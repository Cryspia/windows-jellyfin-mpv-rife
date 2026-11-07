# windows-jellyfin-mpv-rife

[简体中文](./README.zh-CN.md)

Reproducible Windows portable installer for **mpv + jellyfin-mpv-shim + RIFE realtime frame interpolation + NVIDIA RTX Video Super Resolution + dandanplay danmaku**, tuned for NVIDIA RTX GPUs.

After installation, the generated runtime lives under `jellyfin-mpv-shim-portable/`. Apart from the NVIDIA driver and Windows graphics stack, it does not require host-installed Python, mpv, VapourSynth, TensorRT, Tk, or Jellyfin client components.

## Requirements

- Windows 10/11 x64.
- NVIDIA RTX 30-series or newer GPU with RTX Video Super Resolution support and a current release driver.
- RTX Video Super Resolution enabled in NVIDIA App / NVIDIA Control Panel.
- Intel and AMD GPUs are not supported by this project.
- PowerShell 7 or Windows PowerShell.
- Internet access for the first install to download Python, mpv, ffmpeg, Python wheels, RIFE models, and the danmaku script.

## Usage

If the project was downloaded as a ZIP or copied from the internet, Windows may mark `install.ps1` as a remote file and PowerShell may refuse to run it. Unblock the script once before installation:

```powershell
Unblock-File .\install.ps1
```

The launcher scripts under `jellyfin-mpv-shim-portable/` are generated locally by `install.ps1`, so they normally do not need this. If you copied an already-generated portable folder from another machine or a downloaded archive, unblock the portable PowerShell scripts as well:

```powershell
Get-ChildItem .\jellyfin-mpv-shim-portable -Recurse -Filter *.ps1 | Unblock-File
```

```powershell
# Full install or update
.\install.ps1 install

# Prefer a CJK glyph locale for the portable UI font (sc is the default)
.\install.ps1 install -CjkFontLanguage jp

# Faster install; uncached RIFE profiles will build in a low-priority background process on first use
.\install.ps1 install -SkipRifeTrtPrecompile

# Benchmark local RIFE capability and write tier defaults to runtime.conf
.\install.ps1 install -BenchmarkRifeRuntime

# Optional: route >1080p video through 4K -> 1080p GPU downsample -> RIFE -> NVIDIA VSR
# Disabled by default; when enabled, 4K real frames also pass through a 1080p intermediate
.\install.ps1 install -EnableDownsampled4kVsr -BenchmarkRifeRuntime

# Status
.\install.ps1 status

# Start/stop jellyfin-mpv-shim
.\install.ps1 start-shim
.\install.ps1 stop-shim

# Local mpv tests
.\install.ps1 test-mpv
.\install.ps1 test-rife
.\install.ps1 test-all

# Current-user startup shortcut
.\install.ps1 create-startup
.\install.ps1 remove-startup

# Remove generated runtime, preserving portable/config by default
.\install.ps1 uninstall

# Also delete config
.\install.ps1 uninstall -PurgeConfig
```

Generated launchers:

| File | Purpose |
|---|---|
| `jellyfin-mpv-shim-portable/MPV Portable.exe` or `.bat` | Play local files with the same portable mpv config; `.exe` is generated when a compiler is available, otherwise `.bat` is used |
| `jellyfin-mpv-shim-portable/start-shim.exe` or `.bat` | Start the tray Jellyfin client |
| `jellyfin-mpv-shim-portable/stop-shim.exe` or `.bat` | Stop shim, mpv, and portable Python child processes |
| `jellyfin-mpv-shim-portable/scripts/register-mpv-file-association.bat` | Register MPV Portable in the current user's video file Open With list |
| `jellyfin-mpv-shim-portable/scripts/unregister-mpv-file-association.bat` | Remove that current-user Open With registration |

The portable root keeps only double-click entry points; maintenance scripts live under `jellyfin-mpv-shim-portable/scripts/`. The installer prefers generating Start/taskbar-pinnable `.exe` launchers with the system .NET C# compiler; if the target machine has no compiler, it automatically falls back to `.bat` launchers. Windows 10/11 protects default-app selection, so the installer does not silently take over video file associations. To make this portable MPV the default player, run `scripts/register-mpv-file-association.bat`, then choose `MPV Portable` in Settings > Apps > Default apps, or right-click a video file and use Open with > Choose another app.

