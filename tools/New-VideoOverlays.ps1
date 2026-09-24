[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'video-production-common.ps1')

Add-Type -AssemblyName System.Drawing

function Test-JsonProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $Object.PSObject.Properties.Name -contains $Name
}

function ConvertTo-OverlayColor {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][hashtable]$Palette,
        [int]$Alpha = 255
    )

    $resolved = if ($Palette.ContainsKey($Value)) {
        [string]$Palette[$Value]
    }
    else {
        $Value
    }

    if ($resolved -notmatch '^#(?<red>[0-9a-fA-F]{2})(?<green>[0-9a-fA-F]{2})(?<blue>[0-9a-fA-F]{2})$') {
        throw "Overlay color must be a palette name or #RRGGBB value: $Value"
    }

    return [System.Drawing.Color]::FromArgb(
        $Alpha,
        [Convert]::ToInt32($Matches.red, 16),
        [Convert]::ToInt32($Matches.green, 16),
        [Convert]::ToInt32($Matches.blue, 16)
    )
}

function New-RoundedRectanglePath {
    param(
        [Parameter(Mandatory = $true)][System.Drawing.RectangleF]$Rectangle,
        [Parameter(Mandatory = $true)][single]$Radius
    )

    $diameter = [single]($Radius * 2)
    $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
    if ($diameter -le 0) {
        $path.AddRectangle($Rectangle)
        return $path
    }

    $arc = [System.Drawing.RectangleF]::new(
        $Rectangle.X,
        $Rectangle.Y,
        $diameter,
        $diameter
    )
    $path.AddArc($arc, 180, 90)
    $arc.X = $Rectangle.Right - $diameter
    $path.AddArc($arc, 270, 90)
    $arc.Y = $Rectangle.Bottom - $diameter
    $path.AddArc($arc, 0, 90)
    $arc.X = $Rectangle.Left
    $path.AddArc($arc, 90, 90)
    $path.CloseFigure()
    return $path
}

function Draw-RoundedRectangle {
    param(
        [Parameter(Mandatory = $true)][System.Drawing.Graphics]$Graphics,
        [Parameter(Mandatory = $true)][System.Drawing.RectangleF]$Rectangle,
        [Parameter(Mandatory = $true)][single]$Radius,
        [System.Drawing.Brush]$Brush,
        [System.Drawing.Pen]$Pen
    )

    $path = New-RoundedRectanglePath -Rectangle $Rectangle -Radius $Radius
    try {
        if ($Brush) {
            $Graphics.FillPath($Brush, $path)
        }
        if ($Pen) {
            $Graphics.DrawPath($Pen, $path)
        }
    }
    finally {
        $path.Dispose()
    }
}

function New-FittingFont {
    param(
        [Parameter(Mandatory = $true)][System.Drawing.Graphics]$Graphics,
        [Parameter(Mandatory = $true)][string]$Family,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][single]$PreferredSize,
        [Parameter(Mandatory = $true)][single]$MinimumSize,
        [Parameter(Mandatory = $true)][single]$MaximumWidth,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )

    $size = $PreferredSize
    while ($size -ge $MinimumSize) {
        $font = [System.Drawing.Font]::new(
            $Family,
            $size,
            $Style,
            [System.Drawing.GraphicsUnit]::Pixel
        )
        if ($Graphics.MeasureString($Text, $font).Width -le $MaximumWidth) {
            return $font
        }
        $font.Dispose()
        $size -= 1
    }

    return [System.Drawing.Font]::new(
        $Family,
        $MinimumSize,
        $Style,
        [System.Drawing.GraphicsUnit]::Pixel
    )
}

$config = [System.IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
    throw "Overlay configuration not found: $config"
}

$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$manifestPath = Join-Path $outputRoot 'overlay-manifest.json'
if ((Test-Path -LiteralPath $manifestPath) -and -not $Force) {
    throw "Overlay manifest already exists. Use -Force to replace it: $manifestPath"
}
$definition = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json

if (-not (Test-JsonProperty -Object $definition -Name 'canvas')) {
    throw 'Overlay configuration must contain a canvas object.'
}
if (-not (Test-JsonProperty -Object $definition -Name 'items')) {
    throw 'Overlay configuration must contain an items array.'
}

