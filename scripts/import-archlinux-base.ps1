param(
    [string]$Image = "archlinux",
    [string]$Tag = "latest",
    [string]$MirrorUrl = "https://mirrors.tuna.tsinghua.edu.cn/archlinux/iso/latest/archlinux-bootstrap-x86_64.tar.zst",
    [string]$WslDistro = "kali-linux",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function ConvertTo-WslPath {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $drive = $full.Substring(0, 1).ToLowerInvariant()
    $rest = $full.Substring(2).Replace("\", "/")
    return "/mnt/$drive$rest"
}

function Invoke-Native {
    param([string[]]$Command)
    & $Command[0] @($Command | Select-Object -Skip 1)
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed (exit $LASTEXITCODE): $($Command -join ' ')"
    }
}

docker info *> $null
if ($LASTEXITCODE -ne 0) {
    throw "Docker daemon is not available."
}

$imageRef = "${Image}:${Tag}"
if (-not $Force) {
    docker image inspect $imageRef *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Local image ${imageRef} already exists; use -Force to reimport."
        exit 0
    }
}

$temp = Join-Path $env:TEMP "dsh-archlinux-import-$PID"
New-Item -ItemType Directory -Force -Path $temp | Out-Null

try {
    $zst = Join-Path $temp "archlinux-bootstrap.tar.zst"
    $tar = Join-Path $temp "archlinux-bootstrap.tar"
    $rootfs = Join-Path $temp "archlinux-rootfs.tar"

    Write-Host "Downloading Arch Linux bootstrap from $MirrorUrl"
    curl.exe -fL --retry 3 -o $zst $MirrorUrl
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to download Arch Linux bootstrap."
    }

    python -c "import zstandard" *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Installing Python zstandard..."
        python -m pip install zstandard -i https://pypi.tuna.tsinghua.edu.cn/simple
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install Python zstandard."
        }
    }

    $decompress = @"
import zstandard
from pathlib import Path
src = Path(r"$zst")
dst = Path(r"$tar")
with open(src, "rb") as src_file:
    reader = zstandard.ZstdDecompressor().stream_reader(src_file)
    with open(dst, "wb") as dst_file:
        while True:
            chunk = reader.read(1024 * 1024)
            if not chunk:
                break
            dst_file.write(chunk)
print("decompressed", dst.stat().st_size)
"@
    $decompress | python -
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to decompress Arch Linux bootstrap."
    }

    $wslTar = ConvertTo-WslPath $tar
    $wslRootfs = ConvertTo-WslPath $rootfs
    $wslExtract = "/tmp/dsh-archlinux-import-$PID"
    $wslScript = "set -e; rm -rf '$wslExtract'; mkdir -p '$wslExtract'; tar -xf '$wslTar' -C '$wslExtract'; tar -C '$wslExtract/root.x86_64' -cf '$wslRootfs' ."

    Write-Host "Repacking rootfs with WSL ($WslDistro)..."
    wsl -d $WslDistro -u root bash -c $wslScript
    if ($LASTEXITCODE -ne 0) {
        throw "WSL repack failed."
    }

    Write-Host "Importing local Docker image ${imageRef}..."
    docker import $rootfs $imageRef
    if ($LASTEXITCODE -ne 0) {
        throw "docker import failed."
    }

    Write-Host "Imported ${imageRef}."
}
finally {
    if (Test-Path -LiteralPath $temp) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
