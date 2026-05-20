#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>
#include <cuda_runtime.h>
#include <cuda_fp16.h>

namespace torch { using Tensor = at::Tensor; }

// Plan B precision: storage is fp16 (halves global memory traffic and
// matches the cuDNN luma runner's native output), compute stays fp32 for
// numerical safety. The 8×8 Gauss elimination is especially sensitive to
// precision in uniform-chroma regions where the trend term denominator
// shrinks toward `noise²`; fp16 mantissa (10 bits) would lose pivots there.
// On Blackwell the fp32 ALU rate is already very high, so the 2× fp16
// throughput on the cov-and-exp section turns out to be marginal compared
// to the bandwidth saved by the smaller buffers.

__device__ __forceinline__ int clamp_int(int v, int lo, int hi) {
    return max(lo, min(v, hi));
}

__device__ __forceinline__ float ldgh(const __half* __restrict__ p, int idx) {
    return __half2float(__ldg(&p[idx]));
}

// ---------------------------------------------------------------------------
// Stage 1: 2-D Blackman LOWRES_Y in a single kernel.
//
// Mathematically equivalent to the GLSL's two separable 1-D passes (the
// 2-D Blackman kernel factors as the outer product of the two 1-D taps,
// and the law-of-total-variance bookkeeping collapses to a direct
// E[Y²] - E[Y]²). We pay 2*R_h * 2*R_w luma reads per output instead of
// 2*R_h + 2*R_w, but skip the intermediate (B, 2, h_c, W_hi) buffer,
// the `torch.cat` (which is what dominated the einsum path), and two
// cuDNN conv2d launches — net win at the resolutions we run.
// ---------------------------------------------------------------------------
__global__ void lowres_y_kernel(
    const __half* __restrict__ y_hi,     // (H_hi, W_hi)  fp16
    const float* __restrict__ w_h,       // (K_h,) Blackman taps — fp32, tiny
    const float* __restrict__ w_w,       // (K_w,)
    __half* __restrict__ ey_out,         // (h_out, w_out)  fp16
    __half* __restrict__ var_out,        // (h_out, w_out)  fp16
    int H_hi, int W_hi, int h_out, int w_out,
    int K_h, int K_w, int pad_h, int pad_w, int stride_h, int stride_w
) {
    const int j = blockIdx.x * blockDim.x + threadIdx.x;
    const int i = blockIdx.y * blockDim.y + threadIdx.y;
    if (i >= h_out || j >= w_out) return;

    const int start_h = i * stride_h - pad_h;
    const int start_w = j * stride_w - pad_w;

    float sum_w = 0.f, sum_wy = 0.f, sum_wy2 = 0.f;
    for (int kh = 0; kh < K_h; ++kh) {
        const int y_idx = clamp_int(start_h + kh, 0, H_hi - 1);
        const float wh = __ldg(&w_h[kh]);
        for (int kw = 0; kw < K_w; ++kw) {
            const int x_idx = clamp_int(start_w + kw, 0, W_hi - 1);
            const float ww = __ldg(&w_w[kw]);
            const float y = ldgh(y_hi, y_idx * W_hi + x_idx);
            const float w = wh * ww;
            sum_w += w;
            sum_wy += w * y;
            sum_wy2 += w * y * y;
        }
    }
    const float inv = 1.0f / fmaxf(sum_w, 1e-12f);
    const float mean = sum_wy * inv;
    ey_out[i * w_out + j]  = __float2half(mean);
    var_out[i * w_out + j] = __float2half(fmaxf(sum_wy2 * inv - mean * mean, 0.0f));
}

