[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VideoPath,

    [Parameter(Mandatory = $true)]
    [double]$ExpectedDurationSeconds,

    [int]$ExpectedWidth,

    [int]$ExpectedHeight,

    [double]$ExpectedFrameRate,

    [switch]$RequireAudio,

    [int]$ExpectedAudioSampleRate,

    [int]$ExpectedAudioChannels,

    [double]$ExpectedIntegratedLufs = [double]::NaN,

    [ValidateRange(0.1, 10.0)]
    [double]$IntegratedLufsTolerance = 1.0,

    [double]$MaximumTruePeakDbfs = [double]::NaN,

    [ValidateRange(0.001, 2.0)]
    [double]$DurationToleranceSeconds = 0.05,

    [string]$SourceManifestPath,

    [double[]]$ContactSheetTimes = @(),

    [string]$ContactSheetPath,

    [string]$ManifestPath,

    [switch]$AllowSubtitleStreams,

    [switch]$SkipFullDecode,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'video-production-common.ps1')

function Add-Check {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$List,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Actual,
        [string]$Detail = ''
    )

    $List.Add([pscustomobject]@{
        name = $Name
        passed = $Passed
        expected = $Expected
        actual = $Actual
        detail = $Detail
    })
}

$videoPathValue = [System.IO.Path]::GetFullPath($VideoPath)
if (-not (Test-Path -LiteralPath $videoPathValue -PathType Leaf)) {
    throw "Video not found: $videoPathValue"
}
if ($ExpectedDurationSeconds -le 0) {
    throw 'ExpectedDurationSeconds must be positive.'
}
$resolvedManifest = if ($ManifestPath) {
    [System.IO.Path]::GetFullPath($ManifestPath)
}
else {
    [System.IO.Path]::ChangeExtension(
        $videoPathValue,
        '.qc-manifest.json'
    )
}
if ((Test-Path -LiteralPath $resolvedManifest) -and -not $Force) {
    throw "QC manifest already exists. Use -Force to replace it: $resolvedManifest"
}

$ffmpeg = Resolve-VideoTool -CommandName 'ffmpeg' -WinGetPattern 'Gyan.FFmpeg'
$ffprobe = Resolve-VideoTool -CommandName 'ffprobe' -WinGetPattern 'Gyan.FFmpeg'
$probe = Get-VideoProbe -Path $videoPathValue -FfprobePath $ffprobe
$videoStreams = @($probe.streams | Where-Object codec_type -eq 'video')
$audioStreams = @($probe.streams | Where-Object codec_type -eq 'audio')
$subtitleStreams = @($probe.streams | Where-Object codec_type -eq 'subtitle')
$checks = [System.Collections.Generic.List[object]]::new()

Add-Check `
    -List $checks `
    -Name 'nonzero-file-size' `
    -Passed ((Get-Item -LiteralPath $videoPathValue).Length -gt 0) `
    -Expected '> 0 bytes' `
    -Actual (Get-Item -LiteralPath $videoPathValue).Length
Add-Check `
    -List $checks `
    -Name 'video-stream-present' `
    -Passed ($videoStreams.Count -gt 0) `
    -Expected 'at least 1' `
    -Actual $videoStreams.Count

if ($videoStreams.Count -eq 0) {
    throw "Video stream is missing: $videoPathValue"
}

$video = $videoStreams[0]
$actualDuration = [double]::Parse(
    [string]$probe.format.duration,
    [System.Globalization.CultureInfo]::InvariantCulture
)
Add-Check `
    -List $checks `
    -Name 'duration' `
    -Passed (
        [Math]::Abs($actualDuration - $ExpectedDurationSeconds) -le
        $DurationToleranceSeconds
    ) `
    -Expected $ExpectedDurationSeconds `
    -Actual ([Math]::Round($actualDuration, 6)) `
    -Detail "Tolerance: +/- $DurationToleranceSeconds seconds"

if ($ExpectedWidth -gt 0) {
    Add-Check `
        -List $checks `
        -Name 'width' `
        -Passed ([int]$video.width -eq $ExpectedWidth) `
        -Expected $ExpectedWidth `
        -Actual ([int]$video.width)
}
if ($ExpectedHeight -gt 0) {
    Add-Check `
        -List $checks `
        -Name 'height' `
        -Passed ([int]$video.height -eq $ExpectedHeight) `
        -Expected $ExpectedHeight `
        -Actual ([int]$video.height)
}

