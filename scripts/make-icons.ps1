<#
.SYNOPSIS
    Draws the Roku channel poster (home-screen logo) and splash screen:
    Dixie (art\dixie.svg) and the name, Dixie TV.

.DESCRIPTION
    Renders one design at every size Roku asks for, using the Windows drawing
    library (System.Drawing), and writes them to images\:
      channel-poster_fhd.png  540x405
      channel-poster_hd.png   290x218
      channel-poster_sd.png   246x140
      splash_fhd.jpg          1920x1080
    The manifest points at these files. Edit the colors or text below and
    re-run to change the logo.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'images'
New-Item -ItemType Directory -Force $outDir | Out-Null

# App palette (matches the UI).
$bgTop = [System.Drawing.Color]::FromArgb(255, 0x1E, 0x2A, 0x38)
$bgBottom = [System.Drawing.Color]::FromArgb(255, 0x0C, 0x11, 0x17)
$blue = [System.Drawing.Color]::FromArgb(255, 0x4D, 0xA3, 0xFF)
$violet = [System.Drawing.Color]::FromArgb(255, 0x7C, 0x6B, 0xFF)
$live = [System.Drawing.Color]::FromArgb(255, 0xFF, 0x5A, 0x4E)
$white = [System.Drawing.Color]::FromArgb(255, 0xF4, 0xF7, 0xFA)
$grey = [System.Drawing.Color]::FromArgb(255, 0x9A, 0xA6, 0xB2)

function New-RoundedRect([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# Text with extra space between letters, centered on cx.
function Draw-SpacedText($g, [string]$text, $font, $brush, [single]$cx, [single]$y, [single]$spacing) {
    $fmt = [System.Drawing.StringFormat]::GenericTypographic
    $widths = foreach ($ch in $text.ToCharArray()) { $g.MeasureString([string]$ch, $font, 1000, $fmt).Width }
    $total = ($widths | Measure-Object -Sum).Sum + $spacing * ($text.Length - 1)
    $x = $cx - $total / 2
    for ($i = 0; $i -lt $text.Length; $i++) {
        $g.DrawString([string]$text[$i], $font, $brush, $x, $y, $fmt)
        $x += $widths[$i] + $spacing
    }
}

# Dixie, the German Shepherd the app is named after (art\dixie.svg, drawn
# from her photo).
. (Join-Path $PSScriptRoot 'SvgArt.ps1')
$dixie = Read-SvgArt (Join-Path $root 'art\dixie.svg')

# The logo, designed on a 540x405 canvas: Dixie, and the name beside her.
function Draw-Logo($g) {
    Draw-SvgArt $g $dixie 24 38 1.56
    $titleFont = New-Object System.Drawing.Font('Segoe UI', 84, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $fmt = [System.Drawing.StringFormat]::GenericTypographic
    $g.DrawString('Dixie', $titleFont, (New-Object System.Drawing.SolidBrush($white)), 330, 92, $fmt)
    $g.DrawString('TV', $titleFont, (New-Object System.Drawing.SolidBrush($blue)), 332, 192, $fmt)
}

function Save-Image([int]$width, [int]$height, [string]$file, [single]$logoScale) {
    $bmp = New-Object System.Drawing.Bitmap($width, $height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.PixelOffsetMode = 'HighQuality'
    $g.TextRenderingHint = 'AntiAliasGridFit'

    $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point($width, $height)), $bgTop, $bgBottom)
    $g.FillRectangle($bg, 0, 0, $width, $height)

    # Fit the 540x405 design, scaled and centered.
    $scale = [Math]::Min($width / 540.0, $height / 405.0) * $logoScale
    $g.TranslateTransform(($width - 540 * $scale) / 2, ($height - 405 * $scale) / 2)
    $g.ScaleTransform($scale, $scale)
    Draw-Logo $g

    $path = Join-Path $outDir $file
    if ($file.EndsWith('.jpg')) {
        $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
        $params = New-Object System.Drawing.Imaging.EncoderParameters(1)
        $params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]92)
        $bmp.Save($path, $codec, $params)
    }
    else {
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    $g.Dispose()
    $bmp.Dispose()
    Write-Host "Wrote $path"
}

Save-Image 540 405 'channel-poster_fhd.png' 1.0
Save-Image 290 218 'channel-poster_hd.png' 1.0
Save-Image 246 140 'channel-poster_sd.png' 1.0
Save-Image 1920 1080 'splash_fhd.jpg' 0.55
