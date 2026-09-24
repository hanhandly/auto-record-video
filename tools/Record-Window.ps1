[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$WindowTitle,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [ValidateRange(1, 14400)]
    [int]$DurationSeconds,

    [ValidateRange(5, 60)]
    [int]$FrameRate = 30,

    [ValidateRange(1, 120)]
    [int]$WaitForWindowSeconds = 20,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'video-production-common.ps1')

$output = Assert-VideoOutputPath -Path $OutputPath -Force:$Force
$ffmpeg = Resolve-VideoTool -CommandName 'ffmpeg' -WinGetPattern 'Gyan.FFmpeg'
$ffprobe = Resolve-VideoTool -CommandName 'ffprobe' -WinGetPattern 'Gyan.FFmpeg'
$manifestPath = [System.IO.Path]::ChangeExtension(
    $output,
    '.capture-manifest.json'
)
if ((Test-Path -LiteralPath $manifestPath) -and -not $Force) {
    throw "Capture manifest already exists. Use -Force to replace it: $manifestPath"
}

$deadline = (Get-Date).AddSeconds($WaitForWindowSeconds)
do {
    $window = Get-Process |
        Where-Object { $_.MainWindowTitle -eq $WindowTitle } |
        Select-Object -First 1
    if (-not $window) {
        Start-Sleep -Milliseconds 250
    }
}
until ($window -or (Get-Date) -ge $deadline)

if (-not $window) {
    throw "A visible window titled '$WindowTitle' did not appear within $WaitForWindowSeconds seconds."
}

Invoke-VideoCommand -FilePath $ffmpeg -Operation "recording window '$WindowTitle'" -Arguments @(
    '-hide_banner',
    '-loglevel', 'warning',
    '-y',
    '-f', 'gdigrab',
    '-framerate', [string]$FrameRate,
    '-i', "title=$WindowTitle",
    '-t', [string]$DurationSeconds,
    '-c:v', 'libx264',
    '-preset', 'veryfast',
    '-crf', '20',
    '-pix_fmt', 'yuv420p',
    '-movflags', '+faststart',
    $output
)

$probe = Get-VideoProbe -Path $output -FfprobePath $ffprobe
$video = @($probe.streams | Where-Object codec_type -eq 'video')[0]
if (-not $video) {
    throw "Recorded output contains no video stream: $output"
}

Write-VideoJson -Path $manifestPath -InputObject ([pscustomobject]@{
    schemaVersion = 1
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    capture = @{
        mode = 'ffmpeg-gdigrab-window-title'
        windowTitle = $WindowTitle
        processId = $window.Id
        requestedDurationSeconds = $DurationSeconds
        requestedFrameRate = $FrameRate
    }
    output = @{
        path = $output
        bytes = (Get-Item -LiteralPath $output).Length
        sha256 = Get-VideoFileHash -Path $output
        durationSeconds = [double]::Parse(
            [string]$probe.format.duration,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        codec = [string]$video.codec_name
        width = [int]$video.width
        height = [int]$video.height
        frameRate = [string]$video.avg_frame_rate
    }
})

Write-Output "VIDEO=$output"
Write-Output "MANIFEST=$manifestPath"
