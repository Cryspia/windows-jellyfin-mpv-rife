# windows-jellyfin-mpv-rife

[English](./README.md)

面向 Windows + NVIDIA RTX 显卡的可重复 portable 安装器，用于生成一套自包含的 **mpv + jellyfin-mpv-shim + RIFE 实时插帧 + NVIDIA RTX Video Super Resolution + dandanplay 弹幕** 客户端。

安装完成后，运行时全部位于 `jellyfin-mpv-shim-portable/`。除 NVIDIA 驱动和系统图形栈外，不需要在主机上安装 Python、mpv、VapourSynth、TensorRT、Tk 或 Jellyfin 客户端组件。

## 需求

- Windows 10/11 x64。
- 支持 RTX Video Super Resolution 的 NVIDIA RTX 30 系及以上显卡，以及较新的 NVIDIA Release 驱动。
- NVIDIA App / NVIDIA Control Panel 中已启用 RTX Video Super Resolution。
- 本项目不支持 Intel 或 AMD 显卡。
- PowerShell 7 或 Windows PowerShell。
- 首次安装需要联网下载 Python、mpv、ffmpeg、Python wheels、RIFE 模型和弹幕脚本。

## 使用

如果项目是通过 ZIP 下载或从网络位置复制过来的，Windows 可能会给 `install.ps1` 加上远程文件标记，导致 PowerShell 拒绝直接运行。首次安装前先解除脚本锁定：

```powershell
Unblock-File .\install.ps1
```

`jellyfin-mpv-shim-portable/` 里的启动/停止脚本是 `install.ps1` 在本机生成的，正常安装流程下通常不需要额外 unlock。只有当你把已经生成好的 portable 文件夹从另一台电脑、网络共享或下载压缩包里复制过来时，才需要连 portable 里的 PowerShell 脚本一起解除锁定：

```powershell
Get-ChildItem .\jellyfin-mpv-shim-portable -Recurse -Filter *.ps1 | Unblock-File
```

```powershell
# 完整安装或更新
.\install.ps1 install

# 更快安装，但首次播放可能会等待 TensorRT 编译 engine
.\install.ps1 install -SkipRifeTrtPrecompile

# 安装时测试本机 RIFE 能力，并把三档默认倍率写入 runtime.conf
.\install.ps1 install -BenchmarkRifeRuntime

# 可选：让 >1080p 视频走 4K -> 1080p GPU 下采样 -> RIFE -> NVIDIA VSR
# 默认关闭；开启后 4K real frame 会经过 1080p 中间流再超分回 4K
.\install.ps1 install -EnableDownsampled4kVsr -BenchmarkRifeRuntime

# 查看状态
.\install.ps1 status

# 启动/停止 jellyfin-mpv-shim
.\install.ps1 start-shim
.\install.ps1 stop-shim

# 本地 mpv 测试
.\install.ps1 test-mpv
.\install.ps1 test-rife
.\install.ps1 test-all

# 创建或移除当前用户开机启动快捷方式
.\install.ps1 create-startup
.\install.ps1 remove-startup

# 删除生成的运行时，默认保留 portable/config
.\install.ps1 uninstall

# 同时删除配置
.\install.ps1 uninstall -PurgeConfig
```

常用入口在安装后生成：

| 文件 | 用途 |
|---|---|
| `jellyfin-mpv-shim-portable/start-shim.bat` | 双击启动托盘版 Jellyfin 客户端 |
| `jellyfin-mpv-shim-portable/stop-shim.bat` | 停止 shim、mpv 和 portable Python 子进程 |
| `jellyfin-mpv-shim-portable/start-mpv.bat` | 使用同一套 portable mpv 配置播放本地文件 |

## 默认播放管线

| 条件 | RIFE 插帧 | NVIDIA VSR |
|---|---|---|
| 源帧率 <= 60 fps | 按刷新率和本机能力选择 x2/x3/x4，默认 RIFE 4.26 scale=1.0 | 独立判断 |
| 源帧率 > 60 fps | 关闭 | 独立判断 |
| 源分辨率 <= 1920x1080 | 独立判断 | 开启 NVIDIA d3d11vpp VSR |
| 源分辨率 > 1920x1080 | 默认测试全分辨率 4.26 x4/x3/x2，失败后才回退到 4.26 scale=0.5 x2；启用 `-EnableDownsampled4kVsr` 时测试下采样后 x4/x3/x2 | 默认关闭；启用下采样路径时用于把 1080p 中间流升回显示尺寸 |

mpv 的实际滤镜顺序是：