The installer pins Jellyfin MPV Shim 3.3.0, Jellyfin API Client 1.21.0, python-mpv-jsonipc 1.5.0, VapourSynth R82, PyTorch 2.14.0 CUDA 13.0, and vsrife 5.7.0. The standard RIFE backend uses Torch-TensorRT 2.14.0 and TensorRT 11.1.0.106. mpv is pinned to a project-tested zhongfly Windows build tag; rerunning the installer upgrades an existing older mpv instead of downloading only when the executable is missing.

Shim uses its `large` network-buffer preset by default (20 seconds, up to 400 MiB) to absorb short stalls from remote Jellyfin servers or reverse proxies. Its health-check interval uses the upstream 3.3 default of 300 seconds so a server returning repeated 502/503 responses does not keep the client in near-continuous failed requests. Both settings remain editable in the Shim UI.

Shim 3 replaces the old Tk configuration windows with an mpv-rendered library browser and settings UI. `start-shim` starts it minimized to the tray by default; use **Show Library Browser** or **Configure Servers** from the tray icon to open the interface. Existing `cred.json` server credentials are retained during upgrades.

The generated portable includes a locale-specific Noto Sans CJK font for Shim 3's Pillow-rendered library titles and captions. `-CjkFontLanguage sc|tc|hk|jp|kr` selects Simplified Chinese, Traditional Chinese, Hong Kong Chinese, Japanese, or Korean glyph preferences; `sc` is the default. In `sc` mode, Shim prefers the Windows Microsoft YaHei regular/bold fonts for clearer Chinese UI text and falls back to the bundled Noto Sans SC font. Other modes prefer their selected portable Noto font. Rerunning the installer with a different value replaces the generated fallback font and updates the preference. The bundled font is distributed under the SIL Open Font License, included beside the font file.

## Default Playback Pipeline

| Condition | RIFE | NVIDIA VSR |
|---|---|---|
| Source fps <= 60 | enabled with x2/x3/x4 selected by refresh rate and local capability, default RIFE 4.26 scale=1.0 | independent |
| Source fps > 60 | disabled | independent |
| Source resolution <= 1920x1080 | independent | enabled via NVIDIA d3d11vpp VSR |
| Source resolution > 1920x1080 | default benchmark tries full-resolution 4.26 x4/x3/x2 before falling back to 4K-only 4.26 scale=0.5 x2; optional downsampled x4/x3/x2 with `-EnableDownsampled4kVsr` | disabled by default; used to upscale the 1080p intermediate when the optional downsample path is enabled |

The effective mpv filter order is:

```text
vapoursynth(RIFE) -> d3d11vpp(NVIDIA VSR)
```

Low-fps 1080p content is interpolated first and then passed to driver-level upscaling. High-fps 1080p content uses VSR only. Low-fps content above 1080p keeps original 4K real frames by default; the installer benchmark tries full-resolution `4.26 x4/x3/x2`; if none pass for the 4K tier, it may use `4.26 scale=0.5 x2` as the final fallback. RIFE picks the highest factor that does not exceed the display refresh rate, up to x4; for example, 24fps caps at x2 on 60Hz and x4 on 120Hz.

The normal RIFE path prefers `vs_gpu_helpers.rife_yuv`, which keeps YUV/RGB conversion and RIFE input/output on the CUDA/TensorRT path. The GPU path only runs for whitelisted matrices and `limited/full` ranges. YUV420P10/YUV422P10 sources use the bundled prebuilt CUDA KrigBilateral chroma extension by default to reconstruct RGB444 before RIFE; YUV444P10 enters without chroma upsampling. With `rife_output_subsampling=auto`, VSR-enabled playback writes interpolated output as YUV420P10 because NVIDIA `d3d11vpp` can fail to create a video-processor output view for YUV444P10. If VSR is disabled, `auto` keeps YUV444P10 when Krig is available; without Krig it preserves source subsampling. `runtime.conf` can override this with `rife_output_subsampling=auto|420|422|444|source` and `rife_chroma_upsample=krig|bilinear`, although forcing 444 together with VSR is driver-dependent. Other bit depths or unusual subsampling are normalized to YUV420P10 first. The optional 4K downsample + VSR path follows the same policy after the downsample step. If the GPU helper is unavailable, the scripts fall back to the standard `vsrife + core.resize.Bicubic` CPU color-conversion path instead of disabling interpolation outright; if per-frame color metadata is outside the whitelist, the helper refuses to process it rather than silently producing wrong colors. Common HDR10 YUV420P10 / BT.2020 NCL frame props are preserved, but RIFE itself is not a linear-light HDR-aware interpolation algorithm.

