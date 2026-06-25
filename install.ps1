param(
    [ValidateSet("install", "status", "uninstall", "cleanup", "test-mpv", "test-rife", "test-all", "start-shim", "stop-shim", "create-startup", "remove-startup")]
    [string]$Command = "install",
    [switch]$DryRun,
    [switch]$SkipDownloads,
    [switch]$KeepDownloads,
    [switch]$PurgeConfig,
    [switch]$SkipRifeTrtPrecompile,
    [switch]$BenchmarkRifeRuntime,
    [switch]$EnableDownsampled4kVsr
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$PortableName = "jellyfin-mpv-shim-portable"
$PortableDir = Join-Path $ProjectRoot $PortableName
$LegacyPortableDir = Join-Path $ProjectRoot "portable"
$LegacyConfigDir = Join-Path $ProjectRoot "config"
$ConfigDir = Join-Path $PortableDir "config"
$AssetsDir = Join-Path $ProjectRoot "assets"
$ExamplesDir = Join-Path $AssetsDir "examples"
$DownloadsDir = Join-Path $PortableDir "_downloads"
$LogsDir = Join-Path $ConfigDir "logs"
$MpvDir = Join-Path $PortableDir "mpv"
$PythonDir = Join-Path $PortableDir "python"
$ToolsDir = Join-Path $PortableDir "tools"
$ScriptsDir = Join-Path $PortableDir "scripts"
$MpvConfigDir = Join-Path $ConfigDir "mpv"
$ShimConfigDir = Join-Path $ConfigDir "jellyfin-mpv-shim"
$CacheDir = Join-Path $ConfigDir "cache"

$PythonVersion = "3.12.10"
$PythonZipUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
$PythonTclTkMsiUrl = "https://www.python.org/ftp/python/$PythonVersion/amd64/tcltk.msi"
$GetPipUrl = "https://bootstrap.pypa.io/get-pip.py"
$SevenZipUrl = "https://www.7-zip.org/a/7zr.exe"
$FfmpegZipUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
$DanmakuZipUrl = "https://github.com/Cryspia/mpv-dandanplay-danmaku/archive/refs/heads/main.zip"
$PyTorchCudaIndex = "https://download.pytorch.org/whl/test/cu130"
$NvidiaPipIndex = "https://pypi.ngc.nvidia.com"
$TorchVersion = "2.11.0"
$TensorRtVersion = "10.15.1.29"
$TorchTensorRtVersion = "2.11.0"

$MpvRootLauncherExe = Join-Path $PortableDir "MPV Portable.exe"
$MpvRootLauncherBat = Join-Path $PortableDir "MPV Portable.bat"
$StartShimRootLauncherExe = Join-Path $PortableDir "start-shim.exe"
$StartShimRootLauncherBat = Join-Path $PortableDir "start-shim.bat"
$StopShimRootLauncherExe = Join-Path $PortableDir "stop-shim.exe"
$StopShimRootLauncherBat = Join-Path $PortableDir "stop-shim.bat"

function Write-Step {
    param([string]$Message)
    Write-Host "[+] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Invoke-Logged {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory = $ProjectRoot
    )

    if ($DryRun) {
        Write-Host "DRY-RUN: $FilePath $($ArgumentList -join ' ')"
        return
    }

    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory -Wait -NoNewWindow -PassThru
    if ($p.ExitCode -ne 0) {
        throw "Command failed with exit code $($p.ExitCode): $FilePath $($ArgumentList -join ' ')"
    }
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        if ($DryRun) {
            Write-Host "DRY-RUN: mkdir $Path"
        } else {
            New-Item -ItemType Directory -Path $Path | Out-Null
        }
    }
}

function Move-DirectoryContents {
    param(
        [string]$Source,
        [string]$Destination
    )
    Ensure-Directory $Destination
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        $target = Join-Path $Destination $_.Name
        if (Test-Path $target) {
            return
        }
        Move-Item -LiteralPath $_.FullName -Destination $target
    }
}

function Migrate-LegacyLayout {
    if ((Test-Path $LegacyPortableDir) -and -not (Test-Path $PortableDir)) {
        Write-Step "Renaming portable to $PortableName"
        if ($DryRun) {
            Write-Host "DRY-RUN: rename $LegacyPortableDir -> $PortableDir"
        } else {
            Move-Item -LiteralPath $LegacyPortableDir -Destination $PortableDir
        }
    }

    if (Test-Path $LegacyConfigDir) {
        Write-Step "Moving root config into $PortableName"
        if ($DryRun) {
            Write-Host "DRY-RUN: move $LegacyConfigDir -> $ConfigDir"
        } elseif (Test-Path $ConfigDir) {
            Move-DirectoryContents $LegacyConfigDir $ConfigDir
            Remove-Item -LiteralPath $LegacyConfigDir -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Ensure-Directory $PortableDir
            Move-Item -LiteralPath $LegacyConfigDir -Destination $ConfigDir
        }
    }
}

function Download-File {
    param(
        [string]$Url,
        [string]$Path
    )

    if (Test-Path $Path) {
        return
    }
    if ($SkipDownloads) {
        throw "Missing download and -SkipDownloads was specified: $Path"
    }
    Ensure-Directory (Split-Path -Parent $Path)
    Write-Step "Downloading $Url"
    if ($DryRun) {
        Write-Host "DRY-RUN: Invoke-WebRequest $Url -> $Path"
        return
    }
    Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing
}

function Expand-Zip {
    param(
        [string]$ZipPath,
        [string]$Destination
    )

    Ensure-Directory $Destination
    if ($DryRun) {
        Write-Host "DRY-RUN: Expand-Archive $ZipPath -> $Destination"
        return
    }
    Expand-Archive -Path $ZipPath -DestinationPath $Destination -Force
}

function Get-GitHubLatestAsset {
    param(
        [string]$Repo,
        [string]$AssetPattern
    )

    $api = "https://api.github.com/repos/$Repo/releases/latest"
    $release = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "windows-jellyfin-mpv-rife-installer" }
    $asset = $release.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
    if (-not $asset) {
        throw "No release asset matched '$AssetPattern' in $Repo"
    }
    return $asset
}

function Get-SevenZip {
    Ensure-Directory $ToolsDir
    $sevenZip = Join-Path $ToolsDir "7zr.exe"
    Download-File $SevenZipUrl $sevenZip
    return $sevenZip
}

function Expand-7zArchive {
    param(
        [string]$ArchivePath,
        [string]$Destination
    )

    $sevenZip = Get-SevenZip
    Ensure-Directory $Destination
    Invoke-Logged $sevenZip @("x", "-y", "-o$Destination", $ArchivePath)
}

function Initialize-Layout {
    Write-Step "Preparing project directories"
    foreach ($dir in @(
        $PortableDir, $ConfigDir, $LogsDir, $MpvConfigDir, $ShimConfigDir,
        $ScriptsDir,
        $CacheDir, $DownloadsDir, $ToolsDir
    )) {
        Ensure-Directory $dir
    }
}

function Copy-ExampleIfMissing {
    param(
        [string]$Example,
        [string]$Target
    )

    if (Test-Path $Target) {
        return
    }
    Ensure-Directory (Split-Path -Parent $Target)
    if ($DryRun) {
        Write-Host "DRY-RUN: copy $Example -> $Target"
    } else {
        Copy-Item -Path $Example -Destination $Target
    }
}

function Initialize-Config {
    Write-Step "Initializing persistent config inside portable"
    Ensure-Directory (Join-Path $CacheDir "rife-trt\.validated")
    Copy-ExampleIfMissing (Join-Path $ExamplesDir "mpv.conf.example") (Join-Path $MpvConfigDir "mpv.conf")
    Copy-ExampleIfMissing (Join-Path $ExamplesDir "input.conf.example") (Join-Path $MpvConfigDir "input.conf")
    Copy-ExampleIfMissing (Join-Path $ExamplesDir "runtime.conf.example") (Join-Path $MpvConfigDir "runtime.conf")
    Copy-Item -LiteralPath (Join-Path $ExamplesDir "rife-4.26.vpy.example") -Destination (Join-Path $MpvConfigDir "rife-4.26.vpy") -Force
    foreach ($name in @(
        "rife-4.26-x2.vpy",
        "rife-4.26-x3.vpy",
        "rife-4.26-x4.vpy",
        "rife-4.26-half-x2.vpy",
        "rife-4.26-down1080-x2.vpy",
        "rife-4.26-down1080-x3.vpy",
        "rife-4.26-down1080-x4.vpy"
    )) {
        Copy-Item -LiteralPath (Join-Path $ExamplesDir "$name.example") -Destination (Join-Path $MpvConfigDir $name) -Force
    }
    Copy-Item -LiteralPath (Join-Path $ExamplesDir "rife_vpy_common.py.example") -Destination (Join-Path $MpvConfigDir "rife_vpy_common.py") -Force
    Copy-Item -LiteralPath (Join-Path $ExamplesDir "vs_gpu_helpers.py.example") -Destination (Join-Path $MpvConfigDir "vs_gpu_helpers.py") -Force
    Copy-Item -LiteralPath (Join-Path $ExamplesDir "rife_trt_build_cache.py.example") -Destination (Join-Path $MpvConfigDir "rife_trt_build_cache.py") -Force
    Copy-ExampleIfMissing (Join-Path $ExamplesDir "shim-conf.json.example") (Join-Path $ShimConfigDir "conf.json")
    Ensure-Directory (Join-Path $MpvConfigDir "scripts")
    Copy-Item -LiteralPath (Join-Path $ExamplesDir "autorife.lua.example") -Destination (Join-Path $MpvConfigDir "scripts\autorife.lua") -Force
    Copy-Item -LiteralPath (Join-Path $ExamplesDir "autovsr.lua.example") -Destination (Join-Path $MpvConfigDir "scripts\autovsr.lua") -Force
    Add-RuntimeConfigDefaultValues @{
        max_factor_720 = "4"
        max_factor_1080 = "4"
        max_factor_4k = "4"
        rife_model_720 = "4.26"
        rife_model_1080 = "4.26"
        rife_model_4k = "4.26"
        rife_buffered_frames = "12"
        rife_concurrent_frames = "4"
        rife_chroma_upsample = "krig"
        rife_output_subsampling = "auto"
        enable_vsr = "yes"
        enable_4k_downsample_vsr = "no"
        allow_runtime_trt_build = "no"
        trt_cache_build = "background"
    }
    Set-RuntimeConfigValues @{
        trt_cache_build = "background"
        rife_chroma_upsample = "krig"
        rife_output_subsampling = "auto"
        enable_vsr = "yes"
    }
    Remove-RuntimeConfigKeys @("enable_krig_shader")
    if ($EnableDownsampled4kVsr) {
        Set-RuntimeConfigValues @{
            enable_4k_downsample_vsr = "yes"
            rife_model_4k = "4.26-down1080"
            max_factor_4k = "4"
        }
    } else {
        Set-RuntimeConfigValues @{ enable_4k_downsample_vsr = "no" }
    }

    $shaderTargetDir = Join-Path $MpvConfigDir "shaders"
    $legacyKrigShader = Join-Path $shaderTargetDir "KrigBilateral.glsl"
    if ((Test-Path $legacyKrigShader) -and -not $DryRun) {
        Remove-Item -LiteralPath $legacyKrigShader -Force
    }
    if ((Test-Path $shaderTargetDir) -and -not (Get-ChildItem -LiteralPath $shaderTargetDir -Force -ErrorAction SilentlyContinue) -and -not $DryRun) {
        Remove-Item -LiteralPath $shaderTargetDir -Force
    }
}

function Update-MpvRuntimePolicyConfig {
    $mpvConf = Join-Path $MpvConfigDir "mpv.conf"
    if (Test-Path $mpvConf) {
        if ($DryRun) {
            Write-Host "DRY-RUN: remove legacy RIFE auto profiles from $mpvConf"
        } else {
            $content = Get-Content -LiteralPath $mpvConf -Raw
            $content = $content -replace '(?ms)\r?\n?\[rife-4k60-heavy\]\s*.*?(?=\r?\n\[no-rife-high-fps-or-large\])', ''
            $content = $content -replace '(?ms)\r?\n?\[no-rife-high-fps-or-large\]\s*.*?(?=\r?\n\[|\z)', ''
            $content = $content -replace '(?m)^# Windows default:.*(?:autorife\.lua|autovsr\.lua).*$',
                '# Windows default: scripts/autorife.lua manages RIFE; scripts/autovsr.lua manages @vsr:d3d11vpp.'
            foreach ($line in @("d3d11-exclusive-fs=no", "d3d11-flip=no")) {
                $key = ($line -split "=", 2)[0]
                if ($content -match "(?m)^\s*$([regex]::Escape($key))\s*=") {
                    $content = $content -replace "(?m)^\s*$([regex]::Escape($key))\s*=.*$", $line
                } elseif ($content -match "(?m)^gpu-context=d3d11\s*$") {
                    $content = $content -replace "(?m)^gpu-context=d3d11\s*$", "gpu-context=d3d11`r`n$line"
                } else {
                    $content = "$line`r`n" + $content
                }
            }
            Set-Content -LiteralPath $mpvConf -Value $content.TrimEnd() -Encoding UTF8
        }
    }

    $inputConf = Join-Path $MpvConfigDir "input.conf"
    if (Test-Path $inputConf) {
        if ($DryRun) {
            Write-Host "DRY-RUN: remove legacy F9 vf cycle from $inputConf"
        } else {
            $content = Get-Content -LiteralPath $inputConf -Raw
            $content = $content -replace '(?m)^F9\s+cycle-values\s+vf.*\r?\n?', ''
            $content = $content -replace '(?m)^# F9 cycles RIFE modes manually:.*\r?\n?', ''
            $content = $content -replace '(?m)^# F9 is handled by scripts/autorife\.lua:.*$',
                '# F9 is handled by scripts/autorife.lua: auto/default x4 -> 4.26 x3 -> 4.26 x2 -> 4K downsample+VSR or 4.26 x2 scale=0.5 -> off.'
            if ($content -notmatch 'autorife\.lua') {
                $content = "# F9 is handled by scripts/autorife.lua: auto/default x4 -> 4.26 x3 -> 4.26 x2 -> 4K downsample+VSR or 4.26 x2 scale=0.5 -> off.`r`n" + $content
            }
            Set-Content -LiteralPath $inputConf -Value $content.TrimEnd() -Encoding UTF8
        }
    }
}

function Get-NvidiaGpuGeneration {
    $nvidiaSmi = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) {
        return $null
    }

    try {
        $names = & $nvidiaSmi.Source --query-gpu=name --format=csv,noheader 2>$null
    } catch {
        return $null
    }

    $generations = @()
    foreach ($name in $names) {
        if ($name -match "RTX\s+([0-9]{2})[0-9]{2}") {
            $generations += [int]$Matches[1]
        }
    }
    if ($generations.Count -eq 0) {
        return $null
    }
    return ($generations | Measure-Object -Maximum).Maximum
}

function Set-RifeTensorRtInFile {
    param(
        [string]$Path,
        [bool]$Enabled
    )

    if (-not (Test-Path $Path)) {
        return
    }
    $value = if ($Enabled) { "True" } else { "False" }
    if ($DryRun) {
        Write-Host "DRY-RUN: set trt=$value in $Path"
        return
    }

    $content = Get-Content -LiteralPath $Path -Raw
    $updated = $content -replace "trt\s*=\s*(True|False)\s*,", "trt=$value,"
    if ($updated -ne $content) {
        Set-Content -LiteralPath $Path -Value $updated -Encoding UTF8
    }
}

