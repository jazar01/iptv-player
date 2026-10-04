<#
.SYNOPSIS
    Draws the Roku channel poster (home-screen logo) and splash screen.

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

# The logo, designed on a 540x405 canvas.
function Draw-Logo($g) {
    # Soft glow behind the screen.
    $glow = New-Object System.Drawing.Drawing2D.GraphicsPath
    $glow.AddEllipse(110, 20, 320, 240)
    $glowBrush = New-Object System.Drawing.Drawing2D.PathGradientBrush($glow)
    $glowBrush.CenterColor = [System.Drawing.Color]::FromArgb(70, $blue)
    $glowBrush.SurroundColors = @([System.Drawing.Color]::FromArgb(0, $blue))
    $g.FillPath($glowBrush, $glow)

    # TV screen: gradient outline.
    $screen = New-RoundedRect 165 62 210 138 22
    $edge = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF(155, 52)), (New-Object System.Drawing.PointF(385, 210)), $blue, $violet)
    $edge.WrapMode = 'TileFlipXY'
    $pen = New-Object System.Drawing.Pen($edge, 11)
    $pen.LineJoin = 'Round'
    $g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 0x13, 0x1B, 0x25))), $screen)
    $g.DrawPath($pen, $screen)

    # Stand.
    $standPen = New-Object System.Drawing.Pen($grey, 9)
    $standPen.StartCap = 'Round'
    $standPen.EndCap = 'Round'
    $g.DrawLine($standPen, 236, 222, 304, 222)

    # Play triangle with rounded corners.
    $tri = New-Object System.Drawing.Drawing2D.GraphicsPath
    [System.Drawing.PointF[]]$corners = @(
        (New-Object System.Drawing.PointF(250, 101)),
        (New-Object System.Drawing.PointF(250, 161)),
        (New-Object System.Drawing.PointF(301, 131)))
    $tri.AddPolygon($corners)
    # Gradient runs a little past the shape so the rounded outline doesn't
    # wrap around to the far color at the corners.
    $triBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.PointF(238, 89)), (New-Object System.Drawing.PointF(313, 173)), $white, $blue)
    $triBrush.WrapMode = 'TileFlipXY'
    $triPen = New-Object System.Drawing.Pen($triBrush, 8)
    $triPen.LineJoin = 'Round'
    $g.FillPath($triBrush, $tri)
    $g.DrawPath($triPen, $tri)

    # Live dot.
    $g.FillEllipse((New-Object System.Drawing.SolidBrush($live)), 340, 76, 18, 18)

    # Wordmark.
    $titleFont = New-Object System.Drawing.Font('Segoe UI', 54, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $subFont = New-Object System.Drawing.Font('Segoe UI Semibold', 22, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    Draw-SpacedText $g 'IPTV' $titleFont (New-Object System.Drawing.SolidBrush($white)) 270 246 4
    Draw-SpacedText $g 'PLAYER' $subFont (New-Object System.Drawing.SolidBrush($grey)) 270 318 11
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
