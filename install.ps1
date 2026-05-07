param(
    [ValidateSet("install", "status", "uninstall", "cleanup", "test-mpv", "test-rife", "test-all", "start-shim", "stop-shim", "create-startup", "remove-startup")]
    [string]$Command = "install",
    [switch]$DryRun,
    [switch]$SkipDownloads,
    [switch]$KeepDownloads,
    [switch]$PurgeConfig,
    [switch]$EnableGlslUpscaleFallback,
    [switch]$SkipRifeTrtPrecompile
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
    Copy-ExampleIfMissing (Join-Path $ExamplesDir "mpv.conf.example") (Join-Path $MpvConfigDir "mpv.conf")
    Copy-ExampleIfMissing (Join-Path $ExamplesDir "input.conf.example") (Join-Path $MpvConfigDir "input.conf")
    Copy-ExampleIfMissing (Join-Path $ExamplesDir "rife-4.26.vpy.example") (Join-Path $MpvConfigDir "rife-4.26.vpy")
    Copy-ExampleIfMissing (Join-Path $ExamplesDir "rife-4.6-light.vpy.example") (Join-Path $MpvConfigDir "rife-4.6-light.vpy")
    Copy-ExampleIfMissing (Join-Path $ExamplesDir "shim-conf.json.example") (Join-Path $ShimConfigDir "conf.json")
    Ensure-Directory (Join-Path $MpvConfigDir "scripts")
    Copy-Item -LiteralPath (Join-Path $ExamplesDir "autovsr.lua.example") -Destination (Join-Path $MpvConfigDir "scripts\autovsr.lua") -Force

    $shaderSource = Join-Path $AssetsDir "shaders\FSRCNNX_x2_8-0-4-1.glsl"
    $shaderTargetDir = Join-Path $MpvConfigDir "shaders"
    if ((Test-Path $shaderSource) -and $EnableGlslUpscaleFallback) {
        Ensure-Directory $shaderTargetDir
        Copy-ExampleIfMissing $shaderSource (Join-Path $shaderTargetDir "FSRCNNX_x2_8-0-4-1.glsl")
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

    Set-RifeTensorRtInFile (Join-Path $MpvConfigDir "rife-4.26.vpy") $true
    Set-RifeTensorRtInFile (Join-Path $MpvConfigDir "rife-4.6-light.vpy") $true
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

function Ensure-RifeModels {
    $pythonExe = Join-Path $PythonDir "python.exe"
    if ($DryRun) {
        Write-Host "DRY-RUN: predownload RIFE 4.26 and 4.6 models"
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
    "flownet_v4.6.pkl": "https://github.com/HolyWu/vs-rife/releases/download/model/flownet_v4.6.pkl",
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
    Download-File $DanmakuZipUrl $zip
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
    $startMpvBat = Join-Path $PortableDir "start-mpv.bat"
    $startMpvVbs = Join-Path $PortableDir "start-mpv.vbs"
    $shimMpvWrapper = Join-Path $PortableDir "mpv-shim-wrapper.cmd"
    $shimEntryPy = Join-Path $PortableDir "shim-entry.py"
    $startShimBat = Join-Path $PortableDir "start-shim.bat"
    $startShimPs1 = Join-Path $PortableDir "start-shim.ps1"
    $configureServerBat = Join-Path $PortableDir "configure-server.bat"
    $configureServerPs1 = Join-Path $PortableDir "configure-server.ps1"
    $stopShimPs1 = Join-Path $PortableDir "stop-shim.ps1"
    $stopShimBat = Join-Path $PortableDir "stop-shim.bat"

    $startMpv = @"
@echo off
set ROOT=%~dp0
set MPV=%~dp0mpv\mpv.exe
set CFG=%~dp0config\mpv
set PY=%~dp0python
set PYTHONHOME=%PY%
set PYTHONPATH=%PY%\Lib\site-packages
set PYTHONIOENCODING=utf-8
set VSSCRIPT_PATH=%PY%\Lib\site-packages\vapoursynth\vsscript.dll
set DANMAKU_CACHE_DIR=%~dp0config\cache\danmaku
set MPV_HOME=%CFG%
set PATH=%PY%;%PY%\Scripts;%PY%\Lib\site-packages;%PY%\Lib\site-packages\vapoursynth;%PY%\Lib\site-packages\torch\lib;%PY%\Lib\site-packages\torch_tensorrt\lib;%PY%\Lib\site-packages\tensorrt_libs;%PATH%
start "" "%MPV%" --config-dir="%CFG%" %*
"@

    $startShimBatText = @"
@echo off
pwsh.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0start-shim.ps1"
"@

    $shimEntryText = @"
from jellyfin_mpv_shim.mpv_shim import main

if __name__ == "__main__":
    main()
"@

    $stopShimBatText = @"
@echo off
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-shim.ps1"
"@

    $startShim = @'
$ErrorActionPreference = "Stop"
$PortableDir = Split-Path -Parent $MyInvocation.MyCommand.Path
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

try {
    if (-not (Test-Path $PythonExe)) { throw "python.exe not found: $PythonExe" }
    if (-not (Test-Path $MpvExe)) { throw "mpv.exe not found: $MpvExe" }
    if (-not (Test-Path $ShimConfigDir)) { New-Item -ItemType Directory -Path $ShimConfigDir | Out-Null }
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir | Out-Null }

    if (Test-Path $PidFile) {
        $oldPidText = Get-Content -Raw -LiteralPath $PidFile -ErrorAction SilentlyContinue
        $oldPid = 0
        if ([int]::TryParse(($oldPidText -as [string]).Trim(), [ref]$oldPid)) {
            if (Get-Process -Id $oldPid -ErrorAction SilentlyContinue) {
                Write-LauncherLog "jellyfin-mpv-shim already running, PID=$oldPid"
                exit 0
            }
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
    $argList = @(
        (Join-Path $PortableDir "shim-entry.py"),
        "--gui",
        "--config", $ShimConfigDir
    )

    Write-LauncherLog "Starting shim with config: $ShimConfigDir"
    $proc = Start-Process -FilePath $PythonExe -ArgumentList $argList -WorkingDirectory $PortableDir -RedirectStandardOutput $StdOutLog -RedirectStandardError $StdErrLog -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 3
    if (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue) {
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
$PortableDir = Split-Path -Parent $MyInvocation.MyCommand.Path
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

$pidText = if (Test-Path $PidFile) { Get-Content -Raw -LiteralPath $PidFile -ErrorAction SilentlyContinue } else { "" }
$procId = 0
if ([int]::TryParse(($pidText -as [string]).Trim(), [ref]$procId) -and (Get-Process -Id $procId -ErrorAction SilentlyContinue)) {
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
        Remove-Item -LiteralPath $startMpvVbs, $shimMpvWrapper, $configureServerBat, $configureServerPs1, (Join-Path $PortableDir "add-server.bat"), (Join-Path $PortableDir "add-server.ps1") -Force -ErrorAction SilentlyContinue
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
    $json | ConvertTo-Json -Depth 20 | Set-Content -Path $conf -Encoding UTF8
}

function Remove-LegacyShimMpvCopies {
    Write-Step "Removing legacy copied mpv config from shim config"
    $paths = @(
        "mpv.conf",
        "input.conf",
        "rife-4.26.vpy",
        "rife-4.6-light.vpy",
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
    $danmakuDir = Join-Path $ConfigDir "danmaku"
    if (Test-Path $danmakuDir) {
        Write-Step "Removing obsolete config/danmaku"
        if ($DryRun) {
            Write-Host "DRY-RUN: remove $danmakuDir"
        } else {
            Remove-Item -LiteralPath $danmakuDir -Recurse -Force
        }
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
    foreach ($name in @("rife-4.26.vpy", "rife-4.6-light.vpy")) {
        $src = Join-Path $MpvConfigDir $name
        $dst = Join-Path $precompileConfigDir $name
        if ((Test-Path $src) -and -not $DryRun) {
            $vpyContent = Get-Content -LiteralPath $src -Raw
            $vpyContent = $vpyContent -replace 'trt_cache_dir\s*=\s*Path\(__file__\)\.resolve\(\)\.parents\[1\]\s*/\s*"cache"\s*/\s*"rife-trt"', "trt_cache_dir = Path(r'$trtCacheForVpy')"
            Set-Content -LiteralPath $dst -Value $vpyContent -Encoding UTF8
        }
    }
    $stdoutPath = Join-Path $LogsDir ("rife-precompile-" + [Guid]::NewGuid().ToString("N") + ".out.log")
    $stderrPath = Join-Path $LogsDir ("rife-precompile-" + [Guid]::NewGuid().ToString("N") + ".err.log")
    Set-PortablePythonEnvironment
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
        "rife-4.26.vpy",
        "rife-4.6-light.vpy"
    )
    foreach ($resolution in $resolutions) {
        $sample = New-RifePrecompileSample $resolution.Width $resolution.Height
        foreach ($vpy in $vpyFiles) {
            Invoke-MpvRifePrecompile $sample $vpy $resolution.Label
        }
    }
}

function Set-PortablePythonEnvironment {
    $pythonExe = Join-Path $PythonDir "python.exe"
    if (Test-Path $pythonExe) {
        $env:PYTHONHOME = $PythonDir
        $env:PYTHONPATH = Join-Path $PythonDir "Lib\site-packages"
        $env:VSSCRIPT_PATH = Join-Path $PythonDir "Lib\site-packages\vapoursynth\vsscript.dll"
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
        Write-Warn "This installer will not silently enable GLSL upscaling. Use -EnableGlslUpscaleFallback only for manual debugging."
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
    Invoke-Logged $mpvCli @("--config-dir=$MpvConfigDir", "--frames=1", "--no-audio", "--msg-level=all=v", $sample)
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
    $target = Join-Path $PortableDir "start-shim.bat"
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
    Test-NvidiaVideoSuperResolution
    Configure-RifeTensorRtForGpu
    Install-Python
    Install-Tkinter
    Install-Mpv
    Install-Ffmpeg
    Install-PythonPackages
    Update-VsrifeTensorRtPrecision
    Ensure-RifeModels
    Install-Danmaku
    Sync-VcRuntimeDlls
    Remove-StaleMpvVapourSynthDlls
    Configure-VapourSynthPython
    Precompile-RifeTensorRtEngines
    Update-ShimGuiForPortable
    Update-ShimPlayerForPortable
    Update-ShimActionThreadForRobustness
    Update-MpvJsonIpcForWindowsPipe
    Update-ShimConfig
    Remove-LegacyShimMpvCopies
    Cleanup-ObsoleteConfig
    Write-LauncherScripts
    if (-not $KeepDownloads) {
        Cleanup-Downloads
    }
    Write-Step "Install complete"
    Write-Host "Run: .\$PortableName\start-mpv.bat .\sample-video\sample-20s.mp4"
    Write-Host "Run: .\$PortableName\start-shim.bat"
}

function Show-Status {
    Migrate-LegacyLayout
    Initialize-Layout
    Test-NvidiaVideoSuperResolution
    $items = @(
        (Join-Path $PortableDir "mpv\mpv.exe"),
        (Join-Path $PortableDir "python\python.exe"),
        (Join-Path $ConfigDir "mpv\mpv.conf"),
        (Join-Path $ConfigDir "jellyfin-mpv-shim\conf.json"),
        (Join-Path $PortableDir "start-shim.ps1")
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
            (Join-Path $PortableDir "_downloads"),
            (Join-Path $PortableDir "_mpv_extract"),
            (Join-Path $PortableDir "_ffmpeg_extract"),
            (Join-Path $PortableDir "_danmaku_extract"),
            (Join-Path $PortableDir "start-mpv.bat"),
            (Join-Path $PortableDir "start-mpv.vbs"),
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
    "start-shim" { & (Join-Path $PortableDir "start-shim.ps1") }
    "stop-shim" { & (Join-Path $PortableDir "stop-shim.ps1") }
    "create-startup" { Create-StartupShortcut }
    "remove-startup" { Remove-StartupShortcut }
}