function Configure-RifeTensorRtForGpu {
    $generation = Get-NvidiaGpuGeneration
    if ($null -eq $generation) {
        Write-Warn "Could not detect NVIDIA GPU generation. Keeping TensorRT enabled for RIFE."
        return
    }

    if ($generation -ge 50) {
        Write-Step "Detected RTX $generation-series / Blackwell GPU; keeping patched mixed-precision TensorRT enabled for RIFE"
    } else {
        Write-Step "Detected RTX $generation-series GPU; keeping TensorRT enabled for RIFE"
    }

    foreach ($name in @(
        "rife-4.26.vpy",
        "rife-4.26-x2.vpy",
        "rife-4.26-x3.vpy",
        "rife-4.26-x4.vpy",
        "rife-4.26-half-x2.vpy",
        "rife-4.26-down1080-x2.vpy",
        "rife-4.26-down1080-x3.vpy",
        "rife-4.26-down1080-x4.vpy"
    )) {
        Set-RifeTensorRtInFile (Join-Path $MpvConfigDir $name) $true
    }
}

function Update-VsrifeTensorRtPrecision {
    Write-Step "Patching vsrife TensorRT precision policy"
    $vsrifeInit = Join-Path $PythonDir "Lib\site-packages\vsrife\__init__.py"
    if (-not (Test-Path $vsrifeInit)) {
        Write-Warn "vsrife is not installed yet; skipping TensorRT precision patch."
        return
    }

    if ($DryRun) {
        Write-Host "DRY-RUN: patch $vsrifeInit use_explicit_typing=True -> use_explicit_typing=False + enabled_precisions={torch.float16, torch.float32}"
        return
    }

    $content = Get-Content -LiteralPath $vsrifeInit -Raw
    if (($content -match "use_explicit_typing=False,\s*\r?\n\s*enabled_precisions=\{torch\.float16,\s*torch\.float32\}") -and ($content -notmatch "use_explicit_typing=True")) {
        return
    }

    $target = "use_explicit_typing=True,"
    $replacement = "use_explicit_typing=False,`r`n                enabled_precisions={torch.float16, torch.float32},"
    if ($content.Contains($target)) {
        $updated = $content.Replace($target, $replacement)
    } elseif ($content -match "enabled_precisions=\{torch\.float16,\s*torch\.float32\},") {
        $updated = $content -replace "enabled_precisions=\{torch\.float16,\s*torch\.float32\},", $replacement
    } else {
        Write-Warn "Could not find TensorRT precision settings in $vsrifeInit. RIFE TensorRT precision patch was not applied."
        return
    }

    Set-Content -LiteralPath $vsrifeInit -Value $updated -Encoding UTF8

    $trtCache = Join-Path $CacheDir "rife-trt"
    if (Test-Path $trtCache) {
        Write-Warn "Removing existing RIFE TensorRT engine cache so engines rebuild with mixed precision"
        Remove-Item -LiteralPath $trtCache -Recurse -Force
    }
    $vsrifeModelDir = Join-Path $PythonDir "Lib\site-packages\vsrife\models"
    if (Test-Path $vsrifeModelDir) {
        Get-ChildItem -LiteralPath $vsrifeModelDir -Filter "*.ts" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

function Install-Python {
    $pythonExe = Join-Path $PythonDir "python.exe"
    if (Test-Path $pythonExe) {
        Write-Step "Portable Python already exists"
        return
    }

    Write-Step "Installing portable Python $PythonVersion"
    $zip = Join-Path $DownloadsDir "python-$PythonVersion-embed-amd64.zip"
    Download-File $PythonZipUrl $zip
    Expand-Zip $zip $PythonDir
    if ($DryRun) {
        $getPip = Join-Path $DownloadsDir "get-pip.py"
        Download-File $GetPipUrl $getPip
        Invoke-Logged $pythonExe @($getPip, "--no-warn-script-location")
        return
    }

    $pth = Get-ChildItem -Path $PythonDir -Filter "python*._pth" | Select-Object -First 1
    if ($pth) {
        $content = Get-Content $pth.FullName
        $content = $content | ForEach-Object {
            if ($_ -eq "#import site") { "import site" } else { $_ }
        }
        if ($content -notcontains "Lib\site-packages") {
            $content += "Lib\site-packages"
        }
        if ($content -notcontains "Lib") {
            $content = @("Lib") + $content
        }
        if (-not $DryRun) {
            Set-Content -Path $pth.FullName -Value $content -Encoding ASCII
        }
    }

    $getPip = Join-Path $DownloadsDir "get-pip.py"
    Download-File $GetPipUrl $getPip
    Invoke-Logged $pythonExe @($getPip, "--no-warn-script-location")
}

function Test-Tkinter {
    $pythonExe = Join-Path $PythonDir "python.exe"
    return (Test-PythonModule $pythonExe "import tkinter as tk`nroot = tk.Tk()`nroot.destroy()")
}

function Install-Tkinter {
    if (Test-Tkinter) {
        Write-Step "Portable tkinter already works"
        return
    }
    Write-Step "Installing portable Tcl/Tk for tkinter"
    $msi = Join-Path $DownloadsDir "tcltk-$PythonVersion-amd64.msi"
    if ($DryRun) {
        Write-Host "DRY-RUN: install Tcl/Tk from $PythonTclTkMsiUrl"
        return
    } elseif ($SkipDownloads) {
        $existing = Get-ChildItem -Path $DownloadsDir -File -Filter "tcltk*.msi" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $existing) {
            throw "Put tcltk.msi into $DownloadsDir or remove -SkipDownloads."
        }
        $msi = $existing.FullName
    } else {
        Download-File $PythonTclTkMsiUrl $msi
    }

    $tmp = Join-Path $PortableDir "_tcltk_extract"
    if (Test-Path $tmp) {
        Remove-Item -LiteralPath $tmp -Recurse -Force
    }
    Ensure-Directory $tmp
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList @("/a", $msi, "TARGETDIR=$tmp", "/qn") -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "msiexec failed to extract Tcl/Tk MSI, exit code $($proc.ExitCode)"
    }

    foreach ($name in @("_tkinter.pyd", "tcl86t.dll", "tk86t.dll", "zlib1.dll")) {
        $src = Join-Path $tmp "DLLs\$name"
        if (-not (Test-Path $src)) {
            throw "Missing Tcl/Tk file after extraction: $src"
        }
        Copy-Item -LiteralPath $src -Destination $PythonDir -Force
    }
    Copy-Item -LiteralPath (Join-Path $tmp "Lib\tkinter") -Destination (Join-Path $PythonDir "Lib\tkinter") -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $tmp "tcl") -Destination (Join-Path $PythonDir "tcl") -Recurse -Force

    $pth = Get-ChildItem -Path $PythonDir -Filter "python*._pth" | Select-Object -First 1
    if ($pth) {
        $content = Get-Content $pth.FullName
        if ($content -notcontains "Lib") {
            $content = @("Lib") + $content
        }
        if ($content -notcontains "Lib\site-packages") {
            $content += "Lib\site-packages"
        }
        Set-Content -Path $pth.FullName -Value $content -Encoding ASCII
    }

    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Tkinter)) {
        throw "Portable tkinter import test failed after installing Tcl/Tk."
    }
}

