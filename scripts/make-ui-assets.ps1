<#
.SYNOPSIS
    Draws the UI images: focus highlights, rounded panels, background, fades.

.DESCRIPTION
    Writes to images\ui\. The .9.png files are Roku 9-patch images: a 1-pixel
    border marks which middle strip stretches, so one small image draws a
    rounded shape at any size. Re-run after changing colors here.

      rounded.9.png      white rounded panel; tinted per use with blendColor
      card-focus.9.png   blue rounded outline for focused cards
      row-focus.9.png    dark rounded highlight with a blue left bar (lists)
      background.jpg     full-screen background (subtle diagonal gradient)
      fade-bottom.png    transparent-to-dark fade behind the player's strip
      logo-mark.png      small TV mark for the top bar
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'images\ui'
New-Item -ItemType Directory -Force $outDir | Out-Null

function Color([int]$a, [int]$r, [int]$g, [int]$b) { [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }
$blue = Color 255 0x4D 0xA3 0xFF
$violet = Color 255 0x7C 0x6B 0xFF
$white = Color 255 255 255 255
$black = Color 255 0 0 0
$rowFill = Color 255 0x26 0x31 0x3E
$bgTop = Color 255 0x1A 0x24 0x31
$bgBottom = Color 255 0x0B 0x10 0x16

function New-Canvas([int]$w, [int]$h) {
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)
    return @{ bmp = $bmp; g = $g }
}

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

function Save-Png($c, [string]$name) {
    $path = Join-Path $outDir $name
    $c.bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $c.g.Dispose(); $c.bmp.Dispose()
    Write-Host "Wrote $path"
}

# 9-patch: art drawn inside a 1px border; black marks on the top and left
# border say which columns and rows stretch (everything but the corners).
function Save-NinePatch([int]$size, [int]$corner, [scriptblock]$draw, [string]$name, [int]$stretchFromX = -1) {
    $c = New-Canvas ($size + 2) ($size + 2)
    $c.g.TranslateTransform(1, 1)
    & $draw $c.g $size
    $c.g.ResetTransform()
    $from = if ($stretchFromX -ge 0) { $stretchFromX } else { $corner }
    for ($x = 1 + $from; $x -le $size - $corner; $x++) { $c.bmp.SetPixel($x, 0, $black) }
    for ($y = 1 + $corner; $y -le $size - $corner; $y++) { $c.bmp.SetPixel(0, $y, $black) }
    Save-Png $c $name
}

# White rounded panel (tint with blendColor).
Save-NinePatch 48 16 {
    param($g, $s)
    $g.FillPath((New-Object System.Drawing.SolidBrush($white)), (New-RoundedRect 0 0 $s $s 14))
} 'rounded.9.png'

# Focused card: blue outline, clear inside.
Save-NinePatch 48 18 {
    param($g, $s)
    $pen = New-Object System.Drawing.Pen($blue, 5)
    $g.DrawPath($pen, (New-RoundedRect 2.5 2.5 ($s - 5) ($s - 5) 15))
} 'card-focus.9.png'

# Focused list row: dark fill with a blue bar on the left (the bar doesn't stretch).
Save-NinePatch 48 12 {
    param($g, $s)
    $g.FillPath((New-Object System.Drawing.SolidBrush($rowFill)), (New-RoundedRect 0 0 $s $s 10))
    $g.SetClip((New-RoundedRect 0 0 $s $s 10))
    $g.FillRectangle((New-Object System.Drawing.SolidBrush($blue)), 0, 0, 6, $s)
    $g.ResetClip()
} 'row-focus.9.png' 16

# Background: same diagonal gradient and soft glow as the logo.
$c = New-Canvas 1920 1080
$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point(1920, 1080)), $bgTop, $bgBottom)
$c.g.FillRectangle($bg, 0, 0, 1920, 1080)
$glow = New-Object System.Drawing.Drawing2D.GraphicsPath
$glow.AddEllipse(-400, -500, 1600, 1100)
$glowBrush = New-Object System.Drawing.Drawing2D.PathGradientBrush($glow)
$glowBrush.CenterColor = Color 28 0x4D 0xA3 0xFF
$glowBrush.SurroundColors = @((Color 0 0x4D 0xA3 0xFF))
$c.g.FillPath($glowBrush, $glow)
$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$params = New-Object System.Drawing.Imaging.EncoderParameters(1)
$params.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]90)
$c.bmp.Save((Join-Path $outDir 'background.jpg'), $codec, $params)
$c.g.Dispose(); $c.bmp.Dispose()
Write-Host "Wrote $(Join-Path $outDir 'background.jpg')"

# Fade behind the player's channel strip (stretched to full width).
$c = New-Canvas 8 400
$fade = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point(0, 400)), (Color 0 0x08 0x0C 0x10), (Color 235 0x08 0x0C 0x10))
$c.g.FillRectangle($fade, 0, 0, 8, 400)
Save-Png $c 'fade-bottom.png'

# Small mark for the top bar: Dixie (art\dixie.svg), the logo without the name.
. (Join-Path $PSScriptRoot 'SvgArt.ps1')
$dixie = Read-SvgArt (Join-Path (Split-Path -Parent $PSScriptRoot) 'art\dixie.svg')
$c = New-Canvas 76 76
$scale = 75 / $dixie.Height
Draw-SvgArt $c.g $dixie ((76 - $dixie.Width * $scale) / 2) 0.5 $scale
Save-Png $c 'logo-mark.png'
