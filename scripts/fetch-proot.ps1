# Fetch Termux proot binary AND its libtalloc dependency, place both in
# jniLibs as libproot.so + libtalloc.so. The runtime manager copies them to
# files dir at startup with the right soname so the dynamic linker resolves
# libtalloc.so.2.
#
# Run this once after cloning. The Gradle build also runs it automatically.

$ErrorActionPreference = "Stop"

$PRoot_Version = "5.1.107.77"
$Talloc_Version = "2.4.3"
$Arch = "aarch64"
$JniArch = "arm64-v8a"

$Packages = @(
    @{
        Url = "https://packages.termux.dev/apt/termux-main/pool/main/p/proot/proot_${PRoot_Version}_${Arch}.deb"
        BinaryName = "proot"
        OutName = "libproot.so"
    },
    @{
        Url = "https://packages.termux.dev/apt/termux-main/pool/main/libt/libtalloc/libtalloc_${Talloc_Version}_${Arch}.deb"
        BinaryName = "libtalloc.so.2"
        OutName = "libtalloc.so"
    }
)

$RepoRoot = Split-Path -Parent $PSScriptRoot
$JniLibsDir = Join-Path $RepoRoot "android\app\src\main\jniLibs\$JniArch"
New-Item -ItemType Directory -Force -Path $JniLibsDir | Out-Null

$AllPresent = $true
foreach ($pkg in $Packages) {
    $outPath = Join-Path $JniLibsDir $pkg.OutName
    if (-not (Test-Path $outPath)) { $AllPresent = $false; break }
}
if ($AllPresent) {
    Write-Host "[OK] proot + libtalloc already present in jniLibs. Delete to re-fetch." -ForegroundColor Green
    exit 0
}

$winTar = Join-Path $env:SystemRoot "System32\tar.exe"
if (-not (Test-Path $winTar)) { $winTar = "tar" }

foreach ($pkg in $Packages) {
    $outPath = Join-Path $JniLibsDir $pkg.OutName
    if (Test-Path $outPath) {
        Write-Host "[skip] $($pkg.OutName) already present" -ForegroundColor DarkGray
        continue
    }

    $TmpDir = Join-Path $env:TEMP "meow_proot_fetch_$(Get-Random)"
    New-Item -ItemType Directory -Force -Path $TmpDir | Out-Null
    $debPath = Join-Path $TmpDir "package.deb"

    try {
        Write-Host "Downloading $($pkg.BinaryName) from Termux..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $pkg.Url -OutFile $debPath -UseBasicParsing
        $debSize = (Get-Item $debPath).Length
        Write-Host "  Got $debSize bytes" -ForegroundColor DarkGray

        $bytes = [System.IO.File]::ReadAllBytes($debPath)
        $magic = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 8)
        if ($magic -ne "!<arch>`n") {
            throw "Not a valid .deb archive (got '$magic')"
        }

        $pos = 8
        $dataTarPath = $null
        while ($pos -lt $bytes.Length) {
            $name = [System.Text.Encoding]::ASCII.GetString($bytes, $pos, 16).Trim().TrimEnd('/')
            $sizeStr = [System.Text.Encoding]::ASCII.GetString($bytes, $pos + 48, 10).Trim()
            $memberSize = [int]$sizeStr
            $contentStart = $pos + 60

            if ($name.StartsWith("data.tar")) {
                $ext = $name.Substring(4)
                $dataTarPath = Join-Path $TmpDir "data$ext"
                $slice = New-Object byte[] $memberSize
                [Array]::Copy($bytes, $contentStart, $slice, 0, $memberSize)
                [System.IO.File]::WriteAllBytes($dataTarPath, $slice)
                break
            }

            $pos = $contentStart + $memberSize
            if ($memberSize % 2 -ne 0) { $pos++ }
        }

        if (-not $dataTarPath) {
            throw "Could not find data.tar member inside .deb"
        }

        $extractDir = Join-Path $TmpDir "extracted"
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        & $winTar -xf $dataTarPath -C $extractDir
        if ($LASTEXITCODE -ne 0) {
            throw "tar extraction failed."
        }

        # Find binary by name. libtalloc.so.2 may exist as a symlink with
        # the actual file named differently — handle that.
        $src = Get-ChildItem -Path $extractDir -Recurse -File |
            Where-Object { $_.Name -eq $pkg.BinaryName -or $_.Name -like "$($pkg.BinaryName)*" } |
            Sort-Object Length -Descending |
            Select-Object -First 1
        if (-not $src) {
            throw "$($pkg.BinaryName) not found in extracted .deb"
        }

        Copy-Item -Path $src.FullName -Destination $outPath -Force
        $finalSize = (Get-Item $outPath).Length
        Write-Host "[OK] $($pkg.OutName) ($finalSize bytes)" -ForegroundColor Green
    }
    finally {
        if (Test-Path $TmpDir) {
            Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
Write-Host "Done. Run: flutter run" -ForegroundColor Cyan
