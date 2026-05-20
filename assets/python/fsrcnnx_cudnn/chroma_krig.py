"""KrigBilateral chroma upscaler — PyTorch reference port of Shiandow's
KrigBilateral.glsl (the canonical mpv user shader, as packaged by igv).

Original GLSL: https://gist.github.com/igv/a015fc885d5c22e6891820ad89555637

Algorithm in three stages, mirroring the GLSL three-pass structure:

  1. LOWRES_Y: downsample the (post-FSRCNNX) luma to the *input* chroma
     grid using a Blackman-windowed 1-D pass per axis (separable),
     producing per-input-chroma-sample (E[Y], Var(Y)).
  2. Guide luma: bilinearly resample luma to the *output* chroma grid
     to obtain the scalar `y` used as the bilateral guide for each
     output pixel.
  3. For each output chroma pixel: gather a 3×3 input-chroma
     neighborhood (replicate-padded), build an 8×8 kriging covariance
     system (Gaussian spatial kernel × bilateral term over luma
     differences, plus a rank-1 trend term in the centered guide
     residual), solve, project the kriging weights onto the 3×3
     chroma neighborhood, and emit U,V.

Output is at (h_out, w_out) which the caller picks. For the
`fsrcnnx_yuv` integration, h_out / w_out = output luma resolution
shifted by the input clip's subsampling — i.e., the output keeps
input subsampling without a follow-up resize.

Hyperparameters are hardcoded to the GLSL defaults (noise=0.05,
radius=1, taps=3 → 3×3 neighborhood). Expose as kwargs only if a
need arises.

Two CUDA kernels carry the load (compiled lazily on first call via
``torch.utils.cpp_extension.load_inline``, cached under
``~/.cache/torch_extensions``):

  * ``lowres_y_kernel`` does stage 1 — a 2-D Blackman integration
    that produces (E[Y], Var(Y)) at the chroma input grid. Equivalent
    to the GLSL's two separable 1-D passes; we fuse them into one.
  * ``krig_kernel`` does stage 3 — 1 thread per output chroma pixel,
    ``M[8][8]`` in registers, fully unrolled Gaussian elimination,
    chroma projection. Matches the GLSL fragment shader's per-pixel
    cost model. Stage 2 (bilinear guide luma) stays as a single
    ``F.interpolate`` call before the kernel.

Runtime dependency: ``ninja`` (the build driver
``torch.utils.cpp_extension.load_inline`` uses); ``nvcc`` is needed
once for the first-time compile but is already on the system for any
CUDA torch install.
"""
from __future__ import annotations

import math
import os

import torch
import torch.nn.functional as F


# GLSL defaults.
_NOISE = 0.05
_RADIUS_SQ = 1.0
_EPS = 1e-8


def _blackman_kernel(x: torch.Tensor) -> torch.Tensor:
    """Three-term Blackman-Harris-style window from the GLSL:

        Kernel(x) = dot(vec3(0.42659, -0.49656, 0.076849),
                        cos(vec3(0,1,2) * π * (x + 1)))

    Support is |x| ≤ 1 in output-pixel units; caller must mask outside.
    """
    pi = math.pi
    return (
        0.42659
        - 0.49656 * torch.cos(pi * (x + 1.0))
        + 0.076849 * torch.cos(2.0 * pi * (x + 1.0))
    )


def _blackman_resample_matrix(in_len: int, out_len: int,
                              device: torch.device, dtype: torch.dtype
                              ) -> torch.Tensor:
    """Precompute the (out_len, in_len) Blackman resample matrix that
    mirrors KrigBilateral.glsl pass 1/2. Each row holds the weights
    that produce a single output sample as a linear combination of
    input samples. Rows are normalized so weights sum to 1 (the GLSL
    `avg /= W` step)."""
    out_pos = (torch.arange(out_len, device=device, dtype=dtype) + 0.5) / out_len
    in_pos = (torch.arange(in_len, device=device, dtype=dtype) + 0.5) / in_len
    # Distance from each output texel center to each input texel center,
    # in OUTPUT-pixel units (the GLSL `rel` variable).
    diff = (in_pos[None, :] - out_pos[:, None]) * out_len  # (out_len, in_len)
    in_support = diff.abs() < 1.0
    w = _blackman_kernel(diff)
    w = torch.where(in_support, w, torch.zeros_like(w))
    w = w / w.sum(dim=-1, keepdim=True).clamp_min(_EPS)
    return w


_BLACKMAN_TAPS_CACHE: dict[tuple, tuple[torch.Tensor, int, int]] = {}


