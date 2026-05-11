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

# Faster install, but first playback may pause while TensorRT builds engines
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
| `jellyfin-mpv-shim-portable/start-shim.bat` | Start the tray Jellyfin client |
| `jellyfin-mpv-shim-portable/stop-shim.bat` | Stop shim, mpv, and portable Python child processes |
| `jellyfin-mpv-shim-portable/start-mpv.bat` | Play local files with the same portable mpv config |

## Default Playback Pipeline

| Condition | RIFE | NVIDIA VSR |
|---|---|---|
| Source fps <= 60 | enabled with x2/x3/x4 selected by refresh rate and local capability, default RIFE 4.26 scale=1.0 | independent |
| Source fps > 60 | disabled | independent |
| Source resolution <= 1920x1080 | independent | enabled via NVIDIA d3d11vpp VSR |
| Source resolution > 1920x1080 | default benchmark tries full-resolution 4.26 x4/x3/x2 before falling back to 4.26 scale=0.5 x2; optional downsampled x4/x3/x2 with `-EnableDownsampled4kVsr` | disabled by default; used to upscale the 1080p intermediate when the optional downsample path is enabled |

The effective mpv filter order is:

```text
vapoursynth(RIFE) -> d3d11vpp(NVIDIA VSR)
```

Low-fps 1080p content is interpolated first and then passed to driver-level upscaling. High-fps 1080p content uses VSR only. Low-fps content above 1080p keeps original 4K real frames by default; the installer benchmark tries full-resolution `4.26 x4/x3/x2` first and only uses `4.26 scale=0.5 x2` if full-resolution RIFE fails. RIFE picks the highest factor that does not exceed the display refresh rate, up to x4; for example, 24fps caps at x2 on 60Hz and x4 on 120Hz.

The normal RIFE path prefers `vs_gpu_helpers.rife_yuv`, which keeps YUV/RGB conversion and RIFE input/output on the CUDA/TensorRT path. If the helper is unavailable, the scripts fall back to standard `vsrife + core.resize.Bicubic`. Common HDR10 YUV420P10 / BT.2020 NCL frame props are preserved, but RIFE itself is not a linear-light HDR-aware interpolation algorithm.

`-EnableDownsampled4kVsr` enables a performance-first 4K path:

```text
4K source -> GPU downsample to 1080p -> RIFE 4.26 -> NVIDIA VSR -> display size
```

This can make 4K 24fps x4 viable on the tested RTX 4080, but real frames also pass through the 1080p intermediate, so original 4K high-frequency detail is not preserved. It is disabled by default.

RIFE uses TensorRT with a patched mixed-precision policy by default. The installer patches upstream `vsrife` so TensorRT uses `use_explicit_typing=False` plus `enabled_precisions={torch.float16, torch.float32}` instead of `use_explicit_typing=True`; this keeps FP16 throughput while allowing FP32 accumulation where TensorRT needs it, avoiding optical-flow overflow artifacts seen on fast motion and RTX 50-series / Blackwell systems.

During installation, the script also precompiles common RIFE TensorRT engines for 720p, 1080p, and 4K with the bundled full-resolution and fallback profiles. If `-EnableDownsampled4kVsr` is set, it also precompiles the downsampled 4K profiles. This avoids the long first-playback TensorRT build pause. 4K engine builds can take several minutes even on high-end GPUs; use `-SkipRifeTrtPrecompile` when you need a faster install and accept the first-playback compile delay.

`config/mpv/runtime.conf` controls runtime policy. Set `display_refresh`, `vsr_target_w`, and `vsr_target_h` there to pin refresh rate and VSR target size on multi-monitor systems. The default local capability caps are `max_factor_720`, `max_factor_1080`, and `max_factor_4k`; the default profile fields are `rife_model_720`, `rife_model_1080`, and `rife_model_4k`, normally kept at `4.26`. With `-BenchmarkRifeRuntime`, the installer tests 720p/1080p/4K 24fps synthetic clips with 4.26 at x4/x3/x2, measuring group p99 as the total time needed for all inserted frames within one source-frame interval. A factor passes when group p99 fits inside the 24fps source-frame budget of 41.67ms. If a tier cannot pass even 4.26 x2, the installer additionally tests `4.26-half`, meaning RIFE 4.26 x2 with `scale=0.5` optical flow; when that passes, it writes that tier as `4.26-half` x2. Benchmarking uses `runtime.conf` `display_refresh` first, then the Windows current display mode refresh rate, and falls back to 60Hz only if detection fails.

The RIFE VapourSynth queue defaults to `rife_buffered_frames=12` and `rife_concurrent_frames=4` to smooth TensorRT frame-time spikes. Lower them manually if VRAM is tight or latency matters more.

## Keybindings

- `F9` cycles RIFE modes auto/default x4 -> 4.26 x3 -> 4.26 x2 -> 4K downsample+VSR when enabled, otherwise 4.26 x2 scale=0.5 -> off; the effective factor is still limited by display refresh and `runtime.conf` capability caps.
- `F10` toggles danmaku visibility.
- `Shift+F10` opens the danmaku settings panel.
- `Ctrl+F10` opens manual danmaku search.
- Other mpv defaults remain intact, including `q` and the window close button.

## NVIDIA Video Super Resolution

On Windows, the default upscaler is NVIDIA's driver-level D3D11 Video Processor path, not a GLSL shader:

```text
d3d11vpp=scale=...:scaling-mode=nvidia
```

`config/mpv/scripts/autovsr.lua` appends the `@vsr:d3d11vpp` filter at runtime when the source resolution is at or below 1080p. The VSR scale is computed from the actual aspect-preserving render fit with `min(display_width/source_width, display_height/source_height)`, so ultrawide, 16:10, portrait, and other non-16:9 screens do not count letterbox or pillarbox space as part of the upscale target. On multi-monitor setups, set `vsr_target_w` and `vsr_target_h` in `config/mpv/runtime.conf` to override the detected target size. When VSR is active, `Shift+i 2` should show a `d3d11vpp` pass, and NVIDIA App's RTX Video Enhancement status should become active.

If the installer cannot confirm the registry state for NVIDIA VSR, it warns you to check NVIDIA App / Control Panel. It does not silently fall back to GLSL upscaling. `-EnableGlslUpscaleFallback` exists only for manual debugging.

## Danmaku

Danmaku is provided by [Cryspia/mpv-dandanplay-danmaku](https://github.com/Cryspia/mpv-dandanplay-danmaku). Normal online installs sync that repository's `main` branch into:

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
│   │   ├── vs_gpu_helpers.py.example
│   │   ├── autorife.lua.example
│   │   ├── autovsr.lua.example
│   │   └── shim-conf.json.example
│   └── shaders/
└── jellyfin-mpv-shim-portable/   # generated by install.ps1, gitignored
```

Generated portable layout:

| Path | Purpose |
|---|---|
| `python/` | portable CPython, pip packages, Tk, VapourSynth, Torch, TensorRT, RIFE |
| `mpv/` | portable mpv |
| `tools/` | ffmpeg / ffprobe |
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
- Rerun `install.ps1 install` to sync updates from the upstream danmaku script.
- If interpolated frames are corrupted after an update, delete `jellyfin-mpv-shim-portable/config/cache/rife-trt/` and rerun `install.ps1 install` so TensorRT engines rebuild with the patched mixed-precision policy.