$actualFrameRate = ConvertFrom-VideoRational -Value ([string]$video.avg_frame_rate)
if ($ExpectedFrameRate -gt 0) {
    Add-Check `
        -List $checks `
        -Name 'frame-rate' `
        -Passed ([Math]::Abs($actualFrameRate - $ExpectedFrameRate) -le 0.01) `
        -Expected $ExpectedFrameRate `
        -Actual ([Math]::Round($actualFrameRate, 6))
}

$audioRequired = (
    $RequireAudio -or
    $ExpectedAudioSampleRate -gt 0 -or
    $ExpectedAudioChannels -gt 0
)
if ($audioRequired) {
    Add-Check `
        -List $checks `
        -Name 'audio-stream-present' `
        -Passed ($audioStreams.Count -gt 0) `
        -Expected 'at least 1' `
        -Actual $audioStreams.Count
}
if ($audioStreams.Count -gt 0) {
    $audio = $audioStreams[0]
    if ($ExpectedAudioSampleRate -gt 0) {
        Add-Check `
            -List $checks `
            -Name 'audio-sample-rate' `
            -Passed ([int]$audio.sample_rate -eq $ExpectedAudioSampleRate) `
            -Expected $ExpectedAudioSampleRate `
            -Actual ([int]$audio.sample_rate)
    }
    if ($ExpectedAudioChannels -gt 0) {
        Add-Check `
            -List $checks `
            -Name 'audio-channels' `
            -Passed ([int]$audio.channels -eq $ExpectedAudioChannels) `
            -Expected $ExpectedAudioChannels `
            -Actual ([int]$audio.channels)
    }
}

Add-Check `
    -List $checks `
    -Name 'subtitle-streams' `
    -Passed ($AllowSubtitleStreams -or $subtitleStreams.Count -eq 0) `
    -Expected $(if ($AllowSubtitleStreams) { 'allowed' } else { 0 }) `
    -Actual $subtitleStreams.Count

$decodeOutput = @()
$decodePassed = $true
if (-not $SkipFullDecode) {
    $decodeOutput = & $ffmpeg `
        -hide_banner `
        -v error `
        -i $videoPathValue `
        -map '0:v:0?' `
        -map '0:a:0?' `
        -f null `
        NUL 2>&1
    $decodePassed = $LASTEXITCODE -eq 0
    Add-Check `
        -List $checks `
        -Name 'full-decode' `
        -Passed $decodePassed `
        -Expected 'ffmpeg exit code 0' `
        -Actual $(if ($decodePassed) { 0 } else { $LASTEXITCODE }) `
        -Detail ($decodeOutput -join [Environment]::NewLine)
}

$loudness = $null
if ($audioStreams.Count -gt 0) {
    try {
        $measurement = Get-LoudnormMeasurement `
            -InputPath $videoPathValue `
            -IntegratedLufs -16 `
            -TruePeakDb -1.5 `
            -LoudnessRange 7 `
            -FfmpegPath $ffmpeg
        $loudness = [pscustomobject]@{
            integratedLufs = [string]$measurement.input_i
            truePeakDbfs = [string]$measurement.input_tp
            loudnessRangeLu = [string]$measurement.input_lra
            thresholdLufs = [string]$measurement.input_thresh
        }
        Add-Check `
            -List $checks `
            -Name 'loudness-analysis' `
            -Passed $true `
            -Expected 'parseable loudnorm result' `
            -Actual 'parsed'

        if (-not [double]::IsNaN($ExpectedIntegratedLufs)) {
            $actualLufs = 0.0
            $parsedLufs = [double]::TryParse(
                [string]$measurement.input_i,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$actualLufs
            )
            Add-Check `
                -List $checks `
                -Name 'integrated-loudness' `
                -Passed (
                    $parsedLufs -and
                    [Math]::Abs($actualLufs - $ExpectedIntegratedLufs) -le
                    $IntegratedLufsTolerance
                ) `
                -Expected "$ExpectedIntegratedLufs +/- $IntegratedLufsTolerance LUFS" `
                -Actual $(if ($parsedLufs) { $actualLufs } else { [string]$measurement.input_i })
        }

        if (-not [double]::IsNaN($MaximumTruePeakDbfs)) {
            $actualTruePeak = 0.0
            $parsedTruePeak = [double]::TryParse(
                [string]$measurement.input_tp,
                [System.Globalization.NumberStyles]::Float,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$actualTruePeak
            )
            Add-Check `
                -List $checks `
                -Name 'true-peak' `
                -Passed (
                    $parsedTruePeak -and
                    $actualTruePeak -le $MaximumTruePeakDbfs
                ) `
                -Expected "<= $MaximumTruePeakDbfs dBFS" `
                -Actual $(if ($parsedTruePeak) { $actualTruePeak } else { [string]$measurement.input_tp })
        }
    }
    catch {
        Add-Check `
            -List $checks `
            -Name 'loudness-analysis' `
            -Passed $false `
            -Expected 'parseable loudnorm result' `
            -Actual $_.Exception.Message
    }
}

$sourceChecks = [System.Collections.Generic.List[object]]::new()
if ($SourceManifestPath) {
    $sourceManifest = [System.IO.Path]::GetFullPath($SourceManifestPath)
    if (-not (Test-Path -LiteralPath $sourceManifest -PathType Leaf)) {
        throw "Source manifest not found: $sourceManifest"
    }

    $sourceDefinition = Get-Content -LiteralPath $sourceManifest -Raw |
        ConvertFrom-Json
    if ($sourceDefinition.PSObject.Properties.Name -notcontains 'sources') {
        throw "Source manifest has no sources array: $sourceManifest"
    }

    foreach ($source in @($sourceDefinition.sources)) {
        $exists = Test-Path -LiteralPath ([string]$source.path) -PathType Leaf
        $actualHash = if ($exists) {
            Get-VideoFileHash -Path ([string]$source.path)
        }
        else {
            $null
        }
        $matches = $exists -and $actualHash -eq [string]$source.sha256
        $sourceChecks.Add([pscustomobject]@{
            path = [string]$source.path
            exists = $exists
            expectedSha256 = [string]$source.sha256
            actualSha256 = $actualHash
            preserved = $matches
        })
        Add-Check `
            -List $checks `
            -Name "source-preserved:$([System.IO.Path]::GetFileName([string]$source.path))" `
            -Passed $matches `
            -Expected ([string]$source.sha256) `
            -Actual $actualHash
    }
}

