[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PlanPath,

    [Parameter(Mandatory = $true)]
    [string]$SegmentsDirectory,

    [Parameter(Mandatory = $true)]
    [string]$SourceVideo,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$BackgroundAudio,

    [double]$VoiceTargetLufs = -17.0,

    [double]$VoiceTruePeakDb = -1.5,

    [double]$BackgroundTargetLufs = -29.0,

    [double]$BackgroundTruePeakDb = -6.0,

    [ValidateRange(1.0, 20.0)]
    [double]$DuckingRatio = 10.0,

    [ValidateRange(0.001, 1.0)]
    [double]$DuckingThreshold = 0.025,

    [ValidateRange(1, 2000)]
    [int]$DuckingAttackMilliseconds = 15,

    [ValidateRange(1, 5000)]
    [int]$DuckingReleaseMilliseconds = 350,

    [ValidateRange(0.5, 1.0)]
    [double]$MinimumTempo = 0.75,

    [ValidateRange(1.0, 2.0)]
    [double]$MaximumTempo = 1.35,

    [ValidateSet('copy', 'libx264')]
    [string]$VideoCodec = 'copy',

    [ValidateRange(0, 10)]
    [double]$FinalFadeSeconds = 0.5,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'video-production-common.ps1')

function Test-JsonProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $Object.PSObject.Properties.Name -contains $Name
}

function Get-SegmentNumber {
    param(
        [Parameter(Mandatory = $true)][object]$Segment,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][string]$Context
    )

    foreach ($name in $Names) {
        if (Test-JsonProperty -Object $Segment -Name $name) {
            return [double]$Segment.$name
        }
    }

    throw "$Context is missing one of: $($Names -join ', ')."
}

$plan = [System.IO.Path]::GetFullPath($PlanPath)
$segmentRoot = [System.IO.Path]::GetFullPath($SegmentsDirectory)
$source = [System.IO.Path]::GetFullPath($SourceVideo)

foreach ($path in @($plan, $source)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required input not found: $path"
    }
}
$sourceHashBefore = Get-VideoFileHash -Path $source
if (-not (Test-Path -LiteralPath $segmentRoot -PathType Container)) {
    throw "Narration segments directory not found: $segmentRoot"
}

$output = Assert-VideoOutputPath -Path $OutputPath -Force:$Force
if (Test-SameVideoPath -First $source -Second $output) {
    throw "Output must not overwrite the source video: $source"
}

$resolvedBackground = $null
if ($BackgroundAudio) {
    $resolvedBackground = [System.IO.Path]::GetFullPath($BackgroundAudio)
    if (-not (Test-Path -LiteralPath $resolvedBackground -PathType Leaf)) {
        throw "Background audio not found: $resolvedBackground"
    }
    if (Test-SameVideoPath -First $resolvedBackground -Second $output) {
        throw "Output must not overwrite the background audio: $resolvedBackground"
    }
}

$definition = Get-Content -LiteralPath $plan -Raw | ConvertFrom-Json
if (-not (Test-JsonProperty -Object $definition -Name 'durationSeconds')) {
    throw 'Narration plan must contain durationSeconds.'
}
if (-not (Test-JsonProperty -Object $definition -Name 'segments')) {
    throw 'Narration plan must contain a segments array.'
}

$duration = [double]$definition.durationSeconds
if ($duration -le 0) {
    throw 'Narration durationSeconds must be positive.'
}
if ($FinalFadeSeconds -gt $duration) {
    throw 'FinalFadeSeconds cannot exceed the video duration.'
}
if ($MinimumTempo -gt $MaximumTempo) {
    throw 'MinimumTempo cannot be greater than MaximumTempo.'
}

$ffmpeg = Resolve-VideoTool -CommandName 'ffmpeg' -WinGetPattern 'Gyan.FFmpeg'
$ffprobe = Resolve-VideoTool -CommandName 'ffprobe' -WinGetPattern 'Gyan.FFmpeg'
$sourceProbe = Get-VideoProbe -Path $source -FfprobePath $ffprobe
$sourceVideoStreams = @(
    $sourceProbe.streams | Where-Object codec_type -eq 'video'
)
$sourceAudioStreams = @(
    $sourceProbe.streams | Where-Object codec_type -eq 'audio'
)
if ($sourceVideoStreams.Count -eq 0) {
    throw "Source has no video stream: $source"
}
$sourceDuration = [double]::Parse(
    [string]$sourceProbe.format.duration,
    [System.Globalization.CultureInfo]::InvariantCulture
)
if ($sourceDuration -lt $duration - 0.02) {
    throw "Source video is $sourceDuration seconds, shorter than the $duration-second narration plan."
}