// Shared-memory variant: cooperatively load the block's luma window into
// __shared__ once and let every thread read its 2-D Blackman window from
// smem. Reduces global memory traffic by ~3× over the __ldg-only path
// because adjacent threads' windows overlap heavily (R⁻¹ unique input
// per output along each axis after sharing across the warp).
__global__ void lowres_y_kernel_smem(
    const __half* __restrict__ y_hi,
    const float* __restrict__ w_h,
    const float* __restrict__ w_w,
    __half* __restrict__ ey_out,
    __half* __restrict__ var_out,
    int H_hi, int W_hi, int h_out, int w_out,
    int K_h, int K_w, int pad_h, int pad_w, int stride_h, int stride_w,
    int tile_h, int tile_w
) {
    // Tile in smem stays fp16 too — halves shared-memory footprint, lets
    // bigger R values (and larger blocks) fit in the 48 KB default budget.
    extern __shared__ __half tile[];

    const int BM = blockDim.y;
    const int BN = blockDim.x;
    const int block_i0 = blockIdx.y * BM;
    const int block_j0 = blockIdx.x * BN;

    const int luma_y0 = block_i0 * stride_h - pad_h;
    const int luma_x0 = block_j0 * stride_w - pad_w;

    const int tid = threadIdx.y * BN + threadIdx.x;
    const int threads = BM * BN;
    const int tile_pixels = tile_h * tile_w;
    for (int idx = tid; idx < tile_pixels; idx += threads) {
        const int ty_in = idx / tile_w;
        const int tx_in = idx % tile_w;
        const int y_idx = clamp_int(luma_y0 + ty_in, 0, H_hi - 1);
        const int x_idx = clamp_int(luma_x0 + tx_in, 0, W_hi - 1);
        tile[idx] = __ldg(&y_hi[y_idx * W_hi + x_idx]);
    }
    __syncthreads();

    const int i = block_i0 + threadIdx.y;
    const int j = block_j0 + threadIdx.x;
    if (i >= h_out || j >= w_out) return;

    const int local_y0 = threadIdx.y * stride_h;
    const int local_x0 = threadIdx.x * stride_w;

    float sum_w = 0.f, sum_wy = 0.f, sum_wy2 = 0.f;
    for (int kh = 0; kh < K_h; ++kh) {
        const float wh = w_h[kh];
        const int row_off = (local_y0 + kh) * tile_w + local_x0;
        for (int kw = 0; kw < K_w; ++kw) {
            const float ww = w_w[kw];
            const float y = __half2float(tile[row_off + kw]);
            const float w = wh * ww;
            sum_w  += w;
            sum_wy += w * y;
            sum_wy2 += w * y * y;
        }
    }
    const float inv = 1.0f / fmaxf(sum_w, 1e-12f);
    const float mean = sum_wy * inv;
    ey_out[i * w_out + j]  = __float2half(mean);
    var_out[i * w_out + j] = __float2half(fmaxf(sum_wy2 * inv - mean * mean, 0.0f));
}

void lowres_y_launch(
    torch::Tensor y_hi, torch::Tensor w_h, torch::Tensor w_w,
    torch::Tensor ey_out, torch::Tensor var_out,
    int64_t H_hi, int64_t W_hi, int64_t h_out, int64_t w_out,
    int64_t K_h, int64_t K_w, int64_t pad_h, int64_t pad_w,
    int64_t stride_h, int64_t stride_w
) {
    const dim3 block(16, 16);
    const dim3 grid((unsigned)((w_out + block.x - 1) / block.x),
                    (unsigned)((h_out + block.y - 1) / block.y));
    const int tile_h = (int)(block.y * stride_h + K_h);
    const int tile_w = (int)(block.x * stride_w + K_w);
    // fp16 smem tile — 2 bytes per entry. Fits a much larger R than the
    // old fp32 path: budget is 48 KB / 2 bytes = up to 24576 entries.
    const size_t smem_bytes = (size_t)tile_h * tile_w * sizeof(__half);

    auto y_hi_h    = reinterpret_cast<const __half*>(y_hi.data_ptr<at::Half>());
    auto ey_out_h  = reinterpret_cast<__half*>(ey_out.data_ptr<at::Half>());
    auto var_out_h = reinterpret_cast<__half*>(var_out.data_ptr<at::Half>());

    auto stream = at::cuda::getCurrentCUDAStream();
    if (smem_bytes <= 48 * 1024) {
        lowres_y_kernel_smem<<<grid, block, smem_bytes, stream>>>(
            y_hi_h, w_h.data_ptr<float>(), w_w.data_ptr<float>(),
            ey_out_h, var_out_h,
            (int)H_hi, (int)W_hi, (int)h_out, (int)w_out,
            (int)K_h, (int)K_w, (int)pad_h, (int)pad_w,
            (int)stride_h, (int)stride_w,
            tile_h, tile_w);
    } else {
        lowres_y_kernel<<<grid, block, 0, stream>>>(
            y_hi_h, w_h.data_ptr<float>(), w_w.data_ptr<float>(),
            ey_out_h, var_out_h,
            (int)H_hi, (int)W_hi, (int)h_out, (int)w_out,
            (int)K_h, (int)K_w, (int)pad_h, (int)pad_w,
            (int)stride_h, (int)stride_w);
    }
}