`-EnableDownsampled4kVsr` enables a performance-first 4K path:

```text
4K source -> GPU downsample to 1080p -> RIFE 4.26 -> NVIDIA VSR -> display size
```

This can make 4K 24fps x4 viable on the tested RTX 4080, but real frames also pass through the 1080p intermediate, so original 4K high-frequency detail is not preserved. It is disabled by default.

### RIFE Backend

`auto` selects TensorRT-RTX mixed precision on detected RTX 50-series GPUs and standard TensorRT mixed precision on other GPUs unless a supported profile is already installed. On RTX 50-series, use FP32 for the standard TensorRT fallback. PyTorch CUDA is also available as a diagnostic fallback.

Close mpv and stop Shim before switching:

```powershell
.\install.ps1 install -RifeTrtBackend rtx -RifePrecision mixed
.\install.ps1 install -RifeTrtBackend standard -RifePrecision fp32
.\install.ps1 install -RifeTrtBackend torch
```

`rtx` uses Torch-TensorRT-RTX 2.14.0 and TensorRT-RTX 1.6.1.120. Standard TensorRT mixed precision can corrupt interpolated frames on Blackwell. The second command selects standard TensorRT with FP32 inputs and TF32 disabled; the third uses PyTorch CUDA inference without TensorRT. `mixed` uses FP16 inputs and allows FP32 layers; it does not guarantee correct output with every engine.

The installer tests a backend switch in a temporary Python copy before replacing the active runtime. Standard and RTX bindings are never installed together. `install.ps1 status` reports the active backend and precision; do not edit the generated `config/mpv/rife-backend.json` to switch. Engines and validation markers are separated under `config/cache/rife-trt/` by backend, versions, precision, and GPU. Unversioned legacy caches are ignored. The optional benchmark writes a separate JSON report for each profile under `config/logs/`; rerun it after switching to tune the frame-rate limits.

For a Blackwell comparison only, explicitly run `install.ps1 install -RifeTrtBackend standard -RifePrecision mixed -AllowExperimentalBlackwellStandardMixed`. Stop if the install self-test fails or interpolated frames show artifacts. Compare the same clip and RIFE factor against RTX mixed and standard FP32, using newly built engines for each profile. The next automatic install switches this experimental profile back to RTX.

During installation, the script also precompiles common RIFE TensorRT engines for 720p, 1080p, and 4K with the bundled full-resolution and fallback profiles. If `-EnableDownsampled4kVsr` is set, it also precompiles the downsampled 4K profiles. This avoids long TensorRT engine builds during playback. 4K engine builds can take several minutes even on high-end GPUs; use `-SkipRifeTrtPrecompile` only when you need a faster install and accept that uncached RIFE profiles will first play without interpolation while a low-priority background Python process builds the missing cache. If another RIFE filter is active when that happens, autorife removes it before launching the builder so TensorRT compilation does not compete with live RIFE inference. Once the cache is ready, press `F9` again to enable the requested RIFE mode. Inline TensorRT builds inside the active VapourSynth filter are still blocked because they can freeze or terminate mpv on Windows. Direct RIFE-to-RIFE hot switching is also guarded: when the current video already has a RIFE filter, pressing `F9` toward another active RIFE profile first removes the current filter and leaves playback running without RIFE; press `F9` again to apply the pending target profile. This extra step avoids the mpv/Python crashes seen when replacing a live VapourSynth TensorRT filter in-place.

