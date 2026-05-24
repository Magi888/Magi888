Add-Type -AssemblyName System.Drawing

$src = "$PSScriptRoot\assets\logo.png"
$res = "$PSScriptRoot\android\app\src\main\res"

if (-not (Test-Path $src)) {
    Write-Host "ERROR: $src not found" -ForegroundColor Red
    exit 1
}

$sizes = @{
    "mipmap-mdpi"     = 48
    "mipmap-hdpi"     = 72
    "mipmap-xhdpi"    = 96
    "mipmap-xxhdpi"   = 144
    "mipmap-xxxhdpi"  = 192
}

$orig = [System.Drawing.Image]::FromFile($src)

foreach ($dir in $sizes.Keys) {
    $px     = $sizes[$dir]
    $outDir = Join-Path $res $dir
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $bmp = New-Object System.Drawing.Bitmap($px, $px)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($orig, 0, 0, $px, $px)
    $g.Dispose()

    $out = Join-Path $outDir "ic_launcher.png"
    $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    Write-Host "OK  $dir  ($px x $px)" -ForegroundColor Green
}

$orig.Dispose()
Write-Host "DONE - now run: flutter clean && flutter run" -ForegroundColor Cyan
