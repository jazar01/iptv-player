<#
Draws a simple SVG file with System.Drawing, for make-icons.ps1 and
make-ui-assets.ps1 (dot-source this file). Enough for art\dixie.svg:
<path> with d made of M, L, C and Z (absolute coordinates), fill, stroke,
stroke-width and stroke-linecap="round"; <circle>. Colors are #RRGGBB.

    . (Join-Path $PSScriptRoot 'SvgArt.ps1')
    $art = Read-SvgArt (Join-Path $root 'art\dixie.svg')
    Draw-SvgArt $g $art 40 20 1.5      # at (40, 20), 1.5 times its size
#>

Add-Type -AssemblyName System.Drawing

function Read-SvgArt([string]$file) {
    [xml]$svg = Get-Content $file -Raw
    $box = ($svg.svg.viewBox -split '\s+') | ForEach-Object { [single]$_ }
    $shapes = @()
    foreach ($node in $svg.svg.ChildNodes) {
        if ($node.NodeType -ne 'Element') { continue }
        if ($node.LocalName -eq 'path' -or $node.LocalName -eq 'circle') { $shapes += $node }
    }
    return [pscustomobject]@{ Width = $box[2]; Height = $box[3]; Shapes = $shapes }
}

function ConvertTo-SvgColor([string]$value) {
    if (-not $value -or $value -eq 'none') { return $null }
    $hex = $value.TrimStart('#')
    return [System.Drawing.Color]::FromArgb(255, [Convert]::ToInt32($hex.Substring(0, 2), 16), [Convert]::ToInt32($hex.Substring(2, 2), 16), [Convert]::ToInt32($hex.Substring(4, 2), 16))
}

# "M58 104 L 50 26 C 49 12 58 8 66 16 Z" -> a GraphicsPath.
function ConvertTo-SvgPath([string]$d) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $tokens = [regex]::Matches($d, '[MLCZ]|-?\d+(\.\d+)?') | ForEach-Object { $_.Value }
    $i = 0
    $command = ''
    $current = New-Object System.Drawing.PointF(0, 0)
    $start = $current
    $num = { param($k) [single]$tokens[$k] }
    while ($i -lt $tokens.Count) {
        if ($tokens[$i] -match '^[MLCZ]$') { $command = $tokens[$i]; $i++ }
        switch ($command) {
            'M' {
                $current = New-Object System.Drawing.PointF((& $num $i), (& $num ($i + 1))); $i += 2
                $path.StartFigure(); $start = $current
                $command = 'L'      # further pairs after M are lines
            }
            'L' {
                $next = New-Object System.Drawing.PointF((& $num $i), (& $num ($i + 1))); $i += 2
                $path.AddLine($current, $next); $current = $next
            }
            'C' {
                $c1 = New-Object System.Drawing.PointF((& $num $i), (& $num ($i + 1)))
                $c2 = New-Object System.Drawing.PointF((& $num ($i + 2)), (& $num ($i + 3)))
                $next = New-Object System.Drawing.PointF((& $num ($i + 4)), (& $num ($i + 5))); $i += 6
                $path.AddBezier($current, $c1, $c2, $next); $current = $next
            }
            'Z' { $path.CloseFigure(); $current = $start }
            default { throw "Unsupported path data: $d" }
        }
    }
    return $path
}

function Draw-SvgArt($g, $art, [single]$x, [single]$y, [single]$scale) {
    $state = $g.Save()
    $g.TranslateTransform($x, $y)
    $g.ScaleTransform($scale, $scale)
    foreach ($s in $art.Shapes) {
        if ($s.LocalName -eq 'circle') {
            $r = [single]$s.r
            $fill = ConvertTo-SvgColor $s.fill
            if ($fill) { $g.FillEllipse((New-Object System.Drawing.SolidBrush($fill)), [single]$s.cx - $r, [single]$s.cy - $r, 2 * $r, 2 * $r) }
            continue
        }
        $path = ConvertTo-SvgPath $s.d
        $fill = ConvertTo-SvgColor $s.fill
        if ($fill) { $g.FillPath((New-Object System.Drawing.SolidBrush($fill)), $path) }
        $stroke = ConvertTo-SvgColor $s.stroke
        if ($stroke) {
            $width = if ($s.'stroke-width') { [single]$s.'stroke-width' } else { 1 }
            $pen = New-Object System.Drawing.Pen($stroke, $width)
            if ($s.'stroke-linecap' -eq 'round') { $pen.StartCap = 'Round'; $pen.EndCap = 'Round' }
            $pen.LineJoin = 'Round'
            $g.DrawPath($pen, $path)
        }
    }
    $g.Restore($state)
}