__device__ __forceinline__ float ldgh_clamped(const __half* __restrict__ p,
                                               int y, int x, int H, int W) {
    return __half2float(__ldg(&p[clamp_int(y, 0, H - 1) * W + clamp_int(x, 0, W - 1)]));
}

__global__ void krig_kernel(
    const __half* __restrict__ y_hi,      // (H_hi, W_hi)  fp16 post-SR luma
    const __half* __restrict__ ey,        // (h_in,  w_in)  fp16
    const __half* __restrict__ var,
    const __half* __restrict__ u_in,
    const __half* __restrict__ v_in,
    __half* __restrict__ u_out,           // (h_out, w_out) fp16
    __half* __restrict__ v_out,
    int H_hi, int W_hi, int h_in, int w_in, int h_out, int w_out,
    float scale_y, float scale_x,
    float guide_scale_y, float guide_scale_x
) {
    const int j = blockIdx.x * blockDim.x + threadIdx.x;
    const int i = blockIdx.y * blockDim.y + threadIdx.y;
    if (i >= h_out || j >= w_out) return;

    constexpr float NOISE_SQ  = 0.05f * 0.05f;
    constexpr float RADIUS_SQ = 1.0f;
    constexpr float EPS       = 1e-8f;

    // Per-pixel anchor + sub-pixel offset (matches the GLSL recipe:
    // pos = CHROMA_pos * HOOKED_size - 0.5; offset = pos - round(pos))
    const float y_cont = (i + 0.5f) * scale_y - 0.5f;
    const float x_cont = (j + 0.5f) * scale_x - 0.5f;
    const float pos_y_f = floorf(y_cont + 0.5f);
    const float pos_x_f = floorf(x_cont + 0.5f);
    const float off_y = y_cont - pos_y_f;
    const float off_x = x_cont - pos_x_f;
    const int pos_y = (int)pos_y_f;
    const int pos_x = (int)pos_x_f;

    // Guide luma at the output chroma position via manual bilinear from the
    // high-res luma — fuses what was a separate `F.interpolate` stage. Uses
    // OpenGL/align_corners=False texel-center convention.
    const float gy = (i + 0.5f) * guide_scale_y - 0.5f;
    const float gx = (j + 0.5f) * guide_scale_x - 0.5f;
    const int   gy0 = (int)floorf(gy);
    const int   gx0 = (int)floorf(gx);
    const float fy = gy - gy0;
    const float fx = gx - gx0;
    const int gy0c = clamp_int(gy0,     0, H_hi - 1);
    const int gy1c = clamp_int(gy0 + 1, 0, H_hi - 1);
    const int gx0c = clamp_int(gx0,     0, W_hi - 1);
    const int gx1c = clamp_int(gx0 + 1, 0, W_hi - 1);
    const float v00 = ldgh(y_hi, gy0c * W_hi + gx0c);
    const float v01 = ldgh(y_hi, gy0c * W_hi + gx1c);
    const float v10 = ldgh(y_hi, gy1c * W_hi + gx0c);
    const float v11 = ldgh(y_hi, gy1c * W_hi + gx1c);
    const float y_g = (1.f - fy) * ((1.f - fx) * v00 + fx * v01)
                          + fy   * ((1.f - fx) * v10 + fx * v11);

    // 8 outer neighbors. Center is loaded separately as X[N].
    constexpr int DY[8] = {-1, -1, -1,  0,  0,  1,  1,  1};
    constexpr int DX[8] = {-1,  0,  1, -1,  1, -1,  0,  1};

    // Load center (fp16 → fp32 immediately; compute stays fp32).
    const float ey_N  = ldgh_clamped(ey,   pos_y, pos_x, h_in, w_in);
    const float var_N = ldgh_clamped(var,  pos_y, pos_x, h_in, w_in);
    const float u_N   = ldgh_clamped(u_in, pos_y, pos_x, h_in, w_in);
    const float v_N   = ldgh_clamped(v_in, pos_y, pos_x, h_in, w_in);

    // Load 8 outer neighbors.
    float ey_o[8], var_o[8], u_o[8], v_o[8];
    #pragma unroll
    for (int k = 0; k < 8; ++k) {
        ey_o[k]  = ldgh_clamped(ey,   pos_y + DY[k], pos_x + DX[k], h_in, w_in);
        var_o[k] = ldgh_clamped(var,  pos_y + DY[k], pos_x + DX[k], h_in, w_in);
        u_o[k]   = ldgh_clamped(u_in, pos_y + DY[k], pos_x + DX[k], h_in, w_in);
        v_o[k]   = ldgh_clamped(v_in, pos_y + DY[k], pos_x + DX[k], h_in, w_in);
    }

    // Bilateral local moments (E[Y], E[Y²], E[Var(Y)]) over the 3×3.
    float sum_w = 0.f, sum_ey = 0.f, sum_ey2 = 0.f, sum_var = 0.f;
    #pragma unroll
    for (int k = 0; k < 8; ++k) {
        const float wy = fmaxf(0.f, fminf(1.f, 1.5f - fabsf((float)DY[k] - off_y)));
        const float wx = fmaxf(0.f, fminf(1.f, 1.5f - fabsf((float)DX[k] - off_x)));
        const float w = wy * wx;
        sum_w   += w;
        sum_ey  += w * ey_o[k];
        sum_ey2 += w * ey_o[k] * ey_o[k];
        sum_var += w * var_o[k];
    }
    {
        const float wy = fmaxf(0.f, fminf(1.f, 1.5f - fabsf(off_y)));
        const float wx = fmaxf(0.f, fminf(1.f, 1.5f - fabsf(off_x)));
        const float w = wy * wx;
        sum_w   += w;
        sum_ey  += w * ey_N;
        sum_ey2 += w * ey_N * ey_N;
        sum_var += w * var_N;
    }
    const float sum_w_safe = fmaxf(sum_w, EPS);
    const float total_x    = sum_ey  / sum_w_safe;
    const float total_y_sq = sum_ey2 / sum_w_safe;
    const float total_z    = sum_var / sum_w_safe;
    const float lv         = NOISE_SQ + fabsf(total_y_sq - total_x * total_x) + total_z;
    const float lv_safe    = fmaxf(lv, EPS);

    // Luma differences (bilateral term).
    float luma_diff_o[8];
    #pragma unroll
    for (int k = 0; k < 8; ++k) luma_diff_o[k] = ey_o[k] - y_g;
    const float luma_diff_N = ey_N - y_g;

    // c(i) for outer neighbors — covariance with the target.
    float c_o[8];
    #pragma unroll
    for (int k = 0; k < 8; ++k) {
        const float dy_v = (float)DY[k] - off_y;
        const float dx_v = (float)DX[k] - off_x;
        const float d_sq = dy_v * dy_v + dx_v * dx_v;
        const float denom  = fmaxf(lv + var_o[k], EPS);
        const float factor = rsqrtf(fmaxf(1.f + var_o[k] / lv_safe, EPS));
        c_o[k] = factor * __expf(-0.5f * (luma_diff_o[k] * luma_diff_o[k] / denom
                                          + d_sq / RADIUS_SQ));
    }
    // c(N).
    const float d_sq_N = off_y * off_y + off_x * off_x;
    const float c_N = rsqrtf(fmaxf(1.f + var_N / lv_safe, EPS)) *
                      __expf(-0.5f * (luma_diff_N * luma_diff_N / fmaxf(lv + var_N, EPS)
                                      + d_sq_N / RADIUS_SQ));

    // C(N, N) — spatial=0, ey_diff=0 so exp(0)=1; just inv-sqrt + trend.
    const float var_pair_NN = 2.f * var_N;
    const float C_NN = rsqrtf(fmaxf(1.f + var_pair_NN / lv_safe, EPS))
                       + (luma_diff_N * luma_diff_N) / lv_safe;

    // C(i, N) for outer neighbors.
    float C_oN[8];
    #pragma unroll
    for (int k = 0; k < 8; ++k) {
        const float var_pair = var_o[k] + var_N;
        const float ey_diff  = ey_o[k] - ey_N;
        const float spatial  = (float)(DY[k] * DY[k] + DX[k] * DX[k]);
        const float denom    = fmaxf(lv + var_pair, EPS);
        const float factor   = rsqrtf(fmaxf(1.f + var_pair / lv_safe, EPS));
        const float base = factor * __expf(-0.5f * (ey_diff * ey_diff / denom
                                                     + spatial / RADIUS_SQ));
        const float trend = luma_diff_o[k] * luma_diff_N / lv_safe;
        C_oN[k] = base + trend;
    }

    // Build M(i, j) and b(i) directly via the centering trick.
    float M[8][8], b[8];
    #pragma unroll
    for (int ki = 0; ki < 8; ++ki) {
        b[ki] = c_o[ki] - c_N - C_oN[ki] + C_NN;
        #pragma unroll
        for (int kj = 0; kj < 8; ++kj) {
            const float var_pair = var_o[ki] + var_o[kj];
            const float ey_diff  = ey_o[ki] - ey_o[kj];
            const float dy_d     = (float)(DY[ki] - DY[kj]);
            const float dx_d     = (float)(DX[ki] - DX[kj]);
            const float spatial  = dy_d * dy_d + dx_d * dx_d;
            const float denom    = fmaxf(lv + var_pair, EPS);
            const float factor   = rsqrtf(fmaxf(1.f + var_pair / lv_safe, EPS));
            const float base = factor * __expf(-0.5f * (ey_diff * ey_diff / denom
                                                         + spatial / RADIUS_SQ));
            const float trend = luma_diff_o[ki] * luma_diff_o[kj] / lv_safe;
            M[ki][kj] = (base + trend) - C_oN[ki] - C_oN[kj] + C_NN;
        }
        M[ki][ki] += EPS;    // ridge for stability in uniform regions
    }

    // Unpivoted Gaussian elimination (matches the GLSL). Fully unrolled
    // so the compiler keeps M in registers without spilling.
    #pragma unroll
    for (int k = 0; k < 7; ++k) {
        const float inv_pivot = 1.f / M[k][k];
        #pragma unroll
        for (int ki = 0; ki < 8; ++ki) {
            if (ki <= k) continue;
            const float fct = M[ki][k] * inv_pivot;
            #pragma unroll
            for (int kj = 0; kj < 8; ++kj) {
                if (kj <= k) continue;
                M[ki][kj] -= fct * M[k][kj];
            }
            b[ki] -= fct * b[k];
        }
    }

    // Back substitution.
    float x_sol[8];
    x_sol[7] = b[7] / M[7][7];
    #pragma unroll
    for (int k = 6; k >= 0; --k) {
        float s = b[k];
        #pragma unroll
        for (int kj = 0; kj < 8; ++kj) {
            if (kj <= k) continue;
            s -= M[k][kj] * x_sol[kj];
        }
        x_sol[k] = s / M[k][k];
    }

    // Project onto chroma: out = X[N] + Σ_i sol[i] * (X[i] - X[N]).
    float u_acc = u_N, v_acc = v_N;
    #pragma unroll
    for (int k = 0; k < 8; ++k) {
        u_acc += x_sol[k] * (u_o[k] - u_N);
        v_acc += x_sol[k] * (v_o[k] - v_N);
    }

    u_out[i * w_out + j] = __float2half(u_acc);
    v_out[i * w_out + j] = __float2half(v_acc);
}