`config/mpv/runtime.conf` controls runtime policy. Set `display_refresh`, `vsr_target_w`, and `vsr_target_h` there to pin refresh rate and VSR target size on multi-monitor and VRR systems. The default local capability caps are `max_factor_720`, `max_factor_1080`, and `max_factor_4k`; the default profile fields are `rife_model_720`, `rife_model_1080`, and `rife_model_4k`, normally kept at `4.26`. With `-BenchmarkRifeRuntime`, the installer first tests 720p/1080p/4K 24fps synthetic clips with 4.26 at x4/x3/x2, measuring group p99 as the total time needed for all inserted frames within one source-frame interval. A factor enters real-render validation when group p99 fits inside the 24fps source-frame budget of 41.67ms. Real-render validation starts mpv with `gpu-next`/D3D11 output and the RIFE plus NVIDIA VSR filter chain, then rejects factors with excessive dropped/mistimed/delayed frames; if wall-clock render time exceeds 2x the test clip duration plus startup grace, the installer kills that mpv process and treats the factor as failed. If the 4K tier cannot pass 4.26 x2, the installer can fall back to `4.26-half`, meaning RIFE 4.26 x2 with `scale=0.5` optical flow. Runtime switching checks the matching TensorRT cache before mpv loads the VapourSynth filter; missing caches are built by a separate low-priority process while playback continues without RIFE. Benchmarking uses `runtime.conf` `display_refresh` first; when empty, it enumerates the highest Windows display mode refresh at the current resolution, then falls back to the current mode or 60Hz. At runtime, mpv still cannot reliably read the full VRR range, so VRR users should set the panel ceiling explicitly, for example `display_refresh=160`.

The RIFE VapourSynth queue defaults to `rife_buffered_frames=12` and `rife_concurrent_frames=4` to smooth TensorRT frame-time spikes. Lower them manually if VRAM is tight or latency matters more. Missing runtime TensorRT engines use `trt_cache_build=background` by default: autorife keeps playback running without RIFE, starts one separate low-priority portable Python process to compile or validate the cache, then asks you to press `F9` again after the cache is ready. Use `trt_cache_build=skip` to disable runtime builds or `trt_cache_build=inline` only for debugging the old in-filter build path.

## Keybindings

- `F9` cycles RIFE modes auto/default x4 -> 4.26 x3 -> 4.26 x2 -> 4K downsample+VSR when enabled, otherwise 4.26 x2 scale=0.5 for >1080p -> off; the effective factor is still limited by display refresh and `runtime.conf` capability caps. Switching from one active RIFE profile to another is a two-press operation: the first press disables the current RIFE filter and records the target, and the next press enables that target after the filter has been removed.
- `F8` toggles NVIDIA VSR for the current mpv session. It is enabled by default through `enable_vsr=yes`.
- `F10` toggles danmaku visibility.
- `Shift+F10` opens the danmaku settings panel.
- `Ctrl+F10` opens manual danmaku search.
- Other mpv defaults remain intact, including `q` and the window close button.

## NVIDIA Video Super Resolution

On Windows, the upscaler is NVIDIA's driver-level D3D11 Video Processor path:

```text
d3d11vpp=scale=...:scaling-mode=nvidia
```

`config/mpv/scripts/autovsr.lua` appends the `@vsr:d3d11vpp` filter at runtime when the source resolution is at or below 1080p. The VSR scale is computed from the actual aspect-preserving render fit with `min(display_width/source_width, display_height/source_height)`, so ultrawide, 16:10, portrait, and other non-16:9 screens do not count letterbox or pillarbox space as part of the upscale target. On multi-monitor setups, set `vsr_target_w` and `vsr_target_h` in `config/mpv/runtime.conf` to override the detected target size. When VSR is active, `Shift+i 2` should show a `d3d11vpp` pass, and NVIDIA App's RTX Video Enhancement status should become active. `F8` disables or re-enables the driver VSR filter for the current session.

Local VSR format testing showed that mpv's D3D11 path accepts the YUV outputs used here (`NV12`, `P010`, and 10-bit 420/422/444 through mpv's upload/conversion path). Direct `RGBA/BGRA` input into `d3d11vpp` is not used because it produced D3D11 texture-view errors on the tested system.

