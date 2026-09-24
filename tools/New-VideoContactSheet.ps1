[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VideoPath,

    [Parameter(Mandatory = $true)]
    [double[]]$Times,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [ValidateRange(1, 8)]
    [int]$Columns = 3,

    [ValidateRange(240, 1920)]
    [int]$CellWidth = 576,

    [string]$Label = 'video',

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'video-production-common.ps1')

Add-Type -AssemblyName System.Drawing

$video = [System.IO.Path]::GetFullPath($VideoPath)
if (-not (Test-Path -LiteralPath $video -PathType Leaf)) {
    throw "Video not found: $video"
}
if ($Times.Count -eq 0) {
    throw 'At least one timestamp is required.'
}

$output = Assert-VideoOutputPath -Path $OutputPath -Force:$Force
$ffmpeg = Resolve-VideoTool -CommandName 'ffmpeg' -WinGetPattern 'Gyan.FFmpeg'
$ffprobe = Resolve-VideoTool -CommandName 'ffprobe' -WinGetPattern 'Gyan.FFmpeg'
$probe = Get-VideoProbe -Path $video -FfprobePath $ffprobe
$videoStream = @($probe.streams | Where-Object codec_type -eq 'video')[0]
if (-not $videoStream) {
    throw "No video stream found: $video"
}

$duration = [double]::Parse(
    [string]$probe.format.duration,
    [System.Globalization.CultureInfo]::InvariantCulture
)
foreach ($time in $Times) {
    if ($time -lt 0 -or $time -ge $duration) {
        throw "Contact-sheet timestamp $time is outside the half-open media interval [0, $duration) seconds."
    }
}

$sourceWidth = [int]$videoStream.width
$sourceHeight = [int]$videoStream.height
$cellHeight = [int][Math]::Round($CellWidth * $sourceHeight / $sourceWidth)
$labelHeight = [Math]::Max(34, [int][Math]::Round($CellWidth / 14))
$rows = [int][Math]::Ceiling($Times.Count / $Columns)
$sheetWidth = $Columns * $CellWidth
$sheetHeight = $rows * ($cellHeight + $labelHeight)
$temporaryRoot = Join-Path $env:TEMP (
    'auto-record-video-contact-sheet\' + [guid]::NewGuid().ToString('N')
)

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null

$sheet = $null
$graphics = $null
$font = $null
$labelBrush = $null
$backgroundBrush = $null

try {
    $sheet = [System.Drawing.Bitmap]::new(
        $sheetWidth,
        $sheetHeight,
        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($sheet)
    $graphics.Clear([System.Drawing.Color]::FromArgb(8, 12, 20))
    $graphics.InterpolationMode =
        [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.TextRenderingHint =
        [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $fontSize = [Math]::Max(12, [single]($labelHeight * 0.5))
    $font = [System.Drawing.Font]::new(
        'Consolas',
        $fontSize,
        [System.Drawing.FontStyle]::Regular,
        [System.Drawing.GraphicsUnit]::Pixel
    )
    $labelBrush = [System.Drawing.SolidBrush]::new(
        [System.Drawing.Color]::FromArgb(91, 242, 183)
    )
    $backgroundBrush = [System.Drawing.SolidBrush]::new(
        [System.Drawing.Color]::FromArgb(16, 26, 42)
    )

    for ($index = 0; $index -lt $Times.Count; $index++) {
        $time = $Times[$index]
        $framePath = Join-Path $temporaryRoot ('frame-{0:D3}.png' -f $index)
        Invoke-VideoCommand -FilePath $ffmpeg -Operation "extracting frame at $time seconds" -Arguments @(
            '-hide_banner',
            '-loglevel', 'error',
            '-y',
            '-ss', (ConvertTo-InvariantNumber -Value $time -Format '0.###'),
            '-i', $video,
            '-frames:v', '1',
            '-vf', "scale=$CellWidth`:$cellHeight`:flags=lanczos",
            $framePath
        )

        $frame = [System.Drawing.Image]::FromFile($framePath)
        try {
            $column = $index % $Columns
            $row = [int][Math]::Floor($index / $Columns)
            $x = $column * $CellWidth
            $y = $row * ($cellHeight + $labelHeight)
            $graphics.FillRectangle(
                $backgroundBrush,
                $x,
                $y,
                $CellWidth,
                $labelHeight
            )
            $graphics.DrawString(
                ('{0} {1:000.000}s' -f $Label, $time),
                $font,
                $labelBrush,
                [single]($x + 12),
                [single]($y + ($labelHeight - $fontSize) / 2 - 1)
            )
            $graphics.DrawImage(
                $frame,
                $x,
                $y + $labelHeight,
                $CellWidth,
                $cellHeight
            )
        }
        finally {
            $frame.Dispose()
        }
    }

    $sheet.Save($output, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    if ($backgroundBrush) {
        $backgroundBrush.Dispose()
    }
    if ($labelBrush) {
        $labelBrush.Dispose()
    }
    if ($font) {
        $font.Dispose()
    }
    if ($graphics) {
        $graphics.Dispose()
    }
    if ($sheet) {
        $sheet.Dispose()
    }
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

$file = Get-Item -LiteralPath $output
Write-Output "CONTACT_SHEET=$($file.FullName)"
Write-Output "SHA256=$(Get-VideoFileHash -Path $file.FullName)"