def _blackman_taps_1d(in_len: int, out_len: int,
                      device: torch.device, dtype: torch.dtype
                      ) -> tuple[torch.Tensor, int, int] | None:
    """Precompute the 1-D Blackman taps for an integer-ratio strided
    resample ``in_len → out_len`` along one axis. Returns
    ``(taps, stride, padding)`` or ``None`` for a non-integer ratio.

    The Blackman taps are translation-invariant in stride units (one
    kernel applies to every output sample), so the per-output cost in
    the CUDA kernel is just ``K = 2*R`` reads × multiply-add.
    """
    if in_len % out_len != 0:
        return None
    R = in_len // out_len
    K = 2 * R
    P = R - 1
    key = (in_len, out_len, str(device), str(dtype))
    cached = _BLACKMAN_TAPS_CACHE.get(key)
    if cached is not None:
        return cached
    j = torch.arange(K, dtype=dtype, device=device)
    # Position of input tap `j` relative to its output texel center, in
    # OUTPUT-pixel units (the GLSL `rel` variable).
    rel = (j - P - (R / 2.0 - 0.5)) / R
    w = _blackman_kernel(rel)
    w = torch.where(rel.abs() < 1.0, w, torch.zeros_like(w))
    w = (w / w.sum().clamp_min(_EPS)).contiguous()
    _BLACKMAN_TAPS_CACHE[key] = (w, R, P)
    return w, R, P


def _lowres_y_blackman(
    y_hi: torch.Tensor, h_c: int, w_c: int,
) -> tuple[torch.Tensor, torch.Tensor]:
    """Produce (E[Y], Var(Y)) on the (h_c, w_c) chroma grid from `y_hi`.

    Mathematically equivalent to the GLSL's two separable 1-D Blackman
    passes (the 2-D Blackman kernel factors as the outer product of the
    two 1-D taps, and the variance bookkeeping collapses to
    ``E[Y²] - E[Y]²``). For integer ratios the work runs in one fused
    CUDA kernel that does both axes in a single pass; non-integer
    ratios fall back to the dense einsum path.
    """
    device = y_hi.device
    dtype = y_hi.dtype
    h_hi, w_hi = y_hi.shape[-2], y_hi.shape[-1]

    taps_h = _blackman_taps_1d(h_hi, h_c, device, torch.float32)
    taps_w = _blackman_taps_1d(w_hi, w_c, device, torch.float32)
    if (taps_h is not None and taps_w is not None
            and y_hi.is_cuda and dtype in (torch.float16, torch.float32)):
        w_h, stride_h, pad_h = taps_h
        w_w, stride_w, pad_w = taps_w
        y_flat = y_hi[0, 0].to(torch.float16).contiguous()
        ey_out = torch.empty((h_c, w_c), device=device, dtype=torch.float16)
        var_out = torch.empty_like(ey_out)
        ext = _get_cuda_ext()
        ext.lowres_y_launch(
            y_flat, w_h, w_w, ey_out, var_out,
            h_hi, w_hi, h_c, w_c,
            w_h.shape[0], w_w.shape[0], pad_h, pad_w, stride_h, stride_w,
        )
        return ey_out[None, None], var_out[None, None]

    # Non-integer / non-CUDA fallback: original separable einsum path.
    pair_full = torch.cat([y_hi, y_hi * y_hi], dim=1)
    w_h = _blackman_resample_matrix(h_hi, h_c, device, dtype)
    pair_h = torch.einsum('oi,bcij->bcoj', w_h, pair_full)
    p1_mean = pair_h[:, 0:1]
    p1_var = (pair_h[:, 1:2] - p1_mean ** 2).abs()
    pair_for_p2 = torch.cat([p1_mean, p1_mean ** 2, p1_var], dim=1)
    w_w = _blackman_resample_matrix(w_hi, w_c, device, dtype)
    pair_w = torch.einsum('oi,bcji->bcjo', w_w, pair_for_p2)
    final_mean = pair_w[:, 0:1]
    width_var_contribution = (pair_w[:, 1:2] - final_mean ** 2).abs()
    p1_var_resampled = pair_w[:, 2:3]
    return final_mean, width_var_contribution + p1_var_resampled



# ---------------------------------------------------------------------------
# Native CUDA path (the production backend)
# ---------------------------------------------------------------------------
# 1 thread = 1 output chroma pixel. The 8×8 covariance matrix `M` and the
# 8-vector `b` live in thread-local registers; Gaussian elimination is fully
# unrolled at compile time. Neighbor loads go through `__ldg` (read-only
# cache) with manual clamp on the input chroma indices — equivalent to the
# GLSL TMU's clamp-to-edge addressing mode. We match the upstream GLSL's
# unpivoted elimination and skip pivoting; numerical robustness comes from
# a tiny ridge added to `M[k][k]`.