$segments = @(
    $definition.segments |
        Sort-Object {
            Get-SegmentNumber `
                -Segment $_ `
                -Names @('startSeconds', 'start') `
                -Context "segment '$($_.id)'"
        }
)
if ($segments.Count -eq 0) {
    throw 'Narration plan contains no segments.'
}

$durationText = ConvertTo-InvariantNumber -Value $duration -Format '0.###'
$outputDirectory = [System.IO.Path]::GetDirectoryName($output)
$outputBase = [System.IO.Path]::GetFileNameWithoutExtension($output)
$timelineRaw = Join-Path $outputDirectory "$outputBase.narration-raw-48k.wav"
$timelineNormalized = Join-Path $outputDirectory "$outputBase.narration-48k.wav"
$backgroundRaw = Join-Path $outputDirectory "$outputBase.background-raw-48k.wav"
$backgroundNormalized = Join-Path $outputDirectory "$outputBase.background-48k.wav"
$manifestPath = Join-Path $outputDirectory "$outputBase.voiceover-manifest.json"

foreach ($generatedPath in @(
    $timelineRaw,
    $timelineNormalized,
    $backgroundRaw,
    $backgroundNormalized,
    $manifestPath
)) {
    if ((Test-Path -LiteralPath $generatedPath) -and -not $Force) {
        throw "Generated narration output already exists. Use -Force to replace it: $generatedPath"
    }
}

$timelineArguments = [System.Collections.Generic.List[string]]::new()
$timelineArguments.AddRange([string[]]@(
    '-hide_banner',
    '-loglevel', 'error',
    '-y'
))
$filterParts = [System.Collections.Generic.List[string]]::new()
$mixLabels = [System.Collections.Generic.List[string]]::new()
$segmentManifest = [System.Collections.Generic.List[object]]::new()
$previousEnd = -1.0

for ($index = 0; $index -lt $segments.Count; $index++) {
    $segment = $segments[$index]
    if (-not (Test-JsonProperty -Object $segment -Name 'id')) {
        throw 'Every narration segment must have an id.'
    }

    $id = [string]$segment.id
    $start = Get-SegmentNumber `
        -Segment $segment `
        -Names @('startSeconds', 'start') `
        -Context "segment '$id'"
    $end = Get-SegmentNumber `
        -Segment $segment `
        -Names @('endSeconds', 'end') `
        -Context "segment '$id'"
    $targetSpeech = Get-SegmentNumber `
        -Segment $segment `
        -Names @('targetSpeechSeconds') `
        -Context "segment '$id'"
    if (
        $start -lt 0 -or
        $end -le $start -or
        $end -gt $duration + 0.001
    ) {
        throw "Narration segment '$id' has invalid bounds [$start, $end)."
    }
    if ($start -lt $previousEnd - 0.0001) {
        throw "Narration segment '$id' overlaps the preceding segment."
    }
    if ($targetSpeech -le 0 -or $targetSpeech -gt ($end - $start) + 0.001) {
        throw "Narration segment '$id' targetSpeechSeconds must fit inside its window."
    }
    $previousEnd = $end

    $segmentPath = if (
        (Test-JsonProperty -Object $segment -Name 'file') -and
        -not [string]::IsNullOrWhiteSpace([string]$segment.file)
    ) {
        Resolve-VideoPath `
            -Path ([string]$segment.file) `
            -BaseDirectory $segmentRoot
    }
    else {
        $numericId = 0
        if ([int]::TryParse($id, [ref]$numericId)) {
            Join-Path $segmentRoot ('segment-{0:D2}.wav' -f $numericId)
        }
        else {
            $safeId = $id -replace '[^A-Za-z0-9._-]', '-'
            Join-Path $segmentRoot "segment-$safeId.wav"
        }
    }
    if (-not (Test-Path -LiteralPath $segmentPath -PathType Leaf)) {
        throw "Narration segment audio not found: $segmentPath"
    }

    $generatedDuration = Get-VideoDuration `
        -Path $segmentPath `
        -FfprobePath $ffprobe
    $tempo = $generatedDuration / $targetSpeech
    if ($tempo -lt $MinimumTempo -or $tempo -gt $MaximumTempo) {
        throw (
            "Narration segment '$id' requires atempo " +
            "$([Math]::Round($tempo, 3)), outside the allowed " +
            "$MinimumTempo-$MaximumTempo range. Regenerate the segment closer " +
            'to targetSpeechSeconds instead of applying an unnatural stretch.'
        )
    }

    $timelineArguments.Add('-i')
    $timelineArguments.Add($segmentPath)
    $delayMilliseconds = [int][Math]::Round($start * 1000)
    $tempoFilter = Get-AtempoFilterChain -Tempo $tempo
    $label = "voice$index"
    $filterParts.Add(
        "[$index`:a:0]" +
        'aresample=48000,' +
        'aformat=sample_fmts=fltp:channel_layouts=mono,' +
        "$tempoFilter," +
        'asetpts=PTS-STARTPTS,' +
        "adelay=$delayMilliseconds`:all=1," +
        "apad=whole_dur=$durationText," +
        "atrim=duration=$durationText," +
        'asetpts=N/SR/TB' +
        "[$label]"
    )
    $mixLabels.Add("[$label]")

    $segmentManifest.Add([pscustomobject]@{
        id = $id
        startSeconds = $start
        endSeconds = $end
        windowSeconds = [Math]::Round($end - $start, 3)
        generatedSeconds = [Math]::Round($generatedDuration, 3)
        targetSpeechSeconds = [Math]::Round($targetSpeech, 3)
        atempo = [Math]::Round($tempo, 6)
        source = $segmentPath
        sha256 = Get-VideoFileHash -Path $segmentPath
        text = if (Test-JsonProperty -Object $segment -Name 'text') {
            [string]$segment.text
        }
        else {
            ''
        }
    })
}

$filterParts.Add(
    "$($mixLabels -join '')" +
    "amix=inputs=$($segments.Count):duration=first:" +
    'dropout_transition=0:normalize=0,' +
    "atrim=duration=$durationText," +
    'asetpts=N/SR/TB,' +
    'pan=stereo|c0=c0|c1=c0[voice]'
)
$timelineArguments.AddRange([string[]]@(
    '-filter_complex', ($filterParts -join ';'),
    '-map', '[voice]',
    '-c:a', 'pcm_s16le',
    '-ar', '48000',
    '-ac', '2',
    $timelineRaw
))
Invoke-VideoCommand `
    -FilePath $ffmpeg `
    -Arguments $timelineArguments.ToArray() `
    -Operation 'assembling the narration timeline'

$voiceMeasurement = Get-LoudnormMeasurement `
    -InputPath $timelineRaw `
    -IntegratedLufs $VoiceTargetLufs `
    -TruePeakDb $VoiceTruePeakDb `
    -LoudnessRange 7 `
    -FfmpegPath $ffmpeg
$voiceFilter = New-LoudnormFilter `
    -Measurement $voiceMeasurement `
    -IntegratedLufs $VoiceTargetLufs `
    -TruePeakDb $VoiceTruePeakDb `
    -LoudnessRange 7
Invoke-VideoCommand -FilePath $ffmpeg -Operation 'normalizing narration' -Arguments @(
    '-hide_banner',
    '-loglevel', 'error',
    '-y',
    '-i', $timelineRaw,
    '-af', $voiceFilter,
    '-c:a', 'pcm_s16le',
    '-ar', '48000',
    '-ac', '2',
    $timelineNormalized
)

$backgroundMode = ''
if ($resolvedBackground) {
    $backgroundMode = 'external-audio'
    Invoke-VideoCommand -FilePath $ffmpeg -Operation 'preparing external background audio' -Arguments @(
        '-hide_banner',
        '-loglevel', 'error',
        '-y',
        '-i', $resolvedBackground,
        '-map', '0:a:0',
        '-af', (
            'aresample=48000,' +
            'aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,' +
            "apad=whole_dur=$durationText," +
            "atrim=duration=$durationText," +
            'asetpts=N/SR/TB'
        ),
        '-c:a', 'pcm_s16le',
        '-ar', '48000',
        '-ac', '2',
        $backgroundRaw
    )
}
elseif ($sourceAudioStreams.Count -gt 0) {
    $backgroundMode = 'source-video-audio'
    Invoke-VideoCommand -FilePath $ffmpeg -Operation 'extracting source background audio' -Arguments @(
        '-hide_banner',
        '-loglevel', 'error',
        '-y',
        '-i', $source,
        '-map', '0:a:0',
        '-af', (
            'aresample=48000,' +
            'aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,' +
            "apad=whole_dur=$durationText," +
            "atrim=duration=$durationText," +
            'asetpts=N/SR/TB'
        ),
        '-c:a', 'pcm_s16le',
        '-ar', '48000',
        '-ac', '2',
        $backgroundRaw
    )
}
else {
    $backgroundMode = 'silence'
    Invoke-VideoCommand -FilePath $ffmpeg -Operation 'creating a silent background' -Arguments @(
        '-hide_banner',
        '-loglevel', 'error',
        '-y',
        '-f', 'lavfi',
        '-i', 'anullsrc=r=48000:cl=stereo',
        '-t', $durationText,
        '-c:a', 'pcm_s16le',
        '-ar', '48000',
        '-ac', '2',
        $backgroundRaw
    )
}

if ($backgroundMode -eq 'silence') {
    Copy-Item -LiteralPath $backgroundRaw -Destination $backgroundNormalized -Force
}
else {
    $backgroundMeasurement = Get-LoudnormMeasurement `
        -InputPath $backgroundRaw `
        -IntegratedLufs $BackgroundTargetLufs `
        -TruePeakDb $BackgroundTruePeakDb `
        -LoudnessRange 8 `
        -FfmpegPath $ffmpeg
    $backgroundFilter = New-LoudnormFilter `
        -Measurement $backgroundMeasurement `
        -IntegratedLufs $BackgroundTargetLufs `
        -TruePeakDb $BackgroundTruePeakDb `
        -LoudnessRange 8
    Invoke-VideoCommand -FilePath $ffmpeg -Operation 'normalizing background audio' -Arguments @(
        '-hide_banner',
        '-loglevel', 'error',
        '-y',
        '-i', $backgroundRaw,
        '-af', $backgroundFilter,
        '-c:a', 'pcm_s16le',
        '-ar', '48000',
        '-ac', '2',
        $backgroundNormalized
    )
}

$thresholdText = ConvertTo-InvariantNumber `
    -Value $DuckingThreshold `
    -Format '0.######'
$ratioText = ConvertTo-InvariantNumber `
    -Value $DuckingRatio `
    -Format '0.###'
$fadeFilter = ''
if ($FinalFadeSeconds -gt 0) {
    $fadeStart = $duration - $FinalFadeSeconds
    $fadeFilter = (
        ',afade=t=out:st=' +
        (ConvertTo-InvariantNumber -Value $fadeStart -Format '0.###') +
        ':d=' +
        (ConvertTo-InvariantNumber -Value $FinalFadeSeconds -Format '0.###')
    )
}
$mixFilter = (
    '[1:a]aresample=48000,' +
    'aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,' +
    "apad=whole_dur=$durationText," +
    "atrim=duration=$durationText," +
    'asetpts=N/SR/TB[background];' +
    '[2:a]aresample=48000,' +
    'aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo,' +
    'asplit=2[voice_sidechain][voice_mix];' +
    '[background][voice_sidechain]' +
    "sidechaincompress=threshold=$thresholdText`:ratio=$ratioText`:" +
    "attack=$DuckingAttackMilliseconds`:release=$DuckingReleaseMilliseconds`:" +
    'knee=4[ducked];' +
    '[ducked][voice_mix]' +
    'amix=inputs=2:duration=first:dropout_transition=0:normalize=0,' +
    'alimiter=limit=0.891:attack=5:release=50:level=false' +
    $fadeFilter +
    ",apad=whole_dur=$durationText," +
    "atrim=duration=$durationText," +
    'asetpts=N/SR/TB[mixed]'
)

$mixArguments = [System.Collections.Generic.List[string]]::new()
$mixArguments.AddRange([string[]]@(
    '-hide_banner',
    '-loglevel', 'error',
    '-y',
    '-i', $source,
    '-i', $backgroundNormalized,
    '-i', $timelineNormalized,
    '-filter_complex', $mixFilter,
    '-map', '0:v:0',
    '-map', '[mixed]',
    '-map_metadata', '0'
))
if ($VideoCodec -eq 'copy') {
    $mixArguments.AddRange([string[]]@('-c:v', 'copy'))
}
else {
    $mixArguments.AddRange([string[]]@(
        '-c:v', 'libx264',
        '-preset', 'medium',
        '-crf', '18',
        '-pix_fmt', 'yuv420p'
    ))
}
$mixArguments.AddRange([string[]]@(
    '-c:a', 'aac',
    '-b:a', '192k',
    '-ar', '48000',
    '-ac', '2',
    '-t', $durationText,
    '-movflags', '+faststart',
    $output
))
Invoke-VideoCommand `
    -FilePath $ffmpeg `
    -Arguments $mixArguments.ToArray() `
    -Operation 'mixing narration with the video'

$outputProbe = Get-VideoProbe -Path $output -FfprobePath $ffprobe
$outputAudio = @($outputProbe.streams | Where-Object codec_type -eq 'audio')
$actualDuration = [double]::Parse(
    [string]$outputProbe.format.duration,
    [System.Globalization.CultureInfo]::InvariantCulture
)
if ([Math]::Abs($actualDuration - $duration) -gt 0.05) {
    throw "Narrated video duration is $actualDuration seconds; expected $duration seconds."
}
if ($outputAudio.Count -eq 0) {
    throw 'Narrated video has no audio stream.'
}
if ([int]$outputAudio[0].sample_rate -ne 48000 -or [int]$outputAudio[0].channels -ne 2) {
    throw 'Narrated video audio is not 48 kHz stereo.'
}

$sourceHashAfter = Get-VideoFileHash -Path $source
$sourcePreserved = $sourceHashBefore -eq $sourceHashAfter

$manifest = [pscustomobject]@{
    schemaVersion = 1
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    plan = $plan
    sourceVideo = @{
        path = $source
        sha256Before = $sourceHashBefore
        sha256After = $sourceHashAfter
        preserved = $sourcePreserved
    }
    background = @{
        mode = $backgroundMode
        source = $resolvedBackground
        raw = $backgroundRaw
        normalized = $backgroundNormalized
        targetLufs = $BackgroundTargetLufs
        truePeakTargetDb = $BackgroundTruePeakDb
    }
    narration = @{
        rawTimeline = $timelineRaw
        normalizedTimeline = $timelineNormalized
        targetLufs = $VoiceTargetLufs
        truePeakTargetDb = $VoiceTruePeakDb
        segments = $segmentManifest
    }
    ducking = @{
        filter = 'sidechaincompress'
        threshold = $DuckingThreshold
        ratio = $DuckingRatio
        attackMilliseconds = $DuckingAttackMilliseconds
        releaseMilliseconds = $DuckingReleaseMilliseconds
        knee = 4
    }
    output = @{
        path = $output
        sha256 = Get-VideoFileHash -Path $output
        bytes = (Get-Item -LiteralPath $output).Length
        durationSeconds = [Math]::Round($actualDuration, 6)
        audioSampleRate = [int]$outputAudio[0].sample_rate
        audioChannels = [int]$outputAudio[0].channels
    }
}
Write-VideoJson -InputObject $manifest -Path $manifestPath

if (-not $sourcePreserved) {
    throw "Source video hash changed while mixing narration. Inspect: $manifestPath"
}

Write-Output "NARRATION_TIMELINE=$timelineNormalized"
Write-Output "BACKGROUND=$backgroundNormalized"
Write-Output "VIDEO=$output"
Write-Output "MANIFEST=$manifestPath"