```text
vapoursynth(RIFE) -> d3d11vpp(NVIDIA VSR)
```

也就是说，低帧率 1080p 内容会先插帧再交给 NVIDIA 驱动级超分；高帧率 1080p 内容只做超分；高于 1080p 的低帧率内容默认保留原始 4K real frames，安装 benchmark 会先尝试全分辨率 `4.26 x4/x3/x2`，都失败才用 `4.26 scale=0.5 x2` 兜底。RIFE 会在“不超过显示器刷新率”的前提下选择最高倍率，最高 x4；例如 24fps 在 60Hz 下最多 x2，在 120Hz 下最多 x4。

RIFE 的普通路径优先使用 `vs_gpu_helpers.rife_yuv`，把 YUV/RGB 色彩转换和 RIFE 输入/输出放到 CUDA/TensorRT 管线里。GPU 路径只对白名单矩阵和 `limited/full` range 启用；YUV420P10、YUV422P10、YUV444P10 会按原 subsampling 进入 GPU 色转并按原 subsampling 写回插帧结果。其他位深或异常 subsampling 会先规范化到 YUV420P10。可选的 4K 下采样 + VSR 路径也会对 P10 420/422/444 保留原 subsampling；如果输入需要规范化，则使用 YUV420P10 中间流。如果 GPU helper 不可用，会回退到标准 `vsrife + core.resize.Bicubic` CPU 色转路径，而不是直接关闭插帧；如果逐帧颜色元数据不在白名单内，helper 会拒绝处理，避免静默产生错误颜色。HDR10 常见的 YUV420P10 / BT.2020 NCL frame props 会保留，但 RIFE 本身不是线性光 HDR-aware 插帧算法。

`-EnableDownsampled4kVsr` 是性能优先的 4K 可选路径：

```text
4K source -> GPU downsample to 1080p -> RIFE 4.26 -> NVIDIA VSR -> display size
```

这条路径可以让 4K 24fps 在本机 4080 上跑到 x4，但 real frames 也会经过 1080p 中间流，原始 4K 高频信息会丢失。默认关闭。

RIFE 默认使用经过 patch 的 TensorRT 混合精度策略。安装器会 patch 上游 `vsrife`，把 TensorRT 编译参数从 `use_explicit_typing=True` 改成 `use_explicit_typing=False` 加 `enabled_precisions={torch.float16, torch.float32}`；这样保留 FP16 吞吐，同时允许 TensorRT 在需要的位置使用 FP32 累加，避免快速运动和 RTX 50 系 / Blackwell 环境下可能出现的光流溢出花帧。

安装时脚本还会用内置的全分辨率和兜底 RIFE 配置预编译常见 720p、1080p 和 4K TensorRT engine；如果启用 `-EnableDownsampled4kVsr`，也会预编译 4K 下采样 profile。这样可以避免第一次播放时长时间编译导致用户误以为卡死。4K engine 即使在高端显卡上也可能需要数分钟编译；如果想缩短安装时间并接受首次播放时编译，可使用 `-SkipRifeTrtPrecompile`。

`config/mpv/runtime.conf` 控制运行时策略。可在其中手动设置 `display_refresh`、`vsr_target_w`、`vsr_target_h`，用于多显示器和 VRR 环境下固定刷新率和 VSR 目标尺寸。默认三档能力上限是 `max_factor_720`、`max_factor_1080`、`max_factor_4k`；默认 profile 字段是 `rife_model_720`、`rife_model_1080`、`rife_model_4k`，通常保持 `4.26`。使用 `-BenchmarkRifeRuntime` 安装时，脚本会用 720p/1080p/4K 的 24fps 合成样片测试 4.26 的 x4/x3/x2，并按一个源帧间隔内所有插帧的合计耗时计算 group p99；group p99 不超过 24fps 源帧预算 41.67ms 时，该倍率通过。如果某档连 4.26 x2 都无法通过，会额外测试 `4.26-half`，也就是 RIFE 4.26 x2 + `scale=0.5` 光流，通过时将该档默认写为 `4.26-half` x2。benchmark 会优先使用 `runtime.conf` 中的 `display_refresh`；为空时会枚举 Windows 当前分辨率下的最高显示模式刷新率，再失败才回退到当前模式或 60Hz。运行时 mpv 仍无法可靠读取完整 VRR range，VRR 用户建议在 `runtime.conf` 明确写入面板上限，例如 `display_refresh=160`。