function Install-Mpv {
    $mpvExe = Join-Path $MpvDir "mpv.exe"
    if (Test-Path $mpvExe) {
        Write-Step "Portable mpv already exists"
        return
    }
    Write-Step "Installing portable mpv Windows build"
    if ($DryRun) {
        $archive = Join-Path $DownloadsDir "mpv-latest.7z"
    } elseif ($SkipDownloads) {
        $archive = Get-ChildItem -Path $DownloadsDir -File -Filter "mpv*.7z" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $archive) {
            throw "Put an mpv .7z archive into $DownloadsDir or remove -SkipDownloads."
        }
    } else {
        $asset = Get-GitHubLatestAsset "zhongfly/mpv-winbuild" "mpv-x86_64.*\.7z$"
        $archive = Join-Path $DownloadsDir $asset.name
        Download-File $asset.browser_download_url $archive
    }
    $tmp = Join-Path $PortableDir "_mpv_extract"
    if ((Test-Path $tmp) -and -not $DryRun) {
        Remove-Item -Path $tmp -Recurse -Force
    }
    Expand-7zArchive $archive $tmp
    if (-not $DryRun) {
        $found = Get-ChildItem -Path $tmp -Recurse -File -Filter "mpv.exe" | Select-Object -First 1
        if (-not $found) {
            throw "mpv.exe not found after extracting $archive"
        }
        $root = Split-Path -Parent $found.FullName
        if (Test-Path $MpvDir) {
            Remove-Item -Path $MpvDir -Recurse -Force
        }
        Move-Item -Path $root -Destination $MpvDir
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-Ffmpeg {
    $ffmpegExe = Join-Path $ToolsDir "ffmpeg.exe"
    if (Test-Path $ffmpegExe) {
        Write-Step "Portable ffmpeg already exists"
        return
    }
    Write-Step "Installing portable ffmpeg for test media conversion"
    $zip = Join-Path $DownloadsDir "ffmpeg-release-essentials.zip"
    Download-File $FfmpegZipUrl $zip
    $tmp = Join-Path $PortableDir "_ffmpeg_extract"
    if ((Test-Path $tmp) -and -not $DryRun) {
        Remove-Item -Path $tmp -Recurse -Force
    }
    Expand-Zip $zip $tmp
    if (-not $DryRun) {
        $bin = Get-ChildItem -Path $tmp -Recurse -Directory -Filter "bin" | Select-Object -First 1
        if (-not $bin) {
            throw "ffmpeg bin directory not found after extracting $zip"
        }
        Copy-Item -Path (Join-Path $bin.FullName "ffmpeg.exe") -Destination $ToolsDir -Force
        Copy-Item -Path (Join-Path $bin.FullName "ffprobe.exe") -Destination $ToolsDir -Force
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-PythonModule {
    param(
        [string]$PythonExe,
        [string]$Code,
        [switch]$ShowOutput
    )

    if (-not (Test-Path $PythonExe)) {
        return $false
    }
    Ensure-Directory $CacheDir
    $scriptPath = Join-Path $CacheDir ("python-check-" + [Guid]::NewGuid().ToString("N") + ".py")
    $stdoutPath = Join-Path $CacheDir ("python-check-" + [Guid]::NewGuid().ToString("N") + ".out")
    $stderrPath = Join-Path $CacheDir ("python-check-" + [Guid]::NewGuid().ToString("N") + ".err")
    Set-PortablePythonEnvironment
    try {
        Set-Content -Path $scriptPath -Value $Code -Encoding UTF8
        $p = Start-Process -FilePath $PythonExe -ArgumentList @($scriptPath) -WorkingDirectory $ProjectRoot -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if ($ShowOutput) {
            if (Test-Path $stdoutPath) {
                Get-Content -LiteralPath $stdoutPath
            }
            if (Test-Path $stderrPath) {
                Get-Content -LiteralPath $stderrPath | ForEach-Object { Write-Host $_ }
            }
        }
        return ($p.ExitCode -eq 0)
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-StalePipUninstallDirs {
    $sitePackages = Join-Path $PythonDir "Lib\site-packages"
    if (-not (Test-Path $sitePackages)) {
        return
    }
    Get-ChildItem -Path $sitePackages -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^~(orch|riton|unctorch)" } |
        ForEach-Object {
            Write-Warn "Removing stale pip uninstall directory: $($_.FullName)"
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
}

function Test-CorePythonPackages {
    param([string]$PythonExe)
    $code = @"
import importlib.util
mods = ["jellyfin_mpv_shim", "vapoursynth", "vsrife", "appdirs"]
missing = [m for m in mods if importlib.util.find_spec(m) is None]
raise SystemExit(1 if missing else 0)
"@
    return (Test-PythonModule $PythonExe $code)
}

function Test-CudaTorch {
    param([string]$PythonExe)
    $code = @"
import torch
expected = "$TorchVersion"
if not torch.__version__.startswith(expected):
    raise SystemExit(1)
if not torch.backends.cuda.is_built():
    raise SystemExit(2)
if not torch.cuda.is_available():
    raise SystemExit(3)
torch.ones(1, device="cuda")
"@
    return (Test-PythonModule $PythonExe $code)
}

function Test-TensorRtPackages {
    param([string]$PythonExe)
    $code = @"
import importlib.metadata as md
expected = {
    "tensorrt": "$TensorRtVersion",
    "torch-tensorrt": "$TorchTensorRtVersion",
}
for name, version in expected.items():
    if md.version(name) != version:
        raise SystemExit(1)
import tensorrt
import torch_tensorrt
"@
    return (Test-PythonModule $PythonExe $code)
}

function Install-PythonPackages {
    $pythonExe = Join-Path $PythonDir "python.exe"
    if ($DryRun) {
        Write-Host "DRY-RUN: install jellyfin-mpv-shim, vapoursynth, vsrife, torch, tensorrt into $pythonExe"
        return
    }
    if (-not (Test-Path $pythonExe)) {
        throw "Portable Python is missing: $pythonExe"
    }

    if ((Test-CorePythonPackages $pythonExe) -and (Test-CudaTorch $pythonExe) -and (Test-TensorRtPackages $pythonExe)) {
        Write-Step "Python package stack already works"
        return
    }

    Write-Step "Installing Python packages into portable Python"
    Invoke-Logged $pythonExe @("-m", "pip", "install", "--upgrade", "pip", "wheel", "setuptools<82")

    if (Test-CorePythonPackages $pythonExe) {
        Write-Step "Core Python packages already present"
    } else {
        $packages = @(
            "jellyfin-mpv-shim[gui]",
            "vapoursynth",
            "vsrife",
            "wheel-stub",
            "appdirs"
        )
        Invoke-Logged $pythonExe (@("-m", "pip", "install") + $packages)
    }

    if (Test-CudaTorch $pythonExe) {
        Write-Step "CUDA PyTorch $TorchVersion already works"
    } else {
        Write-Step "Installing CUDA PyTorch $TorchVersion for Windows"
        Remove-StalePipUninstallDirs
        Invoke-Logged $pythonExe @(
            "-m", "pip", "install",
            "--no-cache-dir",
            "--force-reinstall",
            "--index-url", $PyTorchCudaIndex,
            "torch==$TorchVersion"
        )
    }

    if (Test-TensorRtPackages $pythonExe) {
        Write-Step "TensorRT packages already present"
    } else {
        Write-Step "Installing TensorRT packages"
        try {
            Invoke-Logged $pythonExe @(
                "-m", "pip", "install",
                "--extra-index-url", $NvidiaPipIndex,
                "tensorrt==$TensorRtVersion",
                "torch_tensorrt==$TorchTensorRtVersion"
            )
        } catch {
            Write-Warn "TensorRT package install failed. RIFE config requests trt=True, so test-rife may fail until TensorRT wheels are available for this Python/CUDA combination."
            Write-Warn $_.Exception.Message
        }
    }
}

function Install-KrigChromaExtension {
    $pythonExe = Join-Path $PythonDir "python.exe"
    $source = Join-Path $AssetsDir "python\fsrcnnx_cudnn"
    $target = Join-Path $PythonDir "Lib\site-packages\fsrcnnx_cudnn"

    if (-not (Test-Path $source)) {
        Write-Warn "KrigBilateral chroma package asset is missing; RIFE will use bilinear chroma fallback."
        return
    }
    if (-not (Test-Path $pythonExe)) {
        throw "Portable Python is missing: $pythonExe"
    }

    Write-Step "Installing prebuilt KrigBilateral chroma extension"
    if ($DryRun) {
        Write-Host "DRY-RUN: copy $source -> $target"
        return
    }

    Ensure-Directory (Split-Path -Parent $target)
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    Ensure-Directory $target
    $nestedTarget = Join-Path $target "fsrcnnx_cudnn"
    Remove-Item -LiteralPath $nestedTarget -Recurse -Force -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $source "*") -Destination $target -Recurse -Force

    $code = @'
import torch
from fsrcnnx_cudnn.chroma_krig import precompile

precompile()
y = torch.full((1, 1, 32, 32), 0.5, device="cuda", dtype=torch.float16)
u = torch.full((1, 1, 16, 16), 0.0, device="cuda", dtype=torch.float16)
v = torch.full((1, 1, 16, 16), 0.0, device="cuda", dtype=torch.float16)
from fsrcnnx_cudnn.chroma_krig import krig_bilateral_chroma
uo, vo = krig_bilateral_chroma(y, u, v, h_out=32, w_out=32)
torch.cuda.synchronize()
assert tuple(uo.shape) == (1, 1, 32, 32)
assert tuple(vo.shape) == (1, 1, 32, 32)
print("krig chroma ok")
'@
    $ok = Test-PythonModule $pythonExe $code -ShowOutput
    if (-not $ok) {
        Write-Warn "KrigBilateral prebuilt extension did not validate; runtime will fall back to bilinear/source-subsampling behavior."
    }
}

function Ensure-RifeModels {
    $pythonExe = Join-Path $PythonDir "python.exe"
    if ($DryRun) {
        Write-Host "DRY-RUN: predownload RIFE 4.26 model"
        return
    }
    if (-not (Test-Path $pythonExe)) {
        throw "Portable Python is missing: $pythonExe"
    }
    $code = @'
from pathlib import Path
from vsrife import model_dir
from vsrife.__main__ import download_model

models = {
    "flownet_v4.26.pkl": "https://github.com/HolyWu/vs-rife/releases/download/model/flownet_v4.26.pkl",
}

root = Path(model_dir)
root.mkdir(parents=True, exist_ok=True)
for name, url in models.items():
    path = root / name
    if path.exists() and path.stat().st_size > 1024 * 1024:
        print(f"{name}: present")
        continue
    if path.exists():
        path.unlink()
    print(f"{name}: downloading")
    download_model(url)
'@
    Write-Step "Checking RIFE model files"
    Ensure-Directory $CacheDir
    $scriptPath = Join-Path $CacheDir ("rife-models-" + [Guid]::NewGuid().ToString("N") + ".py")
    try {
        Set-Content -Path $scriptPath -Value $code -Encoding UTF8
        Invoke-Logged $pythonExe @($scriptPath)
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Install-Danmaku {
    $target = Join-Path $MpvConfigDir "scripts\dandanplay"
    Write-Step "Syncing mpv dandanplay danmaku script from upstream"
    $zip = Join-Path $DownloadsDir "mpv-dandanplay-danmaku-main.zip"
    if ($SkipDownloads -and (Test-Path (Join-Path $target "main.lua")) -and -not (Test-Path $zip)) {
        Write-Step "Danmaku script already exists; -SkipDownloads set and no cached upstream zip found"
        return
    }
    try {
        Download-File $DanmakuZipUrl $zip
    } catch {
        if (Test-Path (Join-Path $target "main.lua")) {
            Write-Warn "Could not update danmaku script from upstream; keeping existing installed copy. $($_.Exception.Message)"
            return
        }
        throw
    }
    $tmp = Join-Path $PortableDir "_danmaku_extract"
    if ((Test-Path $tmp) -and -not $DryRun) {
        Remove-Item -Path $tmp -Recurse -Force
    }
    Expand-Zip $zip $tmp
    if (-not $DryRun) {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        $installPy = Get-ChildItem -Path $tmp -Recurse -File -Filter "install.py" | Select-Object -First 1
        if ($installPy) {
            $pythonExe = Join-Path $PythonDir "python.exe"
            $oldMpvHome = $env:MPV_HOME
            $env:MPV_HOME = $MpvConfigDir
            try {
                Invoke-Logged $pythonExe @($installPy.FullName)
            } finally {
                $env:MPV_HOME = $oldMpvHome
            }
        } else {
            $bundle = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
            Ensure-Directory (Split-Path -Parent $target)
            Copy-Item -Path $bundle.FullName -Destination $target -Recurse -Force
        }
        Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Update-ShimGuiForPortable {
    $gui = Join-Path $PythonDir "Lib\site-packages\jellyfin_mpv_shim\gui_mgr.py"
    if (-not (Test-Path $gui)) {
        return
    }
    Write-Step "Patching shim tray menu for portable server configuration"
    if ($DryRun) {
        Write-Host "DRY-RUN: patch tray menu in $gui"
        return
    }
    $content = Get-Content -Raw -LiteralPath $gui
    $content = [Regex]::Replace(
        $content,
        '(?s)\Afrom PIL import Image\r?\nfrom collections import deque\r?\nimport subprocess\r?\nfrom multiprocessing import Process, Queue\r?\n(?:import threading\r?\n|import sys\r?\n|import logging\r?\n|import queue\r?\n|import os\r?\n|import time\r?\n)+',
@'
from PIL import Image
from collections import deque
import subprocess
from multiprocessing import Process, Queue
import threading
import sys
import logging
import queue
import os
import time

'@
    )
    $patched = $content.Replace(
@'
        def get_wrapper(command):
            def wrapper():
                self.r_queue.put((command, None))

            return wrapper

        def die():
'@,
@'
        def get_wrapper(command):
            def wrapper(*_args):
                self.r_queue.put((command, None))

            return wrapper

        def die(*_args):
'@
    )
    $patched = $patched.Replace(
@'
        def die(*_args):
            # We don't call self.icon_stop() because it crashes on Linux now...
            if sys.platform == "linux":
                # This kills the status icon uncleanly.
                self.r_queue.put(("die", None))
            else:
                self.icon_stop()
'@,
@'
        def die(*_args):
            self.r_queue.put(("die", None))
            if sys.platform != "linux":
                try:
                    self.icon_stop()
                except Exception:
                    pass
'@
    )
    $patched = [Regex]::Replace(
        $patched,
        '(?s)\n        def configure_servers\(\):.*?\n        menu_items = \[',
@'

        menu_items = [
'@
    )
    $patterns = @(
@'
        menu_items = [
            MenuItem(_("Configure Servers"), get_wrapper("show_preferences")),
            MenuItem(_("Show Console"), get_wrapper("show_console")),
            MenuItem(_("Application Menu"), get_wrapper("open_player_menu")),
            MenuItem(_("Open Config Folder"), get_wrapper("open_config_brs")),
            MenuItem(_("Quit"), die),
        ]
'@,
@'
        menu_items = [
            MenuItem(_("Configure Servers"), configure_servers),
            MenuItem(_("Show Console"), get_wrapper("show_console")),
            MenuItem(_("Open Config Folder"), get_wrapper("open_config_brs")),
            MenuItem(_("Quit"), die),
        ]
'@
    )
    $replacement = @'
        menu_items = [
            MenuItem(_("Configure Servers"), get_wrapper("show_preferences")),
            MenuItem(_("Show Console"), get_wrapper("show_console")),
            MenuItem(_("Application Menu"), get_wrapper("open_player_menu")),
            MenuItem(_("Open Config Folder"), get_wrapper("open_config_brs")),
            MenuItem(_("Quit"), die),
        ]
'@
    foreach ($p in $patterns) {
        $patched = $patched.Replace($p, $replacement)
    }
    $patched = $patched.Replace(
@'
            MenuItem(_("Show Console"), get_wrapper("show_console")),
            MenuItem(_("Open Config Folder"), get_wrapper("open_config_brs")),
'@,
@'
            MenuItem(_("Show Console"), get_wrapper("show_console")),
            MenuItem(_("Application Menu"), get_wrapper("open_player_menu")),
            MenuItem(_("Open Config Folder"), get_wrapper("open_config_brs")),
'@
    )
    $patched = $patched.Replace(
@'
    def show_console(self):
        portable_dir = os.path.dirname(os.path.dirname(sys.executable))
        log_dir = os.path.join(portable_dir, "config", "logs")
        log_path = os.path.join(log_dir, "shim_stdout_" + time.strftime("%Y-%m-%d") + ".log")
        if os.path.exists(log_path):
            subprocess.Popen(["notepad.exe", log_path])
        elif os.path.exists(log_dir):
            subprocess.Popen(["explorer.exe", log_dir])
        else:
            log.warning("Portable log path does not exist: %s", log_dir)

    def show_preferences(self):
        portable_dir = os.path.dirname(os.path.dirname(sys.executable))
        python_exe = sys.executable
        config_dir = os.path.join(portable_dir, "config", "jellyfin-mpv-shim")
        code = (
            "import sys;"
            "from jellyfin_mpv_shim import conffile, i18n;"
            "from jellyfin_mpv_shim.conf import settings;"
            "from jellyfin_mpv_shim.constants import APP_NAME;"
            "from jellyfin_mpv_shim.log_utils import configure_log;"
            "from jellyfin_mpv_shim.clients import clientManager;"
            "settings.load(conffile.get(APP_NAME, 'conf.json'));"
            "i18n.configure();"
            "configure_log(sys.stdout, settings.mpv_log_level);"
            "clientManager.cli_connect()"
        )
        args = [python_exe, "-c", code, "--config", config_dir, "add"]
        subprocess.Popen(args, cwd=portable_dir, creationflags=subprocess.CREATE_NEW_CONSOLE)
'@,
@'
    def show_console(self):
        if self.log_window is None or self.log_window.dead:
            self.log_window = LoggerWindow()
            self.log_window.start()

    def show_preferences(self):
        if self.preferences_window is None or self.preferences_window.dead:
            self.preferences_window = PreferencesWindow()
            self.preferences_window.start()
'@
    )
    $patched = $patched.Replace(
@'
import threading
import sys
import logging
import queue
'@,
@'
import threading
import sys
import logging
import queue
import os
import time
'@
    )
    $patched = $patched.Replace(
        'os.path.dirname(os.path.dirname(os.path.dirname(sys.executable)))',
        'os.path.dirname(os.path.dirname(sys.executable))'
    )
    $patched = [Regex]::Replace($patched, "(import os\r?\nimport time\r?\n){2,}", "import os`r`nimport time`r`n")
    $patched = $patched.Replace(
@'
        if not is_logged_in:
            log.warning("No Jellyfin server is connected. Use the tray menu Configure Servers to add one.")
'@,
@'
        if not is_logged_in:
            self.show_preferences()
            self.preferences_window.block_until_close()
'@
    )
    if ($patched -ne $content) {
        Set-Content -LiteralPath $gui -Value $patched -Encoding UTF8
    }
}

function Update-ShimPlayerForPortable {
    $player = Join-Path $PythonDir "Lib\site-packages\jellyfin_mpv_shim\player.py"
    if (-not (Test-Path $player)) {
        return
    }
    Write-Step "Patching shim mpv path/config_dir for portable layout"
    if ($DryRun) {
        Write-Host "DRY-RUN: patch mpv config_dir in $player"
        return
    }
    $content = Get-Content -Raw -LiteralPath $player
    $patched = $content.Replace(
@'
        mpv_location = settings.mpv_ext_path
        if (
'@,
@'
        mpv_location = settings.mpv_ext_path
        if mpv_location and not os.path.isabs(mpv_location):
            portable_dir = os.path.dirname(os.path.dirname(sys.executable))
            candidate = os.path.join(portable_dir, mpv_location)
            if os.path.exists(candidate):
                mpv_location = candidate
        if (
'@
    )
    $patched = $patched.Replace(
@'
            mpv_options["config"] = True
            mpv_options["config_dir"] = conffile.confdir(APP_NAME)
'@,
@'
            mpv_options["config"] = True
            mpv_options["config_dir"] = os.environ.get("MPV_HOME") or conffile.confdir(APP_NAME)
'@
    )
    if ($patched -notmatch 'mpv_options\["log_file"\]') {
        $patched = $patched.Replace(
@'
            mpv_options["config"] = True
            mpv_options["config_dir"] = os.environ.get("MPV_HOME") or conffile.confdir(APP_NAME)
'@,
@'
            mpv_options["config"] = True
            mpv_options["config_dir"] = os.environ.get("MPV_HOME") or conffile.confdir(APP_NAME)
            log_dir = os.path.join(os.path.dirname(mpv_options["config_dir"]), "logs")
            try:
                os.makedirs(log_dir, exist_ok=True)
                mpv_options["log_file"] = os.path.join(log_dir, "mpv.log")
            except Exception:
                log.debug("Could not configure mpv log file", exc_info=True)
'@
        )
    }
    $patched = $patched.Replace(
@'
_mpv_errors = (BrokenPipeError,)
if hasattr(mpv, "ShutdownError"):
    _mpv_errors = (BrokenPipeError, mpv.ShutdownError)
'@,
@'
_mpv_errors = (BrokenPipeError, TimeoutError)
if hasattr(mpv, "ShutdownError"):
    _mpv_errors = _mpv_errors + (mpv.ShutdownError,)
if hasattr(mpv, "MPVError"):
    _mpv_errors = _mpv_errors + (mpv.MPVError,)
'@
    )
    $patched = $patched.Replace(
@'
_mpv_errors = (BrokenPipeError, TimeoutError)
if hasattr(mpv, "ShutdownError"):
    _mpv_errors = (BrokenPipeError, mpv.ShutdownError)
'@,
@'
_mpv_errors = (BrokenPipeError, TimeoutError)
if hasattr(mpv, "ShutdownError"):
    _mpv_errors = _mpv_errors + (mpv.ShutdownError,)
if hasattr(mpv, "MPVError"):
    _mpv_errors = _mpv_errors + (mpv.MPVError,)
'@
    )
    $patched = $patched.Replace(
@'
    def stop_and_close(self):
        log.info("stop_and_close: stopping playback")
        self.stop()
        if not self._mpv_alive:
            return
'@,
@'
    def stop_and_close(self):
        log.info("stop_and_close: stopping playback")
        try:
            self.stop()
        except _mpv_errors:
            self._handle_mpv_disconnect()
            return
        if not self._mpv_alive:
            return
'@
    )
    if ($patched -notmatch 'self\._player\.window_minimized = False') {
        $patched = $patched.Replace(
@'
        self._player.play(self.url)
'@,
@'
        try:
            self._player.force_window = True
            self._player.keep_open = True
            self._player.window_minimized = False
        except _mpv_errors:
            self._handle_mpv_disconnect()
            return
        self._player.play(self.url)
'@
        )
    }
    $patched = $patched.Replace(
@'
        self._mpv_alive = False

    def _terminate_mpv(self):
'@,
@'
        self._mpv_alive = False
        if is_using_ext_mpv and self._player:
            try:
                self._player.terminate(join=False)
            except Exception:
                log.debug("Error terminating disconnected mpv", exc_info=True)

    def _terminate_mpv(self):
'@
    )
    if ($patched -notmatch 'PlayerManager::finished_callback starting next episode: current seq=') {
        $patched = $patched.Replace(
@'
        if not url:
            log.error("PlayerManager::play no URL found")
            return

        self._play_media(video, url, offset, no_initial_timeline, is_initial_play)
'@,
@'
        if not url:
            log.error("PlayerManager::play no URL found")
            return False

        return self._play_media(video, url, offset, no_initial_timeline, is_initial_play)
'@
        )
        $patched = $patched.Replace(
@'
        except _mpv_errors:
            self._handle_mpv_disconnect()
            return
        self._player.play(self.url)
'@,
@'
        except _mpv_errors:
            self._handle_mpv_disconnect()
            return False
        self._video = video
        self._player.play(self.url)
'@
        )
        $patched = $patched.Replace(
@'
            # Timeout playback attempt after 10 seconds
            log.error("Timeout when waiting for media duration. Stopping playback!")
            self.stop()
            return
'@,
@'
            log.error(
                "Timeout when waiting for media duration for item %s (%s). Stopping playback!",
                getattr(video, "item_id", "unknown"),
                video.get_proper_title(),
            )
            self.stop()
            return False
'@
        )
        $patched = $patched.Replace(
@'
                5000,
                1,
            )

    @staticmethod
'@,
@'
                5000,
                1,
            )
        return True

    @staticmethod
'@
        )
        $patched = $patched.Replace(
@'
            if has_lock:
                log.info("PlayerManager::finished_callback starting next episode")
                new_video = self._video.parent.get_next().video
                self.send_timeline_stopped(True)
                if self.syncplay.is_enabled():
                    self.syncplay.request_next(self._video.get_playlist_id())
                else:
                    self.play(new_video)
'@,
@'
            if has_lock:
                old_video = self._video
                old_parent = old_video.parent
                next_media = old_parent.get_next()
                new_video = next_media.video
                log.info(
                    "PlayerManager::finished_callback starting next episode: current seq=%s/%s item=%s title=%r; next seq=%s/%s item=%s title=%r",
                    old_parent.seq + 1,
                    len(old_parent.queue),
                    old_video.item_id,
                    old_video.get_proper_title(),
                    next_media.seq + 1,
                    len(next_media.queue),
                    new_video.item_id,
                    new_video.get_proper_title(),
                )
                self.send_timeline_stopped(True)
                if self.syncplay.is_enabled():
                    self.syncplay.request_next(old_video.get_playlist_id())
                else:
                    if not self.play(new_video):
                        log.error(
                            "PlayerManager::finished_callback failed to start next episode item=%s title=%r",
                            new_video.item_id,
                            new_video.get_proper_title(),
                        )
'@
        )
        $patched = $patched.Replace(
@'
        if self._video.parent.has_next:
            new_video = self._video.parent.get_next().video
            self.send_timeline_stopped(True)
            if self.syncplay.is_enabled():
                self.syncplay.request_next(self._video.get_playlist_id())
            else:
                self.play(new_video)
            return True
'@,
@'
        if self._video.parent.has_next:
            old_video = self._video
            old_parent = old_video.parent
            next_media = old_parent.get_next()
            new_video = next_media.video
            log.info(
                "PlayerManager::play_next: current seq=%s/%s item=%s title=%r; next seq=%s/%s item=%s title=%r",
                old_parent.seq + 1,
                len(old_parent.queue),
                old_video.item_id,
                old_video.get_proper_title(),
                next_media.seq + 1,
                len(next_media.queue),
                new_video.item_id,
                new_video.get_proper_title(),
            )
            self.send_timeline_stopped(True)
            if self.syncplay.is_enabled():
                self.syncplay.request_next(old_video.get_playlist_id())
            else:
                return self.play(new_video)
            return True
'@
        )
    }
    if ($patched -ne $content) {
        Set-Content -LiteralPath $player -Value $patched -Encoding UTF8
    }
}

function Update-ShimActionThreadForRobustness {
    $actionThread = Join-Path $PythonDir "Lib\site-packages\jellyfin_mpv_shim\action_thread.py"
    if (-not (Test-Path $actionThread)) {
        return
    }
    Write-Step "Patching shim action thread to survive mpv IPC timeouts"
    if ($DryRun) {
        Write-Host "DRY-RUN: patch action thread in $actionThread"
        return
    }
    $content = Get-Content -Raw -LiteralPath $actionThread
    $patched = $content.Replace(
@'
import threading

from .player import playerManager
'@,
@'
import threading
import logging

from .player import playerManager

log = logging.getLogger("action_thread")
'@
    )
    $patched = $patched.Replace(
@'
            if playerManager.is_active() or force_next:
                playerManager.update()
'@,
@'
            try:
                if playerManager.is_active() or force_next:
                    playerManager.update()
            except Exception:
                log.exception("ActionThread update failed; keeping action thread alive.")
'@
    )
    if ($patched -ne $content) {
        Set-Content -LiteralPath $actionThread -Value $patched -Encoding UTF8
    }
}

function Update-MpvJsonIpcForWindowsPipe {
    $ipc = Join-Path $PythonDir "Lib\site-packages\python_mpv_jsonipc.py"
    if (-not (Test-Path $ipc)) {
        return
    }
    Write-Step "Patching python_mpv_jsonipc Windows pipe handling"
    if ($DryRun) {
        Write-Host "DRY-RUN: patch Windows pipe handling in $ipc"
        return
    }
    $content = Get-Content -Raw -LiteralPath $ipc
    $patched = $content.Replace(
        '        limit = 5 # Connection may fail at first. Try 5 times.',
        '        limit = 30 # Connection may fail while mpv initializes filters/scripts.'
    )
    $patched = $patched.Replace(
@'
        if os.name == 'nt':
            ipc_socket = "\\\\.\\pipe\\" + ipc_socket
'@,
@'
        if os.name == 'nt':
            ipc_socket = "\\\\.\\pipe\\" + ipc_socket
            ipc_socket_name = ipc_socket
'@
    )
    $patched = $patched.Replace(
@'
        ipc_exists = False
        for _ in range(100): # Give MPV 10 seconds to start.
            time.sleep(0.1)
            self.process.poll()
            if os.path.exists(ipc_socket):
                ipc_exists = True
                log.debug("Found MPV socket.")
                break
            if self.process.returncode is not None:
                log.error("MPV failed with returncode {0}.".format(self.process.returncode))
                break
        else:
            self.process.terminate()
            raise MPVError("MPV start timed out.")
'@,
@'
        ipc_exists = False
        for attempt in range(100): # Give MPV 10 seconds to start.
            time.sleep(0.1)
            self.process.poll()
            if os.name == 'nt':
                # Python's os.path.exists() is unreliable for Windows named pipes.
                # Once mpv has stayed alive briefly, let WindowsSocket do the real
                # connection retry against the pipe.
                if attempt >= 5:
                    ipc_exists = True
                    log.debug("MPV process is alive; deferring Windows pipe connection to MPVInter.")
                    break
            elif os.path.exists(ipc_socket):
                ipc_exists = True
                log.debug("Found MPV socket.")
                break
            if self.process.returncode is not None:
                log.error("MPV failed with returncode {0}.".format(self.process.returncode))
                break
        else:
            self.process.terminate()
            raise MPVError("MPV start timed out.")
'@
    )
    if ($patched -ne $content) {
        Set-Content -LiteralPath $ipc -Value $patched -Encoding UTF8
    }
}

function Write-LauncherScripts {
    Write-Step "Writing portable launcher scripts"
    Ensure-Directory $ScriptsDir
    $startMpvBat = Join-Path $ScriptsDir "start-mpv.bat"
    $startMpvVbs = Join-Path $PortableDir "start-mpv.vbs"
    $shimMpvWrapper = Join-Path $PortableDir "mpv-shim-wrapper.cmd"
    $shimEntryPy = Join-Path $ScriptsDir "shim-entry.py"
    $startShimBat = Join-Path $ScriptsDir "start-shim.bat"
    $startShimPs1 = Join-Path $ScriptsDir "start-shim.ps1"
    $configureServerBat = Join-Path $PortableDir "configure-server.bat"
    $configureServerPs1 = Join-Path $PortableDir "configure-server.ps1"
    $stopShimPs1 = Join-Path $ScriptsDir "stop-shim.ps1"
    $stopShimBat = Join-Path $ScriptsDir "stop-shim.bat"
    $registerMpvAssocPs1 = Join-Path $ScriptsDir "register-mpv-file-association.ps1"
    $registerMpvAssocBat = Join-Path $ScriptsDir "register-mpv-file-association.bat"
    $unregisterMpvAssocPs1 = Join-Path $ScriptsDir "unregister-mpv-file-association.ps1"
    $unregisterMpvAssocBat = Join-Path $ScriptsDir "unregister-mpv-file-association.bat"

    $startMpv = @"
@echo off
set "ROOT=%~dp0.."
set "MPV=%ROOT%\mpv\mpv.exe"
set "CFG=%ROOT%\config\mpv"
set "PY=%ROOT%\python"
set PYTHONHOME=%PY%
set PYTHONPATH=%PY%\Lib\site-packages
set PYTHONIOENCODING=utf-8
set VSSCRIPT_PATH=%PY%\Lib\site-packages\vapoursynth\vsscript.dll
set DANMAKU_CACHE_DIR=%ROOT%\config\cache\danmaku
set RIFE_TRT_CACHE_DIR=%ROOT%\config\cache\rife-trt
set MPV_HOME=%CFG%
set PATH=%PY%;%PY%\Scripts;%PY%\Lib\site-packages;%PY%\Lib\site-packages\vapoursynth;%PY%\Lib\site-packages\torch\lib;%PY%\Lib\site-packages\torch_tensorrt\lib;%PY%\Lib\site-packages\tensorrt_libs;%PATH%
start "" "%MPV%" --config-dir="%CFG%" %*
"@

    $startShimBatText = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0start-shim.ps1"
"@

    $shimEntryText = @"
from jellyfin_mpv_shim.mpv_shim import main

if __name__ == "__main__":
    main()
"@

    $stopShimBatText = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-shim.ps1"
"@

    $registerMpvAssocPs1Text = @'
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PortableDir = Split-Path -Parent $ScriptDir
$StartMpvExe = Join-Path $PortableDir "MPV Portable.exe"
$StartMpvBat = Join-Path $PortableDir "MPV Portable.bat"
$ProgId = "WindowsJellyfinMpvRife.MPV"
$Extensions = @(
    ".mkv", ".mp4", ".m4v", ".mov", ".avi", ".wmv", ".webm", ".flv", ".ts", ".m2ts",
    ".mpg", ".mpeg", ".ogm", ".ogv", ".3gp", ".3g2", ".vob", ".rm", ".rmvb"
)

function Set-DefaultValue {
    param([string]$Path, [string]$Value)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-Item -Path $Path -Value $Value
}

$StartMpvLauncher = if (Test-Path $StartMpvExe) { $StartMpvExe } else { $StartMpvBat }
if (-not (Test-Path $StartMpvLauncher)) { throw "Missing launcher: $StartMpvLauncher" }

$classesRoot = "HKCU:\Software\Classes"
$progRoot = Join-Path $classesRoot $ProgId
Set-DefaultValue $progRoot "MPV Portable"
Set-DefaultValue (Join-Path $progRoot "DefaultIcon") "`"$StartMpvLauncher`",0"
Set-DefaultValue (Join-Path $progRoot "shell\open\command") "`"$StartMpvLauncher`" `"%1`""

$appRoot = "HKCU:\Software\Clients\Media\MPV Portable"
$capRoot = Join-Path $appRoot "Capabilities"
if (-not (Test-Path $capRoot)) {
    New-Item -Path $capRoot -Force | Out-Null
}
Set-ItemProperty -Path $capRoot -Name "ApplicationName" -Value "MPV Portable"
Set-ItemProperty -Path $capRoot -Name "ApplicationDescription" -Value "Portable MPV configured by windows-jellyfin-mpv-rife"
$fileAssocRoot = Join-Path $capRoot "FileAssociations"
if (-not (Test-Path $fileAssocRoot)) {
    New-Item -Path $fileAssocRoot -Force | Out-Null
}

foreach ($ext in $Extensions) {
    $extRoot = Join-Path $classesRoot $ext
    if (-not (Test-Path $extRoot)) {
        New-Item -Path $extRoot -Force | Out-Null
    }
    $openWith = Join-Path $extRoot "OpenWithProgids"
    if (-not (Test-Path $openWith)) {
        New-Item -Path $openWith -Force | Out-Null
    }
    New-ItemProperty -Path $openWith -Name $ProgId -PropertyType String -Value "" -Force | Out-Null
    Set-ItemProperty -Path $fileAssocRoot -Name $ext -Value $ProgId
}

$registeredApps = "HKCU:\Software\RegisteredApplications"
if (-not (Test-Path $registeredApps)) {
    New-Item -Path $registeredApps -Force | Out-Null
}
Set-ItemProperty -Path $registeredApps -Name "MPV Portable" -Value "Software\Clients\Media\MPV Portable\Capabilities"

Write-Host "Registered MPV Portable for current-user Open With entries."
Write-Host "Windows protects default-app selection; choose MPV Portable from Settings > Apps > Default apps, or right-click a video > Open with > Choose another app."
'@

    $registerMpvAssocBatText = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0register-mpv-file-association.ps1"
pause
"@

    $unregisterMpvAssocPs1Text = @'
$ErrorActionPreference = "Stop"
$ProgId = "WindowsJellyfinMpvRife.MPV"
$Extensions = @(
    ".mkv", ".mp4", ".m4v", ".mov", ".avi", ".wmv", ".webm", ".flv", ".ts", ".m2ts",
    ".mpg", ".mpeg", ".ogm", ".ogv", ".3gp", ".3g2", ".vob", ".rm", ".rmvb"
)

$classesRoot = "HKCU:\Software\Classes"
foreach ($ext in $Extensions) {
    $openWith = Join-Path (Join-Path $classesRoot $ext) "OpenWithProgids"
    if (Test-Path $openWith) {
        Remove-ItemProperty -Path $openWith -Name $ProgId -ErrorAction SilentlyContinue
    }
}

$progRoot = Join-Path $classesRoot $ProgId
if (Test-Path $progRoot) {
    Remove-Item -LiteralPath $progRoot -Recurse -Force
}

Remove-ItemProperty -Path "HKCU:\Software\RegisteredApplications" -Name "MPV Portable" -ErrorAction SilentlyContinue
$appRoot = "HKCU:\Software\Clients\Media\MPV Portable"
if (Test-Path $appRoot) {
    Remove-Item -LiteralPath $appRoot -Recurse -Force
}

Write-Host "Unregistered MPV Portable Open With entries for the current user."
Write-Host "If Windows still shows it in Default apps, restart Explorer or sign out and back in."
'@

    $unregisterMpvAssocBatText = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0unregister-mpv-file-association.ps1"
pause
"@

    $rootMpvBatText = @"
@echo off
call "%~dp0scripts\start-mpv.bat" %*
"@

    $rootStartShimBatText = @"
@echo off
call "%~dp0scripts\start-shim.bat"
"@

    $rootStopShimBatText = @"
@echo off
call "%~dp0scripts\stop-shim.bat"
"@

$startShim = @'
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PortableDir = Split-Path -Parent $ScriptDir
$PythonExe = Join-Path $PortableDir "python\python.exe"
$MpvExe = Join-Path $PortableDir "mpv\mpv.exe"
$ConfigDir = Join-Path $PortableDir "config"
$ShimConfigDir = Join-Path $ConfigDir "jellyfin-mpv-shim"
$MpvConfigDir = Join-Path $ConfigDir "mpv"
$LogDir = Join-Path $ConfigDir "logs"
$CacheDir = Join-Path $ConfigDir "cache"
$PidFile = Join-Path $CacheDir "shim.pid"
$Today = Get-Date -Format "yyyy-MM-dd"
$LauncherLog = Join-Path $LogDir "shim_launcher_$Today.log"
$StdOutLog = Join-Path $LogDir "shim_stdout_$Today.log"
$StdErrLog = Join-Path $LogDir "shim_stderr_$Today.log"

function Write-LauncherLog {
    param([string]$Message)
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir | Out-Null
    }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LauncherLog -Value "[$timestamp] $Message" -Encoding UTF8
}

function Test-ShimProcess {
    param([int]$ProcessId)
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
        if (-not $proc -or -not $proc.ExecutablePath) { return $false }
        $actualExe = [System.IO.Path]::GetFullPath($proc.ExecutablePath)
        $expectedExe = [System.IO.Path]::GetFullPath($PythonExe)
        $commandLine = [string]$proc.CommandLine
        return (
            $actualExe.Equals($expectedExe, [System.StringComparison]::OrdinalIgnoreCase) -and
            $commandLine.Contains("shim-entry.py") -and
            $commandLine.Contains($ShimConfigDir)
        )
    } catch {
        return $false
    }
}

try {
    if (-not (Test-Path $PythonExe)) { throw "python.exe not found: $PythonExe" }
    if (-not (Test-Path $MpvExe)) { throw "mpv.exe not found: $MpvExe" }
    if (-not (Test-Path $ShimConfigDir)) { New-Item -ItemType Directory -Path $ShimConfigDir | Out-Null }
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir | Out-Null }

    if (Test-Path $PidFile) {
        $oldPidText = Get-Content -Raw -LiteralPath $PidFile -ErrorAction SilentlyContinue
        $oldPid = 0
        if ([int]::TryParse(($oldPidText -as [string]).Trim(), [ref]$oldPid)) {
            if (Test-ShimProcess $oldPid) {
                Write-LauncherLog "jellyfin-mpv-shim already running, PID=$oldPid"
                exit 0
            }
            Write-LauncherLog "Removing stale shim PID file, PID=$oldPid is not this portable shim"
        }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }

    $PythonDir = Split-Path -Parent $PythonExe
    $env:PYTHONHOME = $PythonDir
    $env:PYTHONPATH = Join-Path $PythonDir "Lib\site-packages"
    $env:PYTHONIOENCODING = "utf-8"
    $env:VSSCRIPT_PATH = Join-Path $PythonDir "Lib\site-packages\vapoursynth\vsscript.dll"
    $env:PATH = "$PythonDir;$(Join-Path $PythonDir 'Scripts');$(Join-Path $PythonDir 'Lib\site-packages');$(Join-Path $PythonDir 'Lib\site-packages\vapoursynth');$(Join-Path $PythonDir 'Lib\site-packages\torch\lib');$(Join-Path $PythonDir 'Lib\site-packages\torch_tensorrt\lib');$(Join-Path $PythonDir 'Lib\site-packages\tensorrt_libs');$env:PATH"
    $env:MPV_HOME = $MpvConfigDir
    $env:DANMAKU_CACHE_DIR = Join-Path $CacheDir "danmaku"
    $env:RIFE_TRT_CACHE_DIR = Join-Path $CacheDir "rife-trt"
    $argList = @(
        (Join-Path $ScriptDir "shim-entry.py"),
        "--gui",
        "--config", $ShimConfigDir
    )

    Write-LauncherLog "Starting shim with config: $ShimConfigDir"
    $proc = Start-Process -FilePath $PythonExe -ArgumentList $argList -WorkingDirectory $PortableDir -RedirectStandardOutput $StdOutLog -RedirectStandardError $StdErrLog -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 3
    if (Test-ShimProcess $proc.Id) {
        Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding ASCII
        Write-LauncherLog "jellyfin-mpv-shim running, PID=$($proc.Id)"
        exit 0
    }
    Write-LauncherLog "jellyfin-mpv-shim exited shortly after launch"
    exit 1
}
catch {
    Write-LauncherLog "ERROR: $($_.Exception.Message)"
    exit 1
}
'@

$stopShim = @'
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PortableDir = Split-Path -Parent $ScriptDir
$PythonExe = Join-Path $PortableDir "python\python.exe"
$ShimConfigDir = Join-Path $PortableDir "config\jellyfin-mpv-shim"
$LogDir = Join-Path $PortableDir "config\logs"
$CacheDir = Join-Path $PortableDir "config\cache"
$PidFile = Join-Path $CacheDir "shim.pid"
$Today = Get-Date -Format "yyyy-MM-dd"
$LauncherLog = Join-Path $LogDir "shim_launcher_$Today.log"

function Write-LauncherLog {
    param([string]$Message)
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $LauncherLog -Value "[$timestamp] $Message" -Encoding UTF8
}

function Test-ShimProcess {
    param([int]$ProcessId)
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
        if (-not $proc -or -not $proc.ExecutablePath) { return $false }
        $actualExe = [System.IO.Path]::GetFullPath($proc.ExecutablePath)
        $expectedExe = [System.IO.Path]::GetFullPath($PythonExe)
        $commandLine = [string]$proc.CommandLine
        return (
            $actualExe.Equals($expectedExe, [System.StringComparison]::OrdinalIgnoreCase) -and
            $commandLine.Contains("shim-entry.py") -and
            $commandLine.Contains($ShimConfigDir)
        )
    } catch {
        return $false
    }
}

$pidText = if (Test-Path $PidFile) { Get-Content -Raw -LiteralPath $PidFile -ErrorAction SilentlyContinue } else { "" }
$procId = 0
if ([int]::TryParse(($pidText -as [string]).Trim(), [ref]$procId) -and (Test-ShimProcess $procId)) {
    Write-LauncherLog "Stopping shim PID=$procId"
    & taskkill.exe /PID $procId /T /F 2>$null | Out-Null
    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
} else {
    Write-LauncherLog "No shim process found"
}
$portablePrefix = [System.IO.Path]::GetFullPath($PortableDir)
Get-Process -ErrorAction SilentlyContinue | Where-Object {
    ($_.ProcessName -eq "mpv" -or $_.ProcessName -eq "python") -and
    $_.Path -and
    ([System.IO.Path]::GetFullPath($_.Path).StartsWith($portablePrefix, [System.StringComparison]::OrdinalIgnoreCase))
} | ForEach-Object {
    Write-LauncherLog "Stopping portable child process $($_.ProcessName) PID=$($_.Id)"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
'@

    if (-not $DryRun) {
        Set-Content -Path $startMpvBat -Value $startMpv -Encoding ASCII
        Set-Content -Path $shimEntryPy -Value $shimEntryText -Encoding ASCII
        Set-Content -Path $startShimBat -Value $startShimBatText -Encoding ASCII
        Set-Content -Path $stopShimBat -Value $stopShimBatText -Encoding ASCII
        Set-Content -Path $startShimPs1 -Value $startShim -Encoding ASCII
        Set-Content -Path $stopShimPs1 -Value $stopShim -Encoding ASCII
        Set-Content -Path $registerMpvAssocPs1 -Value $registerMpvAssocPs1Text -Encoding ASCII
        Set-Content -Path $registerMpvAssocBat -Value $registerMpvAssocBatText -Encoding ASCII
        Set-Content -Path $unregisterMpvAssocPs1 -Value $unregisterMpvAssocPs1Text -Encoding ASCII
        Set-Content -Path $unregisterMpvAssocBat -Value $unregisterMpvAssocBatText -Encoding ASCII
        Set-Content -Path $MpvRootLauncherBat -Value $rootMpvBatText -Encoding ASCII
        Set-Content -Path $StartShimRootLauncherBat -Value $rootStartShimBatText -Encoding ASCII
        Set-Content -Path $StopShimRootLauncherBat -Value $rootStopShimBatText -Encoding ASCII
        Remove-Item -LiteralPath `
            (Join-Path $PortableDir "start-mpv.bat"),
            $startMpvVbs,
            $shimMpvWrapper,
            (Join-Path $PortableDir "shim-entry.py"),
            (Join-Path $PortableDir "start-shim.ps1"),
            (Join-Path $PortableDir "stop-shim.ps1"),
            (Join-Path $PortableDir "register-mpv-file-association.bat"),
            (Join-Path $PortableDir "register-mpv-file-association.ps1"),
            (Join-Path $PortableDir "unregister-mpv-file-association.bat"),
            (Join-Path $PortableDir "unregister-mpv-file-association.ps1"),
            (Join-Path $PortableDir "MPV Portable.lnk"),
            $configureServerBat,
            $configureServerPs1,
            (Join-Path $PortableDir "add-server.bat"),
            (Join-Path $PortableDir "add-server.ps1") -Force -ErrorAction SilentlyContinue
    }
}

function Get-CSharpCompiler {
    $cmd = Get-Command csc.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($path in @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Export-AssociatedIcon {
    param(
        [string]$SourcePath,
        [string]$IconPath
    )
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($SourcePath)
        if (-not $icon) { return $false }
        $stream = [System.IO.File]::Open($IconPath, [System.IO.FileMode]::Create)
        try {
            $icon.Save($stream)
        } finally {
            $stream.Dispose()
            $icon.Dispose()
        }
        return $true
    } catch {
        return $false
    }
}

function Convert-PngToIcon {
    param(
        [string]$PngPath,
        [string]$IconPath
    )
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $bitmap = [System.Drawing.Bitmap]::new($PngPath)
        try {
            $handle = $bitmap.GetHicon()
            $icon = [System.Drawing.Icon]::FromHandle($handle)
            try {
                $stream = [System.IO.File]::Open($IconPath, [System.IO.FileMode]::Create)
                try {
                    $icon.Save($stream)
                } finally {
                    $stream.Dispose()
                }
            } finally {
                $icon.Dispose()
                Add-Type -Namespace NativeMethods -Name User32 -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr hIcon);' -ErrorAction SilentlyContinue
                [NativeMethods.User32]::DestroyIcon($handle) | Out-Null
            }
        } finally {
            $bitmap.Dispose()
        }
        return $true
    } catch {
        return $false
    }
}

function New-PortableLauncherExe {
    param(
        [string]$OutputPath,
        [string]$RelativeTarget,
        [string]$IconPath = $null
    )
    $compiler = Get-CSharpCompiler
    if (-not $compiler) { return $false }

    Ensure-Directory $CacheDir
    $sourcePath = Join-Path $CacheDir ("launcher-" + [Guid]::NewGuid().ToString("N") + ".cs")
    $escapedTarget = $RelativeTarget.Replace("\", "\\").Replace('"', '\"')
    $source = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

internal static class PortableLauncher {
    private const string RelativeTarget = "$escapedTarget";

    private static string Quote(string value) {
        if (String.IsNullOrEmpty(value)) return "\"\"";
        var sb = new StringBuilder();
        sb.Append('"');
        foreach (char c in value) {
            if (c == '\\' || c == '"') sb.Append('\\');
            sb.Append(c);
        }
        sb.Append('"');
        return sb.ToString();
    }

    private static int Main(string[] args) {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string target = Path.GetFullPath(Path.Combine(baseDir, RelativeTarget));
        if (!File.Exists(target)) return 2;
        var psi = new ProcessStartInfo();
        psi.FileName = target;
        psi.WorkingDirectory = baseDir;
        psi.UseShellExecute = true;
        psi.WindowStyle = ProcessWindowStyle.Hidden;
        if (args.Length > 0) {
            var sb = new StringBuilder();
            for (int i = 0; i < args.Length; i++) {
                if (i > 0) sb.Append(' ');
                sb.Append(Quote(args[i]));
            }
            psi.Arguments = sb.ToString();
        }
        Process.Start(psi);
        return 0;
    }
}
"@

    try {
        Set-Content -LiteralPath $sourcePath -Value $source -Encoding ASCII
        $args = @("/nologo", "/target:winexe", "/optimize+", "/out:$OutputPath")
        if ($IconPath -and (Test-Path $IconPath)) {
            $args += "/win32icon:$IconPath"
        }
        $args += $sourcePath
        $compilerOutput = & $compiler @args 2>&1
        $ok = ((Test-Path $OutputPath) -and ($LASTEXITCODE -eq 0))
        if (-not $ok -and $compilerOutput) {
            Write-Warn ("Launcher compiler failed for {0}: {1}" -f (Split-Path -Leaf $OutputPath), ($compilerOutput -join " "))
        }
        return $ok
    } finally {
        Remove-Item -LiteralPath $sourcePath -Force -ErrorAction SilentlyContinue
    }
}

function Create-RootLaunchers {
    Write-Step "Creating portable root launchers"
    if ($DryRun) {
        Write-Host "DRY-RUN: create root launchers"
        return
    }

    $mpvIcon = Join-Path $AssetsDir "icons\mpv.ico"
    $shimIcon = Join-Path $AssetsDir "icons\jellyfin.ico"

    $compiled = $true
    $compiled = (New-PortableLauncherExe $MpvRootLauncherExe "scripts\start-mpv.bat" $mpvIcon) -and $compiled
    $compiled = (New-PortableLauncherExe $StartShimRootLauncherExe "scripts\start-shim.bat" $shimIcon) -and $compiled
    $compiled = (New-PortableLauncherExe $StopShimRootLauncherExe "scripts\stop-shim.bat" $shimIcon) -and $compiled

    if ($compiled) {
        Remove-Item -LiteralPath $MpvRootLauncherBat, $StartShimRootLauncherBat, $StopShimRootLauncherBat -Force -ErrorAction SilentlyContinue
        Write-Host "Created root .exe launchers."
    } else {
        Remove-Item -LiteralPath $MpvRootLauncherExe, $StartShimRootLauncherExe, $StopShimRootLauncherExe -Force -ErrorAction SilentlyContinue
        Write-Warn "C# compiler is not available or launcher build failed; using root .bat launchers instead."
    }
}

function Update-ShimConfig {
    Write-Step "Writing shim config mpv path"
    $conf = Join-Path $ShimConfigDir "conf.json"
    if (-not (Test-Path $conf)) {
        Copy-ExampleIfMissing (Join-Path $ExamplesDir "shim-conf.json.example") $conf
    }
    if ($DryRun) {
        Write-Host "DRY-RUN: update $conf"
        return
    }
    $json = Get-Content $conf -Raw | ConvertFrom-Json
    $setJson = {
        param($Object, [string]$Name, $Value)
        if ($Object.PSObject.Properties.Name -contains $Name) {
            $Object.$Name = $Value
        } else {
            $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
        }
    }
    & $setJson $json "mpv_ext" $true
    & $setJson $json "enable_gui" $true
    & $setJson $json "mpv_ext_no_ovr" $false
    & $setJson $json "mpv_ext_path" "mpv\mpv.exe"
    & $setJson $json "mpv_ext_ipc" $null
    & $setJson $json "screenshot_dir" $null
    & $setJson $json "auto_play" $true
    & $setJson $json "playback_timeout" 60
    # Shim's upstream default remote_kbps=10000 can force remote/reverse-proxy
    # Jellyfin sessions into HLS transcode and lose HDR/color metadata. Seed an
    # effectively unlimited default only when the user has not chosen a cap.
    if (-not ($json.PSObject.Properties.Name -contains "remote_kbps")) {
        & $setJson $json "remote_kbps" 2147483
    }
    $jsonText = $json | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($conf, $jsonText, [System.Text.UTF8Encoding]::new($false))
}

function Remove-LegacyShimMpvCopies {
    Write-Step "Removing legacy copied mpv config from shim config"
    $paths = @(
        "mpv.conf",
        "input.conf",
        "rife-4.26.vpy",
        "scripts",
        "shaders"
    ) | ForEach-Object { Join-Path $ShimConfigDir $_ }
    foreach ($path in $paths) {
        if (Test-Path $path) {
            if ($DryRun) {
                Write-Host "DRY-RUN: remove $path"
            } else {
                Remove-Item -LiteralPath $path -Recurse -Force
            }
        }
    }
}

function Cleanup-Downloads {
    Write-Step "Cleaning generated download/extract caches"
    $paths = @(
        $DownloadsDir,
        (Join-Path $PortableDir "_mpv_extract"),
        (Join-Path $PortableDir "_ffmpeg_extract"),
        (Join-Path $PortableDir "_danmaku_extract"),
        (Join-Path $PortableDir "_tcltk_extract"),
        (Join-Path $PortableDir "_python_layout"),
        (Join-Path $PortableDir "_python_layout_full"),
        (Join-Path $PortableDir "_pyinstaller_extract"),
        (Join-Path $PortableDir "_nuget_check"),
        (Join-Path $PortableDir "_tk_test")
    )
    foreach ($path in $paths) {
        if (Test-Path $path) {
            if ($DryRun) {
                Write-Host "DRY-RUN: remove $path"
            } else {
                Remove-Item -LiteralPath $path -Recurse -Force
            }
        }
    }
    $portablePipIni = Join-Path $PythonDir "pip.ini"
    if (Test-Path $portablePipIni) {
        if ($DryRun) {
            Write-Host "DRY-RUN: remove $portablePipIni"
        } else {
            Remove-Item -LiteralPath $portablePipIni -Force
        }
    }
}

function Cleanup-ObsoleteConfig {
    $legacyRootCache = Join-Path $PortableDir "cache"
    if (Test-Path $legacyRootCache) {
        Write-Step "Removing obsolete portable root cache"
        if ($DryRun) {
            Write-Host "DRY-RUN: remove $legacyRootCache"
        } else {
            Remove-Item -LiteralPath $legacyRootCache -Recurse -Force
        }
    }

    $danmakuDir = Join-Path $ConfigDir "danmaku"
    if (Test-Path $danmakuDir) {
        Write-Step "Removing obsolete config/danmaku"
        if ($DryRun) {
            Write-Host "DRY-RUN: remove $danmakuDir"
        } else {
            Remove-Item -LiteralPath $danmakuDir -Recurse -Force
        }
    }

    foreach ($name in @(
        "rife-4.6-light.vpy",
        "rife-4.6-light-x2.vpy",
        "rife-4.6-light-x3.vpy",
        "rife-4.6-light-x4.vpy"
    )) {
        $path = Join-Path $MpvConfigDir $name
        if (Test-Path $path) {
            Write-Step "Removing obsolete $name"
            if ($DryRun) {
                Write-Host "DRY-RUN: remove $path"
            } else {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }

    $conf = Get-RuntimeConfigMap
    $runtimeUpdates = @{}
    foreach ($key in @("rife_model_720", "rife_model_1080", "rife_model_4k")) {
        if ($conf.Contains($key) -and ([string]$conf[$key]) -match '^4\.6') {
            $runtimeUpdates[$key] = "4.26"
        }
    }
    if ($runtimeUpdates.Count -gt 0) {
        Write-Step "Migrating obsolete RIFE 4.6 runtime profiles to 4.26"
        Set-RuntimeConfigValues $runtimeUpdates
    }
}

function Remove-StaleMpvVapourSynthDlls {
    Write-Step "Removing stale VapourSynth loader DLLs from mpv"
    foreach ($name in @("vsscript.dll", "libvapoursynth.dll")) {
        $path = Join-Path $MpvDir $name
        if (Test-Path $path) {
            if ($DryRun) {
                Write-Host "DRY-RUN: remove $path"
            } else {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }
}

function Sync-VcRuntimeDlls {
    Write-Step "Copying VC runtime DLLs into portable runtime"
    $names = @(
        "vcruntime140.dll",
        "vcruntime140_1.dll",
        "msvcp140.dll",
        "msvcp140_1.dll",
        "msvcp140_2.dll",
        "msvcp140_atomic_wait.dll",
        "msvcp140_codecvt_ids.dll",
        "concrt140.dll"
    )
    $targets = @($PythonDir, $MpvDir)
    foreach ($name in $names) {
        $src = Join-Path $env:SystemRoot "System32\$name"
        if (-not (Test-Path $src)) {
            Write-Warn "VC runtime DLL missing on host: $src"
            continue
        }
        foreach ($target in $targets) {
            $dst = Join-Path $target $name
            if ($DryRun) {
                Write-Host "DRY-RUN: copy $src -> $dst"
            } else {
                try {
                    Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
                } catch {
                    Write-Warn "Could not update $dst; it may be in use. Existing DLL will be kept."
                }
            }
        }
    }
}

function Configure-VapourSynthPython {
    Write-Step "Configuring VapourSynth for portable Python"
    $pythonExe = Join-Path $PythonDir "python.exe"
    $pythonStableDll = Join-Path $PythonDir "python3.dll"
    if (-not (Test-Path $pythonExe)) {
        Write-Warn "python.exe not found for VapourSynth config: $pythonExe"
        return
    }
    if (Test-Path $pythonStableDll) {
        Write-Host "VapourSynth implicit portable Python config detected."
        return
    }
    if ($DryRun) {
        Write-Host "DRY-RUN: run VapourSynth config"
        return
    }
    Set-PortablePythonEnvironment
    & $pythonExe -m vapoursynth config
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "VapourSynth config returned exit code $LASTEXITCODE"
    }
}

function New-RifePrecompileSample {
    param(
        [int]$Width,
        [int]$Height
    )

    $ffmpegExe = Join-Path $ToolsDir "ffmpeg.exe"
    if (-not (Test-Path $ffmpegExe)) {
        throw "ffmpeg.exe is missing. Run install first."
    }

    $sampleDir = Join-Path $CacheDir "precompile"
    Ensure-Directory $sampleDir
    $samplePath = Join-Path $sampleDir ("rife-precompile-{0}x{1}.mp4" -f $Width, $Height)
    if (Test-Path $samplePath) {
        return $samplePath
    }

    Write-Step ("Generating synthetic RIFE precompile sample {0}x{1}" -f $Width, $Height)
    if ($DryRun) {
        Write-Host "DRY-RUN: generate $samplePath"
        return $samplePath
    }

    Invoke-Logged $ffmpegExe @(
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-f", "lavfi",
        "-i", ("testsrc2=size={0}x{1}:rate=30:duration=0.2" -f $Width, $Height),
        "-frames:v", "6",
        "-an",
        "-pix_fmt", "yuv420p",
        "-c:v", "libx264",
        "-preset", "ultrafast",
        $samplePath
    )
    return $samplePath
}

function New-RifeRenderBenchmarkSample {
    param(
        [int]$Width,
        [int]$Height,
        [int]$DurationSeconds = 8
    )

    $ffmpegExe = Join-Path $ToolsDir "ffmpeg.exe"
    if (-not (Test-Path $ffmpegExe)) {
        throw "ffmpeg.exe is missing. Run install first."
    }

    $sampleDir = Join-Path $CacheDir "render-benchmark"
    Ensure-Directory $sampleDir
    $samplePath = Join-Path $sampleDir ("rife-render-{0}x{1}-24fps-{2}s.mp4" -f $Width, $Height, $DurationSeconds)
    if (Test-Path $samplePath) {
        return $samplePath
    }

    Write-Step ("Generating synthetic render benchmark sample {0}x{1} 24fps" -f $Width, $Height)
    if ($DryRun) {
        Write-Host "DRY-RUN: generate $samplePath"
        return $samplePath
    }

    Invoke-Logged $ffmpegExe @(
        "-hide_banner",
        "-loglevel", "error",
        "-y",
        "-f", "lavfi",
        "-i", ("testsrc2=size={0}x{1}:rate=24:duration={2}" -f $Width, $Height, $DurationSeconds),
        "-an",
        "-pix_fmt", "yuv420p",
        "-c:v", "libx264",
        "-preset", "veryfast",
        "-crf", "18",
        $samplePath
    )
    return $samplePath
}

function Invoke-MpvRifePrecompile {
    param(
        [string]$SamplePath,
        [string]$VpyName,
        [string]$Label
    )

    $mpvCli = Join-Path $MpvDir "mpv.com"
    if (-not (Test-Path $mpvCli)) {
        throw "mpv.com is missing. Run install first."
    }

    Write-Step "Precompiling RIFE TensorRT engine: $Label / $VpyName"
    if ($DryRun) {
        Write-Host "DRY-RUN: mpv precompile $Label with $VpyName"
        return
    }

    Ensure-Directory $LogsDir
    $precompileConfigDir = Join-Path $CacheDir "precompile-mpv-config"
    Ensure-Directory $precompileConfigDir
    $trtCacheForVpy = (Join-Path $CacheDir "rife-trt").Replace("\", "/")
    foreach ($name in @(
        "rife-4.26.vpy",
        "rife-4.26-x2.vpy",
        "rife-4.26-x3.vpy",
        "rife-4.26-x4.vpy",
        "rife-4.26-half-x2.vpy",
        "rife-4.26-down1080-x2.vpy",
        "rife-4.26-down1080-x3.vpy",
        "rife-4.26-down1080-x4.vpy"
    )) {
        $src = Join-Path $MpvConfigDir $name
        $dst = Join-Path $precompileConfigDir $name
        if ((Test-Path $src) -and -not $DryRun) {
            $vpyContent = Get-Content -LiteralPath $src -Raw
            $vpyContent = $vpyContent -replace 'trt_cache_dir\s*=\s*Path\(__file__\)\.resolve\(\)\.parents\[1\]\s*/\s*"cache"\s*/\s*"rife-trt"', "trt_cache_dir = Path(r'$trtCacheForVpy')"
            Set-Content -LiteralPath $dst -Value $vpyContent -Encoding UTF8
        }
    }
    $helperSource = Join-Path $MpvConfigDir "vs_gpu_helpers.py"
    if ((Test-Path $helperSource) -and -not $DryRun) {
        Copy-Item -LiteralPath $helperSource -Destination (Join-Path $precompileConfigDir "vs_gpu_helpers.py") -Force
    }
    $commonSource = Join-Path $MpvConfigDir "rife_vpy_common.py"
    if ((Test-Path $commonSource) -and -not $DryRun) {
        Copy-Item -LiteralPath $commonSource -Destination (Join-Path $precompileConfigDir "rife_vpy_common.py") -Force
    }
    $stdoutPath = Join-Path $LogsDir ("rife-precompile-" + [Guid]::NewGuid().ToString("N") + ".out.log")
    $stderrPath = Join-Path $LogsDir ("rife-precompile-" + [Guid]::NewGuid().ToString("N") + ".err.log")
    Set-PortablePythonEnvironment
    $previousInlineTrtBuild = $env:RIFE_ALLOW_INLINE_TRT_BUILD
    $env:RIFE_TRT_CACHE_DIR = (Join-Path $CacheDir "rife-trt")
    $env:RIFE_ALLOW_INLINE_TRT_BUILD = "1"
    try {
        $args = @(
            "--config-dir=$precompileConfigDir",
            "--load-scripts=no",
            "--vo=null",
            "--ao=null",
            "--frames=3",
            "--msg-level=all=v",
            "--vf=vapoursynth=file=~~/$VpyName",
            $SamplePath
        )

        $p = Start-Process -FilePath $mpvCli -ArgumentList $args -WorkingDirectory $ProjectRoot -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $output = ""
        if (Test-Path $stdoutPath) {
            $output += Get-Content -LiteralPath $stdoutPath -Raw
        }
        if (Test-Path $stderrPath) {
            $output += Get-Content -LiteralPath $stderrPath -Raw
        }
        if (($p.ExitCode -ne 0) -or ($output -match "Script evaluation failed|Disabling filter vapoursynth|could not init VS")) {
            Write-Warn "RIFE TensorRT precompile failed. Logs kept for inspection:"
            Write-Warn $stdoutPath
            Write-Warn $stderrPath
            throw "RIFE TensorRT precompile failed for $Label / $VpyName"
        }
    } finally {
        if ($null -eq $previousInlineTrtBuild) {
            Remove-Item Env:\RIFE_ALLOW_INLINE_TRT_BUILD -ErrorAction SilentlyContinue
        } else {
            $env:RIFE_ALLOW_INLINE_TRT_BUILD = $previousInlineTrtBuild
        }
    }

    Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
}

function Precompile-RifeTensorRtEngines {
    if ($SkipRifeTrtPrecompile) {
        Write-Step "Skipping RIFE TensorRT precompile"
        return
    }

    Write-Step "Precompiling common RIFE TensorRT engines"
    Remove-Item -LiteralPath (Join-Path $CacheDir "cache") -Recurse -Force -ErrorAction SilentlyContinue
    $resolutions = @(
        @{ Label = "720p"; Width = 1280; Height = 720 },
        @{ Label = "1080p"; Width = 1920; Height = 1080 },
        @{ Label = "4K"; Width = 3840; Height = 2160 }
    )

    $vpyFiles = @(
        "rife-4.26-x2.vpy",
        "rife-4.26-x3.vpy",
        "rife-4.26-x4.vpy",
        "rife-4.26-half-x2.vpy"
    )
    if ($EnableDownsampled4kVsr) {
        $vpyFiles += @(
            "rife-4.26-down1080-x2.vpy",
            "rife-4.26-down1080-x3.vpy",
            "rife-4.26-down1080-x4.vpy"
        )
    }
    foreach ($resolution in $resolutions) {
        $sample = New-RifePrecompileSample $resolution.Width $resolution.Height
        foreach ($vpy in $vpyFiles) {
            if (($vpy -match "down1080") -and ($resolution.Height -le 1080)) {
                continue
            }
            Invoke-MpvRifePrecompile $sample $vpy $resolution.Label
        }
    }
}

function Get-RuntimeConfigMap {
    $path = Join-Path $MpvConfigDir "runtime.conf"
    $map = [ordered]@{}
    if (Test-Path $path) {
        foreach ($line in Get-Content -LiteralPath $path) {
            if ($line -match '^\s*([A-Za-z0-9_\-]+)\s*=\s*(.*?)\s*$') {
                $map[$Matches[1]] = $Matches[2]
            }
        }
    }
    return $map
}

function Set-RuntimeConfigValues {
    param([hashtable]$Values)

    $path = Join-Path $MpvConfigDir "runtime.conf"
    if (-not (Test-Path $path)) {
        Copy-ExampleIfMissing (Join-Path $ExamplesDir "runtime.conf.example") $path
    }
    if ($DryRun) {
        foreach ($key in $Values.Keys) {
            Write-Host "DRY-RUN: set runtime.conf $key=$($Values[$key])"
        }
        return
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    if (Test-Path $path) {
        foreach ($line in Get-Content -LiteralPath $path) {
            $lines.Add($line)
        }
    }
    foreach ($key in $Values.Keys) {
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") {
                $lines[$i] = "$key=$($Values[$key])"
                $found = $true
                break
            }
        }
        if (-not $found) {
            $lines.Add("$key=$($Values[$key])")
        }
    }
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
}

function Remove-RuntimeConfigKeys {
    param([string[]]$Keys)

    $path = Join-Path $MpvConfigDir "runtime.conf"
    if (-not (Test-Path $path)) {
        return
    }
    if ($DryRun) {
        foreach ($key in $Keys) {
            Write-Host "DRY-RUN: remove runtime.conf $key"
        }
        return
    }

    $patterns = @{}
    foreach ($key in $Keys) {
        $patterns[$key] = "^\s*$([regex]::Escape($key))\s*="
    }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in Get-Content -LiteralPath $path) {
        $remove = $false
        foreach ($pattern in $patterns.Values) {
            if ($line -match $pattern) {
                $remove = $true
                break
            }
        }
        if (-not $remove) {
            $lines.Add($line)
        }
    }
    Set-Content -LiteralPath $path -Value $lines -Encoding UTF8
}

function Add-RuntimeConfigDefaultValues {
    param([hashtable]$Values)

    $existing = Get-RuntimeConfigMap
    $missing = @{}
    foreach ($key in $Values.Keys) {
        if (-not $existing.Contains($key)) {
            $missing[$key] = $Values[$key]
        }
    }
    if ($missing.Count -gt 0) {
        Set-RuntimeConfigValues $missing
    }
}

function Get-WindowsDisplayRefresh {
    try {
        $typeName = "PortableDisplayMode"
        if (-not ($typeName -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class PortableDisplayMode {
    private const int ENUM_CURRENT_SETTINGS = -1;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        private const int CCHDEVICENAME = 32;
        private const int CCHFORMNAME = 32;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCHDEVICENAME)]
        public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCHFORMNAME)]
        public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
    }

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);

    public static DEVMODE Current() {
        DEVMODE mode = new DEVMODE();
        mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        EnumDisplaySettings(null, ENUM_CURRENT_SETTINGS, ref mode);
        return mode;
    }

    public static DEVMODE MaxRefreshAtCurrentResolution() {
        DEVMODE current = Current();
        if (current.dmPelsWidth <= 0 || current.dmPelsHeight <= 0) {
            return current;
        }

        DEVMODE best = current;
        int bestRefresh = current.dmDisplayFrequency;
        for (int i = 0; ; i++) {
            DEVMODE mode = new DEVMODE();
            mode.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(null, i, ref mode)) {
                break;
            }
            if (mode.dmPelsWidth != current.dmPelsWidth ||
                mode.dmPelsHeight != current.dmPelsHeight) {
                continue;
            }
            if (current.dmBitsPerPel > 0 &&
                mode.dmBitsPerPel > 0 &&
                mode.dmBitsPerPel != current.dmBitsPerPel) {
                continue;
            }
            if (mode.dmDisplayFrequency > bestRefresh) {
                best = mode;
                bestRefresh = mode.dmDisplayFrequency;
            }
        }
        return best;
    }
}
"@
        }
        $current = [PortableDisplayMode]::Current()
        $mode = [PortableDisplayMode]::MaxRefreshAtCurrentResolution()
        if ($mode.dmDisplayFrequency -gt 1) {
            $source = "Windows max display mode refresh at current resolution"
            if ($current.dmDisplayFrequency -eq $mode.dmDisplayFrequency) {
                $source = "Windows current display mode"
            }
            return [pscustomobject]@{
                Refresh = [double]$mode.dmDisplayFrequency
                Width = [int]$mode.dmPelsWidth
                Height = [int]$mode.dmPelsHeight
                Source = $source
            }
        }
    } catch {
        Write-Warn "Could not read Windows display refresh: $($_.Exception.Message)"
    }
    return $null
}

function Get-ConfiguredDisplayRefresh {
    $conf = Get-RuntimeConfigMap
    $configured = 0.0
    if ($conf.Contains("display_refresh") -and [double]::TryParse([string]$conf["display_refresh"], [ref]$configured) -and $configured -gt 0) {
        return [pscustomobject]@{
            Refresh = $configured
            Width = $null
            Height = $null
            Source = "runtime.conf display_refresh"
        }
    }
    $detected = Get-WindowsDisplayRefresh
    if ($detected) {
        return $detected
    }
    return [pscustomobject]@{
        Refresh = 60.0
        Width = $null
        Height = $null
        Source = "fallback default"
    }
}

function Invoke-RifeRuntimeBenchmarkCase {
    param(
        [int]$Width,
        [int]$Height,
        [int]$Factor,
        [string]$Model = "4.26",
        [double]$Scale = 1.0,
        [switch]$UseGpuYuv,
        [switch]$DownsampleTo1080,
        [double]$BudgetMs = 41.667,
        [int]$TimeoutSeconds = 900
    )

    $pythonExe = Join-Path $PythonDir "python.exe"
    if (-not (Test-Path $pythonExe)) {
        throw "python.exe is missing. Run install first."
    }

    $scriptPath = Join-Path $CacheDir ("rife-benchmark-" + [Guid]::NewGuid().ToString("N") + ".py")
    $cachePath = (Join-Path $CacheDir "rife-trt").Replace("\", "/")
    $mpvConfigPath = $MpvConfigDir.Replace("\", "\\")
    $useGpuYuvPy = if ($UseGpuYuv) { "True" } else { "False" }
    $downsamplePy = if ($DownsampleTo1080) { "True" } else { "False" }
    $code = @"
import json
import statistics
import time
from pathlib import Path
import sys

import vapoursynth as vs
from vsrife import rife

sys.path.insert(0, r"$mpvConfigPath")
core = vs.core
cache = Path(r"$cachePath")
cache.mkdir(parents=True, exist_ok=True)

clip = core.std.BlankClip(width=$Width, height=$Height, format=vs.YUV420P10, length=320, fpsnum=24, fpsden=1, color=[512, 512, 512])
if ${downsamplePy}:
    from vs_gpu_helpers import downsample_yuvp10_gpu
    target_h = 1080
    target_w = ((clip.width * target_h) // clip.height) & ~1
    clip = downsample_yuvp10_gpu(clip, width=target_w, height=target_h)

if ${useGpuYuvPy}:
    from vs_gpu_helpers import rife_yuv
    clip = rife_yuv(clip, model="$Model", scale=$Scale, factor_num=$Factor, factor_den=1)
else:
    clip = core.resize.Bicubic(clip, format=vs.RGBH, matrix_in_s="709")
    clip = rife(
        clip,
        model="$Model",
        scale=$Scale,
        factor_num=$Factor,
        factor_den=1,
        auto_download=False,
        trt=True,
        trt_cache_dir=str(cache),
    )
    clip = core.resize.Bicubic(clip, format=vs.YUV420P10, matrix_s="709")

for group in range(8):
    base = group * $Factor
    for offset in range($Factor):
        clip.get_frame(base + offset)

samples = []
early_failed = False
for group in range(8, 32):
    base = group * $Factor
    clip.get_frame(base)
    t0 = time.perf_counter()
    for offset in range(1, $Factor):
        clip.get_frame(base + offset)
    samples.append((time.perf_counter() - t0) * 1000.0)
    if len(samples) >= 6:
        quick = sorted(samples)
        quick_p99 = quick[-1]
        quick_mean = statistics.fmean(samples)
        if quick_p99 > ($BudgetMs * 1.35) and quick_mean > ($BudgetMs * 1.10):
            early_failed = True
            break

ordered = sorted(samples)
p99 = ordered[min(len(ordered) - 1, int(len(ordered) * 0.99))]
print(json.dumps({
    "width": $Width,
    "height": $Height,
    "factor": $Factor,
    "model": "$Model",
    "scale": $Scale,
    "group_p99_ms": p99,
    "group_mean_ms": statistics.fmean(samples),
    "inserted_frames_per_group": $Factor - 1,
    "samples": len(samples),
    "early_failed": early_failed,
}))
"@

    if ($DryRun) {
        Write-Host "DRY-RUN: benchmark RIFE $Model scale=$Scale $Width x $Height factor $Factor gpuYuv=$UseGpuYuv down1080=$DownsampleTo1080"
        return @{ width = $Width; height = $Height; factor = $Factor; model = $Model; scale = $Scale; group_p99_ms = 0.0; group_mean_ms = 0.0 }
    }

    Set-PortablePythonEnvironment
    $previousInlineTrtBuild = $env:RIFE_ALLOW_INLINE_TRT_BUILD
    $env:RIFE_ALLOW_INLINE_TRT_BUILD = "1"
    Set-Content -LiteralPath $scriptPath -Value $code -Encoding UTF8
    $stdoutPath = Join-Path $LogsDir ("rife-benchmark-" + [Guid]::NewGuid().ToString("N") + ".out.log")
    $stderrPath = Join-Path $LogsDir ("rife-benchmark-" + [Guid]::NewGuid().ToString("N") + ".err.log")
    try {
        Ensure-Directory $LogsDir
        $p = Start-Process -FilePath $pythonExe -ArgumentList @($scriptPath) -WorkingDirectory $ProjectRoot -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            throw "benchmark timed out after ${TimeoutSeconds}s: RIFE $Model scale=$Scale ${Width}x$Height x$Factor gpuYuv=$UseGpuYuv down1080=$DownsampleTo1080"
        }
        $output = @()
        if (Test-Path $stdoutPath) { $output += Get-Content -LiteralPath $stdoutPath }
        if (Test-Path $stderrPath) { $output += Get-Content -LiteralPath $stderrPath }
        if ($p.ExitCode -ne 0) {
            throw "benchmark python failed: $output"
        }
        $jsonLine = $output | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1
        if (-not $jsonLine) {
            throw "benchmark did not return JSON: $output"
        }
        return ($jsonLine | ConvertFrom-Json)
    } finally {
        if ($null -eq $previousInlineTrtBuild) {
            Remove-Item Env:\RIFE_ALLOW_INLINE_TRT_BUILD -ErrorAction SilentlyContinue
        } else {
            $env:RIFE_ALLOW_INLINE_TRT_BUILD = $previousInlineTrtBuild
        }
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-RenderBenchmarkVsrScale {
    param(
        [int]$Width,
        [int]$Height,
        [switch]$DownsampleTo1080,
        [object]$RefreshInfo
    )

    $targetW = 0
    $targetH = 0
    $conf = Get-RuntimeConfigMap
    if ($conf.Contains("vsr_target_w")) {
        [int]::TryParse([string]$conf["vsr_target_w"], [ref]$targetW) | Out-Null
    }
    if ($conf.Contains("vsr_target_h")) {
        [int]::TryParse([string]$conf["vsr_target_h"], [ref]$targetH) | Out-Null
    }
    if (($targetW -le 0 -or $targetH -le 0) -and $RefreshInfo -and $RefreshInfo.Width -and $RefreshInfo.Height) {
        $targetW = [int]$RefreshInfo.Width
        $targetH = [int]$RefreshInfo.Height
    }
    if ($targetW -le 0 -or $targetH -le 0) {
        $displayInfo = Get-WindowsDisplayRefresh
        if ($displayInfo -and $displayInfo.Width -and $displayInfo.Height) {
            $targetW = [int]$displayInfo.Width
            $targetH = [int]$displayInfo.Height
        }
    }
    if ($targetW -le 0 -or $targetH -le 0) {
        return $null
    }

    $effectiveW = $Width
    $effectiveH = $Height
    if ($DownsampleTo1080 -and $Height -gt 1080) {
        $effectiveH = 1080
        $effectiveW = [int](($Width * $effectiveH) / $Height)
        if (($effectiveW % 2) -eq 1) { $effectiveW -= 1 }
    }
    if (-not (($Width -le 1920 -and $Height -le 1080) -or $DownsampleTo1080)) {
        return $null
    }

    $scale = [Math]::Min($targetW / [double]$effectiveW, $targetH / [double]$effectiveH)
    $scale = [Math]::Floor($scale * 10.0) / 10.0
    if ($scale -gt 4.0) { $scale = 4.0 }
    if ($scale -le 1.0) { return $null }
    return $scale
}

function Invoke-RifeRenderBenchmarkCase {
    param(
        [int]$Width,
        [int]$Height,
        [int]$Factor,
        [string]$Model = "4.26",
        [switch]$DownsampleTo1080,
        [object]$RefreshInfo,
        [int]$DurationSeconds = 8,
        [int]$TimeoutSeconds = 0
    )

    $mpvCli = Join-Path $MpvDir "mpv.com"
    if (-not (Test-Path $mpvCli)) {
        throw "mpv.com is missing. Run install first."
    }

    $samplePath = New-RifeRenderBenchmarkSample $Width $Height $DurationSeconds
    $scriptPath = Join-Path $CacheDir ("render-benchmark-" + [Guid]::NewGuid().ToString("N") + ".lua")
    $stdoutPath = Join-Path $LogsDir ("render-benchmark-" + [Guid]::NewGuid().ToString("N") + ".out.log")
    $stderrPath = Join-Path $LogsDir ("render-benchmark-" + [Guid]::NewGuid().ToString("N") + ".err.log")
    $statsLua = @'
local utils = require("mp.utils")
local msg = require("mp.msg")
local emitted = false

local function nprop(name)
    return mp.get_property_number(name, 0) or 0
end

local function emit_stats()
    if emitted then return end
    emitted = true
    local data = {
        frame_drop_count = nprop("frame-drop-count"),
        mistimed_frame_count = nprop("mistimed-frame-count"),
        vo_delayed_frame_count = nprop("vo-delayed-frame-count"),
        display_fps = nprop("display-fps"),
        estimated_vf_fps = nprop("estimated-vf-fps"),
        container_fps = nprop("container-fps"),
    }
    local line = "RENDER_BENCH_JSON:" .. utils.format_json(data)
    msg.info(line)
    io.stderr:write(line .. "\n")
    io.stderr:flush()
end

mp.register_event("end-file", emit_stats)
mp.register_event("shutdown", emit_stats)
'@

    $maxBadFrames = [Math]::Max(2, [Math]::Ceiling((24 * $Factor * $DurationSeconds) * 0.005))
    if ($TimeoutSeconds -le 0) {
        $TimeoutSeconds = [int][Math]::Ceiling(($DurationSeconds * 2.0) + 10.0)
    }

    if ($DryRun) {
        Write-Host "DRY-RUN: render benchmark RIFE $Model ${Width}x$Height x$Factor down1080=$DownsampleTo1080"
        return [pscustomobject]@{ frame_drop_count = 0; mistimed_frame_count = 0; vo_delayed_frame_count = 0; bad_frame_count = 0; max_bad_frames = $maxBadFrames; timed_out = $false; timeout_seconds = $TimeoutSeconds; passed = $true }
    }

    Ensure-Directory $LogsDir
    Set-Content -LiteralPath $scriptPath -Value $statsLua -Encoding UTF8
    Set-PortablePythonEnvironment
    $renderConfigDir = Join-Path $CacheDir "render-mpv-config"
    Ensure-Directory $renderConfigDir
    foreach ($name in @(
        "rife-4.26.vpy",
        "rife-4.26-x2.vpy",
        "rife-4.26-x3.vpy",
        "rife-4.26-x4.vpy",
        "rife-4.26-half-x2.vpy",
        "rife-4.26-down1080-x2.vpy",
        "rife-4.26-down1080-x3.vpy",
        "rife-4.26-down1080-x4.vpy",
        "rife_vpy_common.py",
        "vs_gpu_helpers.py"
    )) {
        $src = Join-Path $MpvConfigDir $name
        if (Test-Path $src) {
            Copy-Item -LiteralPath $src -Destination (Join-Path $renderConfigDir $name) -Force
        }
    }

    $vpyModel = $Model
    if ($Model -eq "4.26-half") {
        $vpyName = "rife-4.26-half-x2.vpy"
    } elseif ($Model -eq "4.26-down1080") {
        $vpyName = "rife-4.26-down1080-x$Factor.vpy"
    } else {
        $vpyName = "rife-$vpyModel-x$Factor.vpy"
    }
    $vf = "@rife:vapoursynth=file=~~/$vpyName" + ":buffered-frames=12:concurrent-frames=4"
    $vsrScale = Get-RenderBenchmarkVsrScale $Width $Height -DownsampleTo1080:$DownsampleTo1080 -RefreshInfo $RefreshInfo
    if ($vsrScale) {
        $vf += ",@vsr:d3d11vpp=scale=$vsrScale" + ":scaling-mode=nvidia"
    }

    $args = @(
        "--config-dir=$renderConfigDir",
        "--load-scripts=yes",
        "--script=$scriptPath",
        "--no-audio",
        "--keep-open=no",
        "--length=$DurationSeconds",
        "--vo=gpu-next",
        "--gpu-api=d3d11",
        "--gpu-context=d3d11",
        "--hwdec=d3d11va",
        "--profile=gpu-hq",
        "--video-sync=display-resample",
        "--interpolation=no",
        "--tscale=oversample",
        "--scale=ewa_lanczossharp",
        "--cscale=ewa_lanczossharp",
        "--dscale=mitchell",
        "--correct-downscaling=yes",
        "--linear-downscaling=yes",
        "--sigmoid-upscaling=yes",
        "--deband=yes",
        "--target-colorspace-hint=yes",
        "--dither-depth=auto",
        "--msg-level=all=warn,cplayer=info,vf=info",
        "--vf=$vf",
        $samplePath
    )

    try {
        $p = Start-Process -FilePath $mpvCli -ArgumentList $args -WorkingDirectory $renderConfigDir -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -WindowStyle Hidden
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{
                frame_drop_count = 0
                mistimed_frame_count = 0
                vo_delayed_frame_count = 0
                display_fps = 0.0
                estimated_vf_fps = 0.0
                container_fps = 24.0
                bad_frame_count = $maxBadFrames + 1
                max_bad_frames = $maxBadFrames
                timed_out = $true
                timeout_seconds = $TimeoutSeconds
                passed = $false
            }
        }
        $output = @()
        if (Test-Path $stdoutPath) { $output += Get-Content -LiteralPath $stdoutPath }
        if (Test-Path $stderrPath) { $output += Get-Content -LiteralPath $stderrPath }
        if ($p.ExitCode -ne 0) {
            throw "render benchmark mpv failed: $output"
        }
        $jsonLine = $output | Where-Object { $_ -match '^RENDER_BENCH_JSON:' } | Select-Object -Last 1
        if (-not $jsonLine) {
            throw "render benchmark did not return stats: $output"
        }
        $stats = (($jsonLine -replace '^RENDER_BENCH_JSON:', '') | ConvertFrom-Json)
        $badFrames = [int]$stats.frame_drop_count + [int]$stats.mistimed_frame_count + [int]$stats.vo_delayed_frame_count
        $stats | Add-Member -NotePropertyName bad_frame_count -NotePropertyValue $badFrames -Force
        $stats | Add-Member -NotePropertyName max_bad_frames -NotePropertyValue $maxBadFrames -Force
        $stats | Add-Member -NotePropertyName timed_out -NotePropertyValue $false -Force
        $stats | Add-Member -NotePropertyName timeout_seconds -NotePropertyValue $TimeoutSeconds -Force
        $stats | Add-Member -NotePropertyName passed -NotePropertyValue ($badFrames -le $maxBadFrames) -Force
        return $stats
    } finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Measure-RifeRuntimeCapability {
    if (-not $BenchmarkRifeRuntime) {
        return
    }

    Write-Step "Benchmarking local RIFE runtime capability"
    $refreshInfo = Get-ConfiguredDisplayRefresh
    $refresh = [double]$refreshInfo.Refresh
    if ($refreshInfo.Width -and $refreshInfo.Height) {
        Write-Host ("Using display refresh {0:n2}Hz from {1} ({2}x{3})." -f $refresh, $refreshInfo.Source, $refreshInfo.Width, $refreshInfo.Height)
    } else {
        Write-Host ("Using display refresh {0:n2}Hz from {1}." -f $refresh, $refreshInfo.Source)
    }
    $tiers = @(
        @{ Key = "max_factor_720"; Label = "<=720p"; Width = 1280; Height = 720 },
        @{ Key = "max_factor_1080"; Label = "720p<video<=1080p"; Width = 1920; Height = 1080 },
        @{ Key = "max_factor_4k"; Label = "1080p<video<=4K"; Width = 3840; Height = 2160 }
    )
    $values = @{}

    foreach ($tier in $tiers) {
        $best = 0
        $model = "4.26"
        $useDownsample4k = $EnableDownsampled4kVsr -and ($tier.Height -gt 1080)
        if ($useDownsample4k) {
            $model = "4.26-down1080"
        }
        $sourceBudgetMs = 1000.0 / 24.0
        foreach ($factor in @(4, 3, 2)) {
            if ((24 * $factor) -gt ($refresh + 0.01)) {
                continue
            }
            $result = Invoke-RifeRuntimeBenchmarkCase $tier.Width $tier.Height $factor "4.26" 1.0 -UseGpuYuv -DownsampleTo1080:$useDownsample4k -BudgetMs $sourceBudgetMs
            $labelModel = if ($useDownsample4k) { "4.26 down1080" } else { "4.26 gpu-yuv" }
            Write-Host ("{0} {1} x{2}: group-p99={3:n2}ms, source-budget={4:n2}ms" -f $tier.Label, $labelModel, $factor, [double]$result.group_p99_ms, $sourceBudgetMs)
            if ([double]$result.group_p99_ms -le $sourceBudgetMs) {
                $renderModel = if ($useDownsample4k) { "4.26-down1080" } else { "4.26" }
                $render = Invoke-RifeRenderBenchmarkCase $tier.Width $tier.Height $factor $renderModel -DownsampleTo1080:$useDownsample4k -RefreshInfo $refreshInfo
                $timeoutNote = if ($render.timed_out) { ", timeout>{0}s" -f [int]$render.timeout_seconds } else { "" }
                Write-Host ("{0} render {1} x{2}: bad-frames={3}/{4} (drop={5}, mistimed={6}, delayed={7}{8})" -f $tier.Label, $renderModel, $factor, [int]$render.bad_frame_count, [int]$render.max_bad_frames, [int]$render.frame_drop_count, [int]$render.mistimed_frame_count, [int]$render.vo_delayed_frame_count, $timeoutNote)
                if ($render.passed) {
                    $best = $factor
                    break
                }
                Write-Warn ("{0} {1} x{2} passed RIFE compute but failed real render; trying lower factor." -f $tier.Label, $renderModel, $factor)
            }
        }
        if ($best -lt 2) {
            if ($tier.Height -gt 1080 -and (24 * 2) -le ($refresh + 0.01)) {
                $result = Invoke-RifeRuntimeBenchmarkCase $tier.Width $tier.Height 2 "4.26" 0.5 -UseGpuYuv -BudgetMs $sourceBudgetMs
                Write-Host ("{0} 4.26 x2 scale=0.5 fallback: group-p99={1:n2}ms, source-budget={2:n2}ms" -f $tier.Label, [double]$result.group_p99_ms, $sourceBudgetMs)
                if ([double]$result.group_p99_ms -le $sourceBudgetMs) {
                    $render = Invoke-RifeRenderBenchmarkCase $tier.Width $tier.Height 2 "4.26-half" -RefreshInfo $refreshInfo
                    $timeoutNote = if ($render.timed_out) { ", timeout>{0}s" -f [int]$render.timeout_seconds } else { "" }
                    Write-Host ("{0} render 4.26-half x2: bad-frames={1}/{2} (drop={3}, mistimed={4}, delayed={5}{6})" -f $tier.Label, [int]$render.bad_frame_count, [int]$render.max_bad_frames, [int]$render.frame_drop_count, [int]$render.mistimed_frame_count, [int]$render.vo_delayed_frame_count, $timeoutNote)
                    if ($render.passed) {
                        $best = 2
                        $model = "4.26-half"
                    } else {
                        Write-Warn ("{0} 4.26-half x2 passed RIFE compute but failed real render." -f $tier.Label)
                    }
                }
            }
            if ($best -lt 2) {
            $best = 0
            }
        }
        $values[$tier.Key] = $best
        $modelKey = $tier.Key -replace '^max_factor_', 'rife_model_'
        $values[$modelKey] = $model
        Write-Host ("{0}: default RIFE {1} x{2}" -f $tier.Label, $model, $best)
    }

    Set-RuntimeConfigValues $values
}

function Set-PortablePythonEnvironment {
    $pythonExe = Join-Path $PythonDir "python.exe"
    if (Test-Path $pythonExe) {
        $env:PYTHONHOME = $PythonDir
        $env:PYTHONPATH = Join-Path $PythonDir "Lib\site-packages"
        $env:VSSCRIPT_PATH = Join-Path $PythonDir "Lib\site-packages\vapoursynth\vsscript.dll"
        $env:RIFE_TRT_CACHE_DIR = Join-Path $CacheDir "rife-trt"
        $env:PATH = "$PythonDir;$(Join-Path $PythonDir 'Scripts');$(Join-Path $PythonDir 'Lib\site-packages');$(Join-Path $PythonDir 'Lib\site-packages\vapoursynth');$(Join-Path $PythonDir 'Lib\site-packages\torch\lib');$(Join-Path $PythonDir 'Lib\site-packages\torch_tensorrt\lib');$(Join-Path $PythonDir 'Lib\site-packages\tensorrt_libs');$env:PATH"
    }
}

function Test-NvidiaVideoSuperResolution {
    Write-Step "Checking NVIDIA driver and RTX Video Super Resolution"
    $nvidiaSmi = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
    if ($nvidiaSmi) {
        & $nvidiaSmi.Source --query-gpu=name,driver_version --format=csv,noheader
    } else {
        Write-Warn "nvidia-smi.exe was not found in PATH. NVIDIA driver may still be installed, but cannot be verified from this shell."
    }

    $matches = @()
    foreach ($root in @("HKCU:\Software\NVIDIA Corporation", "HKLM:\SOFTWARE\NVIDIA Corporation")) {
        if (-not (Test-Path $root)) {
            continue
        }
        try {
            Get-ChildItem -Path $root -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $item = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
                foreach ($prop in $item.PSObject.Properties) {
                    if ($prop.Name -match "(VSR|Video.*Super|Super.*Resolution|RTX.*Video)") {
                        $matches += [PSCustomObject]@{
                            Path = $_.Name
                            Name = $prop.Name
                            Value = $prop.Value
                        }
                    }
                }
            }
        } catch {
            Write-Warn "Registry scan failed under ${root}: $($_.Exception.Message)"
        }
    }

    if ($matches.Count -eq 0) {
        Write-Warn "Could not confirm RTX Video Super Resolution registry state. Confirm it is enabled in NVIDIA App / NVIDIA Control Panel before relying on driver-level upscaling."
        Write-Warn "This installer will not silently enable another upscaling path."
    } else {
        $matches | Format-Table -AutoSize
        Write-Warn "Review the values above. If RTX Video Super Resolution is off, enable it in NVIDIA App / NVIDIA Control Panel."
    }
}

function Test-Mpv {
    $mpvCli = Join-Path $MpvDir "mpv.com"
    if (-not (Test-Path $mpvCli)) {
        throw "mpv.com is missing. Run install first."
    }
    $sample = Join-Path $ProjectRoot "sample-video\sample-20s.mp4"
    if (-not (Test-Path $sample)) {
        throw "Sample video missing: $sample"
    }
    Set-PortablePythonEnvironment
    Invoke-Logged $mpvCli @("--config-dir=$MpvConfigDir", "--load-scripts=no", "--frames=1", "--no-audio", "--msg-level=all=v", $sample)
}

function Test-Rife {
    $mpvCli = Join-Path $MpvDir "mpv.com"
    $sample = Join-Path $ProjectRoot "sample-video\sample-20s.mp4"
    if (-not (Test-Path $mpvCli)) {
        throw "mpv.com is missing. Run install first."
    }
    if (-not (Test-Path $sample)) {
        throw "Sample video missing: $sample"
    }
    Set-PortablePythonEnvironment
    Invoke-Logged $mpvCli @("--config-dir=$MpvConfigDir", "--load-scripts=no", "--vo=null", "--ao=null", "--frames=3", "--msg-level=all=v", "--vf=vapoursynth=file=~~/rife-4.26.vpy", $sample)
}

function Test-All {
    Test-Mpv
    Test-Rife
    $pythonExe = Join-Path $PythonDir "python.exe"
    Set-PortablePythonEnvironment
    Invoke-Logged $pythonExe @("-m", "pip", "check")
    $ok = Test-PythonModule $pythonExe "import torch, torch_tensorrt, tensorrt, vapoursynth, vsrife`ntorch.ones(1, device='cuda')`nprint('python cuda/vapoursynth/rife ok')" -ShowOutput
    if (-not $ok) {
        throw "Python CUDA/VapourSynth/RIFE import test failed."
    }
}

function Create-StartupShortcut {
    Write-Step "Creating current-user Startup shortcut for jellyfin-mpv-shim"
    $startup = [Environment]::GetFolderPath("Startup")
    $lnk = Join-Path $startup "Jellyfin MPV Shim Portable.lnk"
    $target = if (Test-Path $StartShimRootLauncherExe) { $StartShimRootLauncherExe } else { $StartShimRootLauncherBat }
    if ($DryRun) {
        Write-Host "DRY-RUN: create shortcut $lnk -> $target"
        return
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($lnk)
    $shortcut.TargetPath = $target
    $shortcut.WorkingDirectory = $PortableDir
    $shortcut.WindowStyle = 7
    $shortcut.Description = "Start portable jellyfin-mpv-shim"
    if (Test-Path $target) {
        $shortcut.IconLocation = "$target,0"
    }
    $shortcut.Save()
}

function Remove-StartupShortcut {
    $startup = [Environment]::GetFolderPath("Startup")
    $lnk = Join-Path $startup "Jellyfin MPV Shim Portable.lnk"
    if (Test-Path $lnk) {
        if ($DryRun) {
            Write-Host "DRY-RUN: remove $lnk"
        } else {
            Remove-Item $lnk -Force
        }
    }
}

function Install-All {
    Migrate-LegacyLayout
    Initialize-Layout
    Initialize-Config
    Update-MpvRuntimePolicyConfig
    Test-NvidiaVideoSuperResolution
    Configure-RifeTensorRtForGpu
    Install-Python
    Install-Tkinter
    Install-Mpv
    Install-Ffmpeg
    Install-PythonPackages
    Install-KrigChromaExtension
    Update-VsrifeTensorRtPrecision
    Ensure-RifeModels
    Install-Danmaku
    Sync-VcRuntimeDlls
    Remove-StaleMpvVapourSynthDlls
    Configure-VapourSynthPython
    Precompile-RifeTensorRtEngines
    Measure-RifeRuntimeCapability
    Update-ShimGuiForPortable
    Update-ShimPlayerForPortable
    Update-ShimActionThreadForRobustness
    Update-MpvJsonIpcForWindowsPipe
    Update-ShimConfig
    Remove-LegacyShimMpvCopies
    Cleanup-ObsoleteConfig
    Write-LauncherScripts
    Create-RootLaunchers
    if (-not $KeepDownloads) {
        Cleanup-Downloads
    }
    Write-Step "Install complete"
    Write-Host "Run: .\$PortableName\MPV Portable.exe or .\$PortableName\MPV Portable.bat"
    Write-Host "Run: .\$PortableName\start-shim.exe or .\$PortableName\start-shim.bat"
}

function Show-Status {
    Migrate-LegacyLayout
    Initialize-Layout
    Test-NvidiaVideoSuperResolution
    $mpvRootItem = if (Test-Path $MpvRootLauncherExe) { $MpvRootLauncherExe } else { $MpvRootLauncherBat }
    $startShimRootItem = if (Test-Path $StartShimRootLauncherExe) { $StartShimRootLauncherExe } else { $StartShimRootLauncherBat }
    $stopShimRootItem = if (Test-Path $StopShimRootLauncherExe) { $StopShimRootLauncherExe } else { $StopShimRootLauncherBat }
    $items = @(
        (Join-Path $PortableDir "mpv\mpv.exe"),
        (Join-Path $PortableDir "python\python.exe"),
        (Join-Path $ConfigDir "mpv\mpv.conf"),
        (Join-Path $ConfigDir "jellyfin-mpv-shim\conf.json"),
        $mpvRootItem,
        $startShimRootItem,
        $stopShimRootItem,
        (Join-Path $ScriptsDir "start-shim.ps1")
    )
    foreach ($item in $items) {
        if (Test-Path $item) {
            Write-Host "[ok] $item"
        } else {
            Write-Warn "Missing: $item"
        }
    }
}

function Uninstall-Portable {
    Migrate-LegacyLayout
    Write-Step "Removing generated portable runtime while preserving config"
    if (Test-Path $PortableDir) {
        $runtimePaths = @(
            (Join-Path $PortableDir "mpv"),
            (Join-Path $PortableDir "python"),
            (Join-Path $PortableDir "tools"),
            (Join-Path $PortableDir "scripts"),
            (Join-Path $PortableDir "_downloads"),
            (Join-Path $PortableDir "_mpv_extract"),
            (Join-Path $PortableDir "_ffmpeg_extract"),
            (Join-Path $PortableDir "_danmaku_extract"),
            (Join-Path $PortableDir "start-mpv.bat"),
            (Join-Path $PortableDir "start-mpv.vbs"),
            $MpvRootLauncherExe,
            $MpvRootLauncherBat,
            (Join-Path $PortableDir "MPV Portable.lnk"),
            $StartShimRootLauncherExe,
            $StartShimRootLauncherBat,
            $StopShimRootLauncherExe,
            $StopShimRootLauncherBat,
            (Join-Path $PortableDir "register-mpv-file-association.bat"),
            (Join-Path $PortableDir "register-mpv-file-association.ps1"),
            (Join-Path $PortableDir "unregister-mpv-file-association.bat"),
            (Join-Path $PortableDir "unregister-mpv-file-association.ps1"),
            (Join-Path $PortableDir "mpv-shim-wrapper.cmd"),
            (Join-Path $PortableDir "shim-entry.py"),
            (Join-Path $PortableDir "start-shim.bat"),
            (Join-Path $PortableDir "start-shim.ps1"),
            (Join-Path $PortableDir "add-server.bat"),
            (Join-Path $PortableDir "add-server.ps1"),
            (Join-Path $PortableDir "configure-server.bat"),
            (Join-Path $PortableDir "configure-server.ps1"),
            (Join-Path $PortableDir "stop-shim.bat"),
            (Join-Path $PortableDir "stop-shim.ps1")
        )
        foreach ($path in $runtimePaths) {
            if (Test-Path $path) {
                if ($DryRun) {
                    Write-Host "DRY-RUN: remove $path"
                } else {
                    Remove-Item -LiteralPath $path -Recurse -Force
                }
            }
        }
    }
    if ($PurgeConfig -and (Test-Path $ConfigDir)) {
        Write-Warn "Purging persistent config because -PurgeConfig was specified"
        if ($DryRun) {
            Write-Host "DRY-RUN: remove $ConfigDir"
        } else {
            Remove-Item -Path $ConfigDir -Recurse -Force
        }
    }
    if ((Test-Path $PortableDir) -and -not (Get-ChildItem -LiteralPath $PortableDir -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $PortableDir -Force -ErrorAction SilentlyContinue
    }
}

switch ($Command) {
    "install" { Install-All }
    "status" { Show-Status }
    "uninstall" { Uninstall-Portable }
    "cleanup" { Cleanup-Downloads; Cleanup-ObsoleteConfig; Remove-LegacyShimMpvCopies }
    "test-mpv" { Test-Mpv }
    "test-rife" { Test-Rife }
    "test-all" { Test-All }
    "start-shim" { & (Join-Path $ScriptsDir "start-shim.ps1") }
    "stop-shim" { & (Join-Path $ScriptsDir "stop-shim.ps1") }
    "create-startup" { Create-StartupShortcut }
    "remove-startup" { Remove-StartupShortcut }
}