_cuda_ext = None


def _get_cuda_ext():
    """Resolve the KrigBilateral CUDA extension. Prefers the AOT-built
    ``_krig_cuda`` module shipped with the wheel; falls back to a one-time
    JIT compile via ``torch.utils.cpp_extension.load_inline`` reading the
    ``.cu`` source bundled in ``csrc/``. Caches the result module-level.

    Cold-start cost:
      * AOT path: 0 (the .so is already loaded by the time Python imports
        this package).
      * JIT fallback: ~15-25 s the first run on a new (Python, CUDA, GPU
        arch) combination; subsequent runs reload instantly from
        ``~/.cache/torch_extensions``.
    """
    global _cuda_ext
    if _cuda_ext is not None:
        return _cuda_ext

    # AOT path — prebuilt extension shipped in the wheel.
    try:
        from . import _krig_cuda    # type: ignore[attr-defined]
        _cuda_ext = _krig_cuda
        return _cuda_ext
    except ImportError:
        pass

    if os.environ.get("FSRCNNX_KRIG_ALLOW_JIT") != "1":
        raise ImportError(
            "prebuilt fsrcnnx_cudnn._krig_cuda is not available; "
            "set FSRCNNX_KRIG_ALLOW_JIT=1 only in a local build "
            "environment with nvcc/MSVC when intentionally testing JIT"
        )

    # JIT fallback — compile from the bundled .cu source.
    from importlib import resources
    from torch.utils.cpp_extension import load_inline

    cu_src = (resources.files(__package__) / 'csrc' / 'chroma_krig.cu').read_text()
    cpp_decl = (
        '#include <torch/extension.h>\n'
        'void krig_launch(\n'
        '    torch::Tensor y_hi, torch::Tensor ey, torch::Tensor var,\n'
        '    torch::Tensor u_in, torch::Tensor v_in,\n'
        '    torch::Tensor u_out, torch::Tensor v_out,\n'
        '    int64_t H_hi, int64_t W_hi,\n'
        '    int64_t h_in, int64_t w_in, int64_t h_out, int64_t w_out,\n'
        '    double scale_y, double scale_x,\n'
        '    double guide_scale_y, double guide_scale_x);\n'
        'void lowres_y_launch(\n'
        '    torch::Tensor y_hi, torch::Tensor w_h, torch::Tensor w_w,\n'
        '    torch::Tensor ey_out, torch::Tensor var_out,\n'
        '    int64_t H_hi, int64_t W_hi, int64_t h_out, int64_t w_out,\n'
        '    int64_t K_h, int64_t K_w, int64_t pad_h, int64_t pad_w,\n'
        '    int64_t stride_h, int64_t stride_w);\n'
    )
    _cuda_ext = load_inline(
        name='fsrcnnx_krig_cuda',
        cpp_sources=cpp_decl,
        cuda_sources=cu_src,
        functions=['krig_launch', 'lowres_y_launch'],
        extra_cuda_cflags=['-O3', '--use_fast_math', '-lineinfo'],
        verbose=False,
    )
    return _cuda_ext


def precompile() -> None:
    """Eagerly trigger the JIT compile so that the first chroma frame
    doesn't pay the ~18 s nvcc cost. Idempotent — safe to call from a
    setup hook, CI step, or one-liner before playback::

        python -c "from fsrcnnx_cudnn.chroma_krig import precompile; precompile()"
    """
    _get_cuda_ext()


def _as_4d(t: torch.Tensor) -> torch.Tensor:
    """Treat either (H, W) or (1, 1, H, W) inputs uniformly. The internal
    helpers (e.g. `_lowres_y_blackman`) expect 4D; the CUDA kernel reads
    flat 2D views. Coercion is cheap (no-op view in both cases)."""
    return t.unsqueeze(0).unsqueeze(0) if t.dim() == 2 else t