RIFE 的 VapourSynth 队列默认使用 `rife_buffered_frames=12` 和 `rife_concurrent_frames=4`，用于减少 TensorRT 插帧的帧时间尖峰。显存紧张或想降低延迟时可以手动调低。

## 按键

- `F9`：循环 RIFE 模式 自动默认 x4 -> 4.26 x3 -> 4.26 x2 -> 启用时 4K 下采样+VSR，否则 4.26 x2 scale=0.5 -> 关闭；实际倍率仍受显示刷新率和 `runtime.conf` 能力上限限制。
- `F10`：弹幕显示开关。
- `Shift+F10`：弹幕设置面板。
- `Ctrl+F10`：手动搜索弹幕。
- 其它 mpv 默认按键保持不变，`q` 和窗口关闭按钮仍然退出 mpv。

## NVIDIA Video Super Resolution

Windows 下不使用 GLSL 超分作为默认方案，而是使用 NVIDIA 驱动级 D3D11 Video Processor：

```text
d3d11vpp=scale=...:scaling-mode=nvidia
```

`config/mpv/scripts/autovsr.lua` 会在运行时根据源分辨率追加 `@vsr:d3d11vpp` 滤镜。VSR 倍率按实际显示区域计算：使用 `min(display_width/source_width, display_height/source_height)`，因此在 21:9、16:10、竖屏等异形屏上会按视频实际能填满的限制轴选择倍率，而不会把黑边区域也算进超分目标。多屏环境检测到错误显示器时，可在 `config/mpv/runtime.conf` 里设置 `vsr_target_w` 和 `vsr_target_h` 覆盖目标尺寸。VSR 生效时，`Shift+i 2` 能看到 `d3d11vpp` pass，NVIDIA App 的 RTX Video Enhancement 状态也应从 inactive 变为 active。

如果安装器不能确认系统 VSR 注册表状态，只会提示你检查 NVIDIA App / Control Panel，不会静默 fallback 到 mpv GLSL shader。`-EnableGlslUpscaleFallback` 只保留给手动调试。

## 弹幕

弹幕由 [Cryspia/mpv-dandanplay-danmaku](https://github.com/Cryspia/mpv-dandanplay-danmaku) 提供。安装器每次正常联网安装都会同步该项目 `main` 分支的脚本到：

```text
jellyfin-mpv-shim-portable/config/mpv/scripts/dandanplay/
```

弹幕配置保存在：

```text
jellyfin-mpv-shim-portable/config/mpv/danmaku-config.json
jellyfin-mpv-shim-portable/config/mpv/danmaku-settings.json
jellyfin-mpv-shim-portable/config/cache/danmaku/
```

它支持 Jellyfin metadata 自动匹配、文件名匹配、手动搜索、别名记忆、密度/透明度/字号/速度/显示区域/繁简转换/去重/时间偏移等面板设置。

## 目录结构

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
│   └── shaders/
└── jellyfin-mpv-shim-portable/   # install.ps1 生成，已 gitignore
```

生成的 portable 目录内部：

| 路径 | 用途 |
|---|---|
| `python/` | portable CPython、pip 包、Tk、VapourSynth、Torch、TensorRT、RIFE |
| `mpv/` | portable mpv |
| `tools/` | ffmpeg / ffprobe |
| `config/mpv/` | mpv 配置、runtime.conf、RIFE vpy、autorife/autovsr、弹幕脚本 |
| `config/jellyfin-mpv-shim/` | shim 配置和服务器凭据 |
| `config/logs/` | shim 和 mpv 日志 |
| `config/cache/` | PID、弹幕缓存和临时检测脚本 |

## Portable 边界

portable 目录由安装器生成，不应把需要持久维护的依赖手工放进去。卸载默认保留 `jellyfin-mpv-shim-portable/config/`，其中包含 Jellyfin 服务器凭据、mpv 设置和弹幕设置。使用 `-PurgeConfig` 才会删除配置。

主机侧必须已有 NVIDIA 驱动和启用的 RTX Video Super Resolution；这些不属于 portable 安装范围。

## 维护说明

- `install.ps1 install` 可重复运行，用于更新或修补 portable。
- 默认安装结束会清理 `_downloads` 和临时解压目录；调试安装问题时可使用 `-KeepDownloads`。
- 如果上游弹幕脚本更新，重新运行 `install.ps1 install` 即可同步。
- 如果更新后插帧结果花屏，删除 `jellyfin-mpv-shim-portable/config/cache/rife-trt/` 并重新运行 `install.ps1 install`，让 TensorRT engine 用 patch 后的混合精度策略重新编译。
