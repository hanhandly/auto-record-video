[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PresentationPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [bool]$UseTimingsAndNarrations = $true,

    [ValidateRange(1, 60)]
    [int]$DefaultSlideDurationSeconds = 5,

    [ValidateSet(480, 720, 1080, 1440, 2160)]
    [int]$VerticalResolution = 1080,

    [ValidateRange(15, 60)]
    [int]$FrameRate = 30,

    [ValidateRange(1, 100)]
    [int]$Quality = 90,

    [ValidateRange(60, 7200)]
    [int]$TimeoutSeconds = 1800,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'video-production-common.ps1')

$presentationFile = [System.IO.Path]::GetFullPath($PresentationPath)
if (-not (Test-Path -LiteralPath $presentationFile -PathType Leaf)) {
    throw "PowerPoint presentation not found: $presentationFile"
}
$output = Assert-VideoOutputPath -Path $OutputPath -Force:$Force
if (Test-SameVideoPath -First $presentationFile -Second $output) {
    throw 'PowerPoint video output must not overwrite the presentation.'
}
$manifestPath = [System.IO.Path]::ChangeExtension(
    $output,
    '.powerpoint-manifest.json'
)
if ((Test-Path -LiteralPath $manifestPath) -and -not $Force) {
    throw "PowerPoint video manifest already exists. Use -Force to replace it: $manifestPath"
}

$sourceHashBefore = Get-VideoFileHash -Path $presentationFile
$stagingRoot = Join-Path $env:LOCALAPPDATA (
    'auto-record-video\powerpoint-video\' + [guid]::NewGuid().ToString('N')
)
$stagedVideo = Join-Path $stagingRoot 'presentation.mp4'
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

$powerPoint = $null
$presentation = $null

try {
    $powerPoint = New-Object -ComObject PowerPoint.Application
    $powerPoint.Visible = -1
    $presentation = $powerPoint.Presentations.Open(
        $presentationFile,
        -1,
        0,
        0
    )
    $presentation.CreateVideo(
        $stagedVideo,
        $UseTimingsAndNarrations,
        $DefaultSlideDurationSeconds,
        $VerticalResolution,
        $FrameRate,
        $Quality
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        $status = [int]$presentation.CreateVideoStatus
        if ((Get-Date) -gt $deadline) {
            throw "PowerPoint video rendering timed out after $TimeoutSeconds seconds."
        }
    }
    while ($status -in @(1, 2))

    if ($status -ne 3) {
        throw "PowerPoint video rendering failed with status $status."
    }
    if (-not (Test-Path -LiteralPath $stagedVideo -PathType Leaf)) {
        throw "PowerPoint reported success but did not create: $stagedVideo"
    }

    Copy-Item -LiteralPath $stagedVideo -Destination $output -Force:$Force
}
finally {
    if ($presentation) {
        try {
            $presentation.Close()
        }
        catch {
        }
        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject(
            $presentation
        )
    }
    if ($powerPoint) {
        try {
            $powerPoint.Quit()
        }
        catch {
        }
        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject(
            $powerPoint
        )
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}

$ffprobe = Resolve-VideoTool -CommandName 'ffprobe' -WinGetPattern 'Gyan.FFmpeg'
$probe = Get-VideoProbe -Path $output -FfprobePath $ffprobe
$video = @($probe.streams | Where-Object codec_type -eq 'video')[0]
if (-not $video) {
    throw "Rendered PowerPoint output contains no video stream: $output"
}

$sourceHashAfter = Get-VideoFileHash -Path $presentationFile
$sourcePreserved = $sourceHashBefore -eq $sourceHashAfter

Write-VideoJson -Path $manifestPath -InputObject ([pscustomobject]@{
    schemaVersion = 1
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    presentation = @{
        path = $presentationFile
        sha256Before = $sourceHashBefore
        sha256After = $sourceHashAfter
        preserved = $sourcePreserved
    }
    render = @{
        useTimingsAndNarrations = $UseTimingsAndNarrations
        defaultSlideDurationSeconds = $DefaultSlideDurationSeconds
        verticalResolution = $VerticalResolution
        requestedFrameRate = $FrameRate
        quality = $Quality
        localStagingUsed = $true
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

if (-not $sourcePreserved) {
    throw "Presentation hash changed during video export. Inspect: $manifestPath"
}

Write-Output "VIDEO=$output"
Write-Output "MANIFEST=$manifestPath"