void krig_launch(
    torch::Tensor y_hi, torch::Tensor ey, torch::Tensor var,
    torch::Tensor u_in, torch::Tensor v_in,
    torch::Tensor u_out, torch::Tensor v_out,
    int64_t H_hi, int64_t W_hi,
    int64_t h_in, int64_t w_in, int64_t h_out, int64_t w_out,
    double scale_y, double scale_x,
    double guide_scale_y, double guide_scale_x
) {
    const dim3 block(16, 16);
    const dim3 grid((unsigned)((w_out + block.x - 1) / block.x),
                    (unsigned)((h_out + block.y - 1) / block.y));
    auto stream = at::cuda::getCurrentCUDAStream();
    krig_kernel<<<grid, block, 0, stream>>>(
        reinterpret_cast<const __half*>(y_hi.data_ptr<at::Half>()),
        reinterpret_cast<const __half*>(ey.data_ptr<at::Half>()),
        reinterpret_cast<const __half*>(var.data_ptr<at::Half>()),
        reinterpret_cast<const __half*>(u_in.data_ptr<at::Half>()),
        reinterpret_cast<const __half*>(v_in.data_ptr<at::Half>()),
        reinterpret_cast<__half*>(u_out.data_ptr<at::Half>()),
        reinterpret_cast<__half*>(v_out.data_ptr<at::Half>()),
        (int)H_hi, (int)W_hi,
        (int)h_in, (int)w_in, (int)h_out, (int)w_out,
        (float)scale_y, (float)scale_x,
        (float)guide_scale_y, (float)guide_scale_x
    );
}