$width = [int]$definition.canvas.width
$height = [int]$definition.canvas.height
if ($width -le 0 -or $height -le 0) {
    throw 'Overlay canvas width and height must be positive.'
}

$palette = @{
    gold = '#FFCD49'
    cyan = '#37D5FF'
    green = '#5BF2B7'
    magenta = '#F74DA6'
    white = '#F6F9FC'
}
if (Test-JsonProperty -Object $definition -Name 'palette') {
    foreach ($property in $definition.palette.PSObject.Properties) {
        $palette[$property.Name] = [string]$property.Value
    }
}

$fontFamily = if (
    (Test-JsonProperty -Object $definition -Name 'font') -and
    (Test-JsonProperty -Object $definition.font -Name 'family')
) {
    [string]$definition.font.family
}
else {
    'Segoe UI'
}

$scale = $height / 1080.0
$margin = [single](24 * $scale)
$top = [single](18 * $scale)
$chipHeight = [single](54 * $scale)
$cornerRadius = [single](9 * $scale)
$manifestItems = [System.Collections.Generic.List[object]]::new()
$ids = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($item in @($definition.items)) {
    foreach ($required in @('id', 'type', 'startSeconds', 'endSeconds')) {
        if (-not (Test-JsonProperty -Object $item -Name $required)) {
            throw "Overlay item is missing '$required'."
        }
    }

    $id = [string]$item.id
    if ([string]::IsNullOrWhiteSpace($id) -or -not $ids.Add($id)) {
        throw "Overlay IDs must be non-empty and unique: $id"
    }

    $start = [double]$item.startSeconds
    $end = [double]$item.endSeconds
    if ($start -lt 0 -or $end -le $start) {
        throw "Overlay '$id' has an invalid half-open interval [$start, $end)."
    }

    $safeId = $id -replace '[^A-Za-z0-9._-]', '-'
    $fileName = "$safeId.png"
    $destination = Join-Path $outputRoot $fileName
    if ((Test-Path -LiteralPath $destination) -and -not $Force) {
        throw "Overlay output already exists. Use -Force to replace it: $destination"
    }

    $bitmap = [System.Drawing.Bitmap]::new(
        $width,
        $height,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $resources = [System.Collections.Generic.List[System.IDisposable]]::new()

    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.SmoothingMode =
            [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.InterpolationMode =
            [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.TextRenderingHint =
            [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

        $colorName = if (Test-JsonProperty -Object $item -Name 'color') {
            [string]$item.color
        }
        else {
            'gold'
        }
        $accent = ConvertTo-OverlayColor -Value $colorName -Palette $palette
        $type = ([string]$item.type).ToLowerInvariant()

        switch ($type) {
            'cue' {
                foreach ($required in @('stage', 'action')) {
                    if (-not (Test-JsonProperty -Object $item -Name $required)) {
                        throw "Cue overlay '$id' is missing '$required'."
                    }
                }

                $stage = [string]$item.stage
                $action = [string]$item.action
                $note = if (Test-JsonProperty -Object $item -Name 'note') {
                    [string]$item.note
                }
                else {
                    ''
                }

                $stageFont = New-FittingFont `
                    -Graphics $graphics `
                    -Family $fontFamily `
                    -Text $stage `
                    -PreferredSize ([single](28 * $scale)) `
                    -MinimumSize ([single](17 * $scale)) `
                    -MaximumWidth ([single]($width * 0.43)) `
                    -Style Bold
                $actionFont = New-FittingFont `
                    -Graphics $graphics `
                    -Family $fontFamily `
                    -Text $action `
                    -PreferredSize ([single](28 * $scale)) `
                    -MinimumSize ([single](17 * $scale)) `
                    -MaximumWidth ([single]($width * 0.58)) `
                    -Style Bold
                $resources.Add($stageFont)
                $resources.Add($actionFont)

                $stagePadding = [single](18 * $scale)
                $stageWidth = [single](
                    $graphics.MeasureString($stage, $stageFont).Width +
                    2 * $stagePadding
                )
                $stageRectangle = [System.Drawing.RectangleF]::new(
                    $margin,
                    $top,
                    $stageWidth,
                    $chipHeight
                )
                $stageBrush = [System.Drawing.SolidBrush]::new($accent)
                $stageTextBrush = [System.Drawing.SolidBrush]::new(
                    [System.Drawing.Color]::FromArgb(255, 4, 9, 16)
                )
                $resources.Add($stageBrush)
                $resources.Add($stageTextBrush)
                Draw-RoundedRectangle `
                    -Graphics $graphics `
                    -Rectangle $stageRectangle `
                    -Radius $cornerRadius `
                    -Brush $stageBrush
                $graphics.DrawString(
                    $stage,
                    $stageFont,
                    $stageTextBrush,
                    [single]($margin + $stagePadding),
                    [single]($top + 9 * $scale)
                )

                $actionPadding = [single](20 * $scale)
                $arrowWidth = [single](18 * $scale)
                $actionWidth = [single](
                    $graphics.MeasureString($action, $actionFont).Width +
                    2 * $actionPadding +
                    $arrowWidth
                )
                $actionX = [single]($width - $margin - $actionWidth)
                $actionRectangle = [System.Drawing.RectangleF]::new(
                    $actionX,
                    $top,
                    $actionWidth,
                    $chipHeight
                )
                $darkBrush = [System.Drawing.SolidBrush]::new(
                    [System.Drawing.Color]::FromArgb(228, 5, 10, 18)
                )
                $accentPen = [System.Drawing.Pen]::new(
                    $accent,
                    [single](3 * $scale)
                )
                $accentBrush = [System.Drawing.SolidBrush]::new($accent)
                $resources.Add($darkBrush)
                $resources.Add($accentPen)
                $resources.Add($accentBrush)
                Draw-RoundedRectangle `
                    -Graphics $graphics `
                    -Rectangle $actionRectangle `
                    -Radius $cornerRadius `
                    -Brush $darkBrush `
                    -Pen $accentPen

                $triangleX = [single]($actionX + 14 * $scale)
                $triangleY = [single]($top + $chipHeight / 2)
                $triangle = [System.Drawing.PointF[]]@(
                    [System.Drawing.PointF]::new(
                        $triangleX,
                        [single]($triangleY - 8 * $scale)
                    ),
                    [System.Drawing.PointF]::new(
                        [single]($triangleX + 12 * $scale),
                        $triangleY
                    ),
                    [System.Drawing.PointF]::new(
                        $triangleX,
                        [single]($triangleY + 8 * $scale)
                    )
                )
                $graphics.FillPolygon($accentBrush, $triangle)
                $graphics.DrawString(
                    $action,
                    $actionFont,
                    $accentBrush,
                    [single]($actionX + 38 * $scale),
                    [single]($top + 9 * $scale)
                )

                if (-not [string]::IsNullOrWhiteSpace($note)) {
                    $noteFont = New-FittingFont `
                        -Graphics $graphics `
                        -Family $fontFamily `
                        -Text $note `
                        -PreferredSize ([single](23 * $scale)) `
                        -MinimumSize ([single](15 * $scale)) `
                        -MaximumWidth ([single]($width * 0.78))
                    $resources.Add($noteFont)
                    $noteHeight = [single](54 * $scale)
                    $notePadding = [single](22 * $scale)
                    $noteWidth = [single][Math]::Min(
                        $width * 0.82,
                        $graphics.MeasureString($note, $noteFont).Width +
                        2 * $notePadding
                    )
                    $noteRectangle = [System.Drawing.RectangleF]::new(
                        $margin,
                        [single]($height - $top - $noteHeight),
                        $noteWidth,
                        $noteHeight
                    )
                    $notePen = [System.Drawing.Pen]::new(
                        [System.Drawing.Color]::FromArgb(220, 63, 77, 101),
                        [single](2 * $scale)
                    )
                    $noteTextBrush = [System.Drawing.SolidBrush]::new(
                        [System.Drawing.Color]::FromArgb(255, 238, 244, 252)
                    )
                    $resources.Add($notePen)
                    $resources.Add($noteTextBrush)
                    Draw-RoundedRectangle `
                        -Graphics $graphics `
                        -Rectangle $noteRectangle `
                        -Radius ([single](8 * $scale)) `
                        -Brush $darkBrush `
                        -Pen $notePen
                    $graphics.FillRectangle(
                        $accentBrush,
                        $noteRectangle.X,
                        $noteRectangle.Y,
                        [single](7 * $scale),
                        $noteRectangle.Height
                    )
                    $graphics.DrawString(
                        $note,
                        $noteFont,
                        $noteTextBrush,
                        [single]($noteRectangle.X + $notePadding),
                        [single]($noteRectangle.Y + 11 * $scale)
                    )
                }
            }
            'focus' {
                foreach ($required in @('x', 'y', 'width', 'height')) {
                    if (-not (Test-JsonProperty -Object $item -Name $required)) {
                        throw "Focus overlay '$id' is missing '$required'."
                    }
                }

                $x = [single]$item.x
                $y = [single]$item.y
                $focusWidth = [single]$item.width
                $focusHeight = [single]$item.height
                if (
                    $x -lt 0 -or $y -lt 0 -or
                    $focusWidth -le 0 -or $focusHeight -le 0 -or
                    $x + $focusWidth -gt $width -or
                    $y + $focusHeight -gt $height
                ) {
                    throw "Focus overlay '$id' is outside the $width x $height canvas."
                }

                foreach ($glow in @(
                    @{ Expand = 10; Alpha = 34; Width = 10 },
                    @{ Expand = 5; Alpha = 86; Width = 6 }
                )) {
                    $glowColor = [System.Drawing.Color]::FromArgb(
                        [int]$glow.Alpha,
                        $accent.R,
                        $accent.G,
                        $accent.B
                    )
                    $glowPen = [System.Drawing.Pen]::new(
                        $glowColor,
                        [single]($glow.Width * $scale)
                    )
                    $resources.Add($glowPen)
                    $expand = [single]($glow.Expand * $scale)
                    Draw-RoundedRectangle `
                        -Graphics $graphics `
                        -Rectangle ([System.Drawing.RectangleF]::new(
                            $x - $expand,
                            $y - $expand,
                            $focusWidth + 2 * $expand,
                            $focusHeight + 2 * $expand
                        )) `
                        -Radius ([single](11 * $scale)) `
                        -Pen $glowPen
                }

                $focusFill = [System.Drawing.SolidBrush]::new(
                    [System.Drawing.Color]::FromArgb(
                        12,
                        $accent.R,
                        $accent.G,
                        $accent.B
                    )
                )
                $focusPen = [System.Drawing.Pen]::new(
                    $accent,
                    [single](4 * $scale)
                )
                $resources.Add($focusFill)
                $resources.Add($focusPen)
                Draw-RoundedRectangle `
                    -Graphics $graphics `
                    -Rectangle ([System.Drawing.RectangleF]::new(
                        $x,
                        $y,
                        $focusWidth,
                        $focusHeight
                    )) `
                    -Radius ([single](8 * $scale)) `
                    -Brush $focusFill `
                    -Pen $focusPen
            }
            default {
                throw "Unsupported overlay type '$($item.type)' for '$id'. Use 'cue' or 'focus'."
            }
        }

        $bitmap.Save($destination, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        foreach ($resource in $resources) {
            $resource.Dispose()
        }
        $graphics.Dispose()
        $bitmap.Dispose()
    }

    $manifestItems.Add([pscustomobject]@{
        id = $id
        type = $type
        startSeconds = $start
        endSeconds = $end
        x = 0
        y = 0
        file = $fileName
        sha256 = Get-VideoFileHash -Path $destination
    })
}

Write-VideoJson -Path $manifestPath -InputObject ([pscustomobject]@{
    schemaVersion = 1
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    sourceConfig = $config
    canvas = @{
        width = $width
        height = $height
    }
    intervalSemantics = 'Half-open: startSeconds <= t < endSeconds'
    items = $manifestItems
})

Write-Output "OVERLAY_COUNT=$($manifestItems.Count)"
Write-Output "OVERLAY_MANIFEST=$manifestPath"