If the installer cannot confirm the registry state for NVIDIA VSR, it warns you to check NVIDIA App / Control Panel. It does not silently fall back to another upscaling path.

## Danmaku

Danmaku is provided by [Cryspia/mpv-dandanplay-danmaku](https://github.com/Cryspia/mpv-dandanplay-danmaku). The installer pins a tested upstream revision and installs it into:

```text
jellyfin-mpv-shim-portable/config/mpv/scripts/dandanplay/
```

Danmaku state lives in:

```text
jellyfin-mpv-shim-portable/config/mpv/danmaku-config.json
jellyfin-mpv-shim-portable/config/mpv/danmaku-settings.json
jellyfin-mpv-shim-portable/config/cache/danmaku/
```

Features include Jellyfin metadata matching, filename matching, manual search, smart aliases, density/opacity/font-size/speed/area controls, traditional-simplified conversion, deduplication, source filtering, and per-episode time offsets.

For Shim 3's `mpvtk` playback UI, the installer adds a small external-modal bridge. `Shift+F10` and `Ctrl+F10` are forced project bindings; while the danmaku settings panel, search input, or result picker is open, the mpvtk bitmap HUD temporarily yields so the ASS/console UI remains visible. Closing the modal restores the normal HUD wake controls.

## Project Layout

```text
windows-jellyfin-mpv-rife/
├── install.ps1
├── README.md
├── README.zh-CN.md
├── assets/
│   ├── examples/
│   │   ├── mpv.conf.example
│   │   ├── input.conf.example
│   │   ├── runtime.conf.example
│   │   ├── rife-4.26.vpy.example
│   │   ├── rife-4.26-half-x2.vpy.example
│   │   ├── rife-4.26-down1080-x{2,3,4}.vpy.example
│   │   ├── rife_vpy_common.py.example
│   │   ├── vs_gpu_helpers.py.example
│   │   ├── autorife.lua.example
│   │   ├── autovsr.lua.example
│   │   └── shim-conf.json.example
│   └── python/        # prebuilt KrigBilateral chroma CUDA extension and source
└── jellyfin-mpv-shim-portable/   # generated by install.ps1, gitignored
```

Generated portable layout:

| Path | Purpose |
|---|---|
| `python/` | portable CPython, pip packages, VapourSynth, Torch, TensorRT, RIFE, Jellyfin MPV Shim |
| `mpv/` | portable mpv |
| `tools/` | ffmpeg / ffprobe |
| `fonts/` | locale-selected portable Noto Sans CJK UI font, language marker, and OFL license |
| `config/mpv/` | mpv config, runtime.conf, RIFE vpy files, autorife/autovsr, danmaku script |
| `config/jellyfin-mpv-shim/` | shim config and server credentials |
| `config/logs/` | shim and mpv logs |
| `config/cache/` | PID file, danmaku cache, temporary check scripts |

## Portability Boundary

The portable directory is generated by the installer. Do not manually place long-lived project dependencies in it. `uninstall` preserves `jellyfin-mpv-shim-portable/config/` by default, including Jellyfin credentials, mpv settings, and danmaku settings. Use `-PurgeConfig` only when you want to remove those too.

The host must still provide the NVIDIA driver and enabled RTX Video Super Resolution. Those are outside the portable install scope.

## Maintenance Notes

- `install.ps1 install` is idempotent and can be rerun to update or patch the portable runtime.
- Successful installs clean `_downloads` and temporary extraction directories by default. Use `-KeepDownloads` while debugging installer issues.
- Update this project and rerun `install.ps1 install` to install its latest tested danmaku revision.
- The pinned danmaku revision includes the Shim 3 mpvtk compatibility fix: the right-edge danmaku icon claims the forced left-click binding only while hovered, so it remains clickable without blocking the Shim HUD elsewhere.
- If interpolated frames are corrupted on an RTX 50-series GPU, check `install.ps1 status` and select `-RifeTrtBackend rtx -RifePrecision mixed`. If RTX still produces artifacts, test `-RifePrecision fp32` or `-RifeTrtBackend torch`.