$contactSheet = $null
if ($ContactSheetTimes.Count -gt 0) {
    $contactSheet = if ($ContactSheetPath) {
        [System.IO.Path]::GetFullPath($ContactSheetPath)
    }
    else {
        [System.IO.Path]::ChangeExtension(
            $videoPathValue,
            '.contact-sheet.png'
        )
    }
    & (Join-Path $PSScriptRoot 'New-VideoContactSheet.ps1') `
        -VideoPath $videoPathValue `
        -Times $ContactSheetTimes `
        -OutputPath $contactSheet `
        -Label ([System.IO.Path]::GetFileNameWithoutExtension($videoPathValue)) `
        -Force:$Force | Out-Null
}

$passed = @($checks | Where-Object { -not $_.passed }).Count -eq 0
Write-VideoJson -Path $resolvedManifest -InputObject ([pscustomobject]@{
    schemaVersion = 1
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    passed = $passed
    video = @{
        path = $videoPathValue
        bytes = (Get-Item -LiteralPath $videoPathValue).Length
        sha256 = Get-VideoFileHash -Path $videoPathValue
        durationSeconds = [Math]::Round($actualDuration, 6)
        videoCodec = [string]$video.codec_name
        width = [int]$video.width
        height = [int]$video.height
        frameRate = [string]$video.avg_frame_rate
        pixelFormat = [string]$video.pix_fmt
        audioCodec = if ($audioStreams.Count -gt 0) {
            [string]$audioStreams[0].codec_name
        }
        else {
            $null
        }
        audioSampleRate = if ($audioStreams.Count -gt 0) {
            [int]$audioStreams[0].sample_rate
        }
        else {
            $null
        }
        audioChannels = if ($audioStreams.Count -gt 0) {
            [int]$audioStreams[0].channels
        }
        else {
            $null
        }
        subtitleStreams = $subtitleStreams.Count
    }
    loudness = $loudness
    checks = $checks
    sourceProtection = $sourceChecks
    contactSheet = if ($contactSheet) {
        @{
            path = $contactSheet
            sha256 = Get-VideoFileHash -Path $contactSheet
            times = $ContactSheetTimes
        }
    }
    else {
        $null
    }
})

if (-not $passed) {
    $failedNames = @(
        $checks |
            Where-Object { -not $_.passed } |
            ForEach-Object name
    )
    throw "Video QC failed: $($failedNames -join ', '). Inspect: $resolvedManifest"
}

Write-Output "PASSED=true"
Write-Output "MANIFEST=$resolvedManifest"
if ($contactSheet) {
    Write-Output "CONTACT_SHEET=$contactSheet"
}
