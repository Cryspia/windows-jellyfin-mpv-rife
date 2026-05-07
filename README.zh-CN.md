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
| 源帧率 < 60 fps | 开启，默认 RIFE 4.26 scale=1.0 | 独立判断 |
| 源帧率 >= 60 fps | 关闭 | 独立判断 |
| 源分辨率 <= 1920x1080 | 独立判断 | 开启 NVIDIA d3d11vpp VSR |
| 源分辨率 > 1920x1080 | 独立判断 | 关闭 |

mpv 的实际滤镜顺序是：

```text
vapoursynth(RIFE) -> d3d11vpp(NVIDIA VSR)
```

也就是说，低帧率 1080p 内容会先插帧再交给 NVIDIA 驱动级超分；高帧率 1080p 内容只做超分；高于 1080p 的低帧率内容只做插帧。

RIFE 默认使用经过 patch 的 TensorRT 混合精度策略。安装器会 patch 上游 `vsrife`，把 TensorRT 编译参数从 `use_explicit_typing=True` 改成 `use_explicit_typing=False` 加 `enabled_precisions={torch.float16, torch.float32}`；这样保留 FP16 吞吐，同时允许 TensorRT 在需要的位置使用 FP32 累加，避免快速运动和 RTX 50 系 / Blackwell 环境下可能出现的光流溢出花帧。

安装时脚本还会用两套内置 RIFE 配置预编译常见 720p、1080p 和 4K TensorRT engine，避免第一次播放时长时间编译导致用户误以为卡死。4K engine 即使在高端显卡上也可能需要数分钟编译；如果想缩短安装时间并接受首次播放时编译，可使用 `-SkipRifeTrtPrecompile`。

## 按键

- `F9`：循环 RIFE 4.26 -> RIFE 4.6 light -> 关闭。
- `F10`：弹幕显示开关。
- `Shift+F10`：弹幕设置面板。
- `Ctrl+F10`：手动搜索弹幕。
- 其它 mpv 默认按键保持不变，`q` 和窗口关闭按钮仍然退出 mpv。

## NVIDIA Video Super Resolution

Windows 下不使用 GLSL 超分作为默认方案，而是使用 NVIDIA 驱动级 D3D11 Video Processor：

```text
d3d11vpp=scale=...:scaling-mode=nvidia
```

`config/mpv/scripts/autovsr.lua` 会在运行时根据源分辨率追加 `@vsr:d3d11vpp` 滤镜。VSR 生效时，`Shift+i 2` 能看到 `d3d11vpp` pass，NVIDIA App 的 RTX Video Enhancement 状态也应从 inactive 变为 active。

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
│   │   ├── rife-4.26.vpy.example
│   │   ├── rife-4.6-light.vpy.example
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
| `config/mpv/` | mpv 配置、RIFE vpy、autovsr、弹幕脚本 |
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