def _krig_chroma_cuda(
    y_hi: torch.Tensor,
    u_in: torch.Tensor,
    v_in: torch.Tensor,
    u_out: torch.Tensor,
    v_out: torch.Tensor,
) -> None:
    """In-place kernel launch. `u_out` / `v_out` are written to directly
    when they're already fp16; otherwise the kernel targets a small fp16
    scratch and we cast-copy at the end. All shapes have been validated
    by the public dispatcher above."""
    y_hi_4d = _as_4d(y_hi).to(torch.float16)
    u_in_4d = _as_4d(u_in).to(torch.float16)
    v_in_4d = _as_4d(v_in).to(torch.float16)

    h_in, w_in = u_in_4d.shape[-2], u_in_4d.shape[-1]
    H_hi, W_hi = y_hi_4d.shape[-2], y_hi_4d.shape[-1]
    h_out, w_out = u_out.shape[-2], u_out.shape[-1]

    ey_in, var_in = _lowres_y_blackman(y_hi_4d, h_in, w_in)

    # If the caller's buffers are fp16, the kernel writes straight in
    # (zero-copy). Otherwise allocate a small fp16 scratch and cast-copy
    # at the end — still cheaper than the old internal stack approach.
    fp16_out = (u_out.dtype == torch.float16 and v_out.dtype == torch.float16)
    if fp16_out:
        u_dst = u_out.view(h_out, w_out)
        v_dst = v_out.view(h_out, w_out)
    else:
        u_dst = torch.empty((h_out, w_out), device=u_out.device, dtype=torch.float16)
        v_dst = torch.empty_like(u_dst)

    ext = _get_cuda_ext()
    ext.krig_launch(
        y_hi_4d[0, 0].contiguous(),
        ey_in[0, 0].contiguous(),
        var_in[0, 0].contiguous(),
        u_in_4d[0, 0].contiguous(),
        v_in_4d[0, 0].contiguous(),
        u_dst, v_dst,
        H_hi, W_hi,
        h_in, w_in, h_out, w_out,
        h_in / float(h_out), w_in / float(w_out),
        H_hi / float(h_out), W_hi / float(w_out),
    )

    if not fp16_out:
        u_out.view(h_out, w_out).copy_(u_dst)
        v_out.view(h_out, w_out).copy_(v_dst)


def krig_bilateral_chroma(
    y_hi: torch.Tensor,
    u_in: torch.Tensor,
    v_in: torch.Tensor,
    *,
    u_out: torch.Tensor | None = None,
    v_out: torch.Tensor | None = None,
    h_out: int | None = None,
    w_out: int | None = None,
) -> tuple[torch.Tensor, torch.Tensor]:
    """Luma-guided chroma upsample (KrigBilateral). Returns
    ``(u_out, v_out)`` — the actual tensors written to, whether they were
    allocated internally or supplied by the caller.

    Inputs
    ------
    ``y_hi``
        High-res luma guide, ``(1, 1, H_hi, W_hi)`` or ``(H_hi, W_hi)``.
    ``u_in``, ``v_in``
        Chroma planes at the lower input resolution,
        ``(1, 1, h_in, w_in)`` or ``(h_in, w_in)``. Must share shape.

    Output target — pass exactly **one** of:

    1. ``u_out`` and ``v_out`` — pre-allocated CUDA tensors. Output shape is
       inferred from ``u_out.shape[-2:]``. Zero-copy if both are fp16;
       otherwise the kernel writes to a small fp16 scratch and cast-copies
       at the end.
    2. ``h_out`` and ``w_out`` as ints — function allocates output tensors
       with dtype matching ``u_in`` and returns them.

    Values are in [0, 1]. Caller is responsible for any subsequent clamp
    (the kriging output can briefly overshoot in saturated regions, matching
    the GLSL).
    """
    if not (y_hi.is_cuda and u_in.is_cuda and v_in.is_cuda):
        raise RuntimeError(
            "krig_bilateral_chroma requires CUDA tensors; got "
            f"y_hi.device={y_hi.device}, u_in.device={u_in.device}, "
            f"v_in.device={v_in.device}"
        )
    if u_in.shape != v_in.shape:
        raise RuntimeError(
            f"u_in / v_in must have identical shape; got {tuple(u_in.shape)} "
            f"vs {tuple(v_in.shape)}"
        )

    have_out = u_out is not None and v_out is not None
    have_dims = h_out is not None and w_out is not None
    if have_out == have_dims:    # both, or neither
        raise RuntimeError(
            "krig_bilateral_chroma: pass exactly one of (u_out, v_out) for "
            "zero-copy mode OR (h_out, w_out) for internal allocation; got "
            f"u_out={u_out is not None}, v_out={v_out is not None}, "
            f"h_out={h_out}, w_out={w_out}"
        )

    if have_out:
        if u_out.shape != v_out.shape:
            raise RuntimeError(
                f"u_out / v_out must have identical shape; got "
                f"{tuple(u_out.shape)} vs {tuple(v_out.shape)}"
            )
        if not (u_out.is_cuda and v_out.is_cuda):
            raise RuntimeError(
                f"u_out / v_out must be CUDA tensors; got "
                f"u_out.device={u_out.device}, v_out.device={v_out.device}"
            )
    else:
        u_out = torch.empty(
            (1, 1, h_out, w_out), device=u_in.device, dtype=u_in.dtype,
        )
        v_out = torch.empty_like(u_out)

    _krig_chroma_cuda(y_hi, u_in, v_in, u_out, v_out)
    return u_out, v_out
