[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [string]$OutputPath,

    [string]$ManifestPath,

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

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    if (-not (Test-JsonProperty -Object $Object -Name $Name)) {
        throw "$Context is missing '$Name'."
    }
    return $Object.$Name
}

$config = [System.IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
    throw "Timeline configuration not found: $config"
}

$configDirectory = [System.IO.Path]::GetDirectoryName($config)
$definition = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
if (-not (Test-JsonProperty -Object $definition -Name 'output')) {
    throw 'Timeline configuration must contain an output object.'
}
if (-not (Test-JsonProperty -Object $definition -Name 'sources')) {
    throw 'Timeline configuration must contain a sources array.'
}
if (-not (Test-JsonProperty -Object $definition -Name 'clips')) {
    throw 'Timeline configuration must contain a clips array.'
}

$outputDefinition = $definition.output
$configuredOutput = if ($OutputPath) {
    $OutputPath
}
elseif (Test-JsonProperty -Object $outputDefinition -Name 'path') {
    [string]$outputDefinition.path
}
else {
    throw 'Specify -OutputPath or output.path in the timeline configuration.'
}

$resolvedOutput = Resolve-VideoPath `
    -Path $configuredOutput `
    -BaseDirectory $configDirectory
$resolvedOutput = Assert-VideoOutputPath -Path $resolvedOutput -Force:$Force
$filterPath = [System.IO.Path]::ChangeExtension(
    $resolvedOutput,
    '.filter.txt'
)
$resolvedManifest = if ($ManifestPath) {
    Resolve-VideoPath -Path $ManifestPath -BaseDirectory $configDirectory
}
else {
    [System.IO.Path]::ChangeExtension(
        $resolvedOutput,
        '.build-manifest.json'
    )
}
foreach ($generatedPath in @($filterPath, $resolvedManifest)) {
    if ((Test-Path -LiteralPath $generatedPath) -and -not $Force) {
        throw "Generated timeline file already exists. Use -Force to replace it: $generatedPath"
    }
}

$targetDuration = [double](
    Get-RequiredProperty `
        -Object $outputDefinition `
        -Name 'durationSeconds' `
        -Context 'output'
)
$width = if (Test-JsonProperty -Object $outputDefinition -Name 'width') {
    [int]$outputDefinition.width
}
else {
    1920
}
$height = if (Test-JsonProperty -Object $outputDefinition -Name 'height') {
    [int]$outputDefinition.height
}
else {
    1080
}
$frameRate = if (Test-JsonProperty -Object $outputDefinition -Name 'frameRate') {
    [double]$outputDefinition.frameRate
}
else {
    30.0
}
$includeAudio = if (
    Test-JsonProperty -Object $outputDefinition -Name 'includeAudio'
) {
    [bool]$outputDefinition.includeAudio
}
else {
    $false
}
$sampleRate = if (
    Test-JsonProperty -Object $outputDefinition -Name 'audioSampleRate'
) {
    [int]$outputDefinition.audioSampleRate
}
else {
    48000
}
$audioChannels = if (
    Test-JsonProperty -Object $outputDefinition -Name 'audioChannels'
) {
    [int]$outputDefinition.audioChannels
}
else {
    2
}
$videoCodec = if (
    Test-JsonProperty -Object $outputDefinition -Name 'videoCodec'
) {
    [string]$outputDefinition.videoCodec
}
else {
    'libx264'
}
$preset = if (Test-JsonProperty -Object $outputDefinition -Name 'preset') {
    [string]$outputDefinition.preset
}
else {
    'medium'
}
$crf = if (Test-JsonProperty -Object $outputDefinition -Name 'crf') {
    [int]$outputDefinition.crf
}
else {
    18
}
$audioBitrate = if (
    Test-JsonProperty -Object $outputDefinition -Name 'audioBitrate'
) {
    [string]$outputDefinition.audioBitrate
}
else {
    '192k'
}
$backgroundColor = if (
    Test-JsonProperty -Object $outputDefinition -Name 'backgroundColor'
) {
    [string]$outputDefinition.backgroundColor
}
else {
    'black'
}
$fadeIn = if (
    Test-JsonProperty -Object $outputDefinition -Name 'fadeInSeconds'
) {
    [double]$outputDefinition.fadeInSeconds
}
else {
    0.0
}
$fadeOut = if (
    Test-JsonProperty -Object $outputDefinition -Name 'fadeOutSeconds'
) {
    [double]$outputDefinition.fadeOutSeconds
}
else {
    0.0
}

if (
    $targetDuration -le 0 -or
    $width -le 0 -or
    $height -le 0 -or
    $frameRate -le 0
) {
    throw 'Output duration, dimensions, and frame rate must be positive.'
}
if ($audioChannels -notin @(1, 2)) {
    throw 'Only mono or stereo output is supported.'
}
if ($backgroundColor -notmatch '^[A-Za-z]+$|^0x[0-9A-Fa-f]{6,8}$') {
    throw "backgroundColor must be a named FFmpeg color or 0xRRGGBB[AA]: $backgroundColor"
}
if ($fadeIn -lt 0 -or $fadeOut -lt 0 -or $fadeIn + $fadeOut -gt $targetDuration) {
    throw 'Output fades must be non-negative and fit inside the target duration.'
}

$ffmpeg = Resolve-VideoTool -CommandName 'ffmpeg' -WinGetPattern 'Gyan.FFmpeg'
$ffprobe = Resolve-VideoTool -CommandName 'ffprobe' -WinGetPattern 'Gyan.FFmpeg'
$sourceMap = @{}
$sourceMetadata = [System.Collections.Generic.List[object]]::new()
$ffmpegArguments = [System.Collections.Generic.List[string]]::new()
$ffmpegArguments.AddRange([string[]]@(
    '-hide_banner',
    '-loglevel', 'error',
    '-y'
))

$sourceIndex = 0
foreach ($source in @($definition.sources)) {
    $id = [string](
        Get-RequiredProperty -Object $source -Name 'id' -Context 'source'
    )
    $pathValue = [string](
        Get-RequiredProperty -Object $source -Name 'path' -Context "source '$id'"
    )
    if ([string]::IsNullOrWhiteSpace($id) -or $sourceMap.ContainsKey($id)) {
        throw "Source IDs must be non-empty and unique: $id"
    }

    $path = Resolve-VideoPath -Path $pathValue -BaseDirectory $configDirectory
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Source file not found: $path"
    }
    if (Test-SameVideoPath -First $path -Second $resolvedOutput) {
        throw "Output must not overwrite a source file: $path"
    }

    $probe = Get-VideoProbe -Path $path -FfprobePath $ffprobe
    $videoStreams = @($probe.streams | Where-Object codec_type -eq 'video')
    $audioStreams = @($probe.streams | Where-Object codec_type -eq 'audio')
    if ($videoStreams.Count -eq 0) {
        throw "Source '$id' has no video stream: $path"
    }

    $duration = [double]::Parse(
        [string]$probe.format.duration,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $sourceRecord = [pscustomobject]@{
        id = $id
        path = $path
        inputIndex = $sourceIndex
        durationSeconds = $duration
        hasAudio = $audioStreams.Count -gt 0
        videoCodec = [string]$videoStreams[0].codec_name
        width = [int]$videoStreams[0].width
        height = [int]$videoStreams[0].height
        sha256Before = Get-VideoFileHash -Path $path
    }
    $sourceMap[$id] = $sourceRecord
    $sourceMetadata.Add($sourceRecord)
    $ffmpegArguments.Add('-i')
    $ffmpegArguments.Add($path)
    $sourceIndex++
}

if ($sourceMap.Count -eq 0) {
    throw 'At least one source is required.'
}

$clips = @($definition.clips)
if ($clips.Count -eq 0) {
    throw 'At least one clip is required.'
}

$filterParts = [System.Collections.Generic.List[string]]::new()
$concatLabels = [System.Collections.Generic.List[string]]::new()
$clipManifest = [System.Collections.Generic.List[object]]::new()
$durationSum = 0.0
$frameDuration = 1.0 / $frameRate
$frameRateText = ConvertTo-InvariantNumber -Value $frameRate -Format '0.######'
$targetDurationText = ConvertTo-InvariantNumber `
    -Value $targetDuration `
    -Format '0.###'
$channelLayout = if ($audioChannels -eq 1) { 'mono' } else { 'stereo' }

for ($index = 0; $index -lt $clips.Count; $index++) {
    $clip = $clips[$index]
    $context = "clip $($index + 1)"
    $kind = ([string](
        Get-RequiredProperty -Object $clip -Name 'kind' -Context $context
    )).ToLowerInvariant()
    $sourceId = [string](
        Get-RequiredProperty -Object $clip -Name 'source' -Context $context
    )
    if (-not $sourceMap.ContainsKey($sourceId)) {
        throw "$context references unknown source '$sourceId'."
    }

    $source = $sourceMap[$sourceId]
    $outputDuration = [double](
        Get-RequiredProperty `
            -Object $clip `
            -Name 'outputDurationSeconds' `
            -Context $context
    )
    if ($outputDuration -le 0) {
        throw "$context outputDurationSeconds must be positive."
    }

    $purpose = if (Test-JsonProperty -Object $clip -Name 'purpose') {
        [string]$clip.purpose
    }
    else {
        ''
    }
    $videoLabel = "clipVideo$index"
    $audioLabel = "clipAudio$index"
    $outputDurationText = ConvertTo-InvariantNumber `
        -Value $outputDuration `
        -Format '0.###'
    $audioMode = if (Test-JsonProperty -Object $clip -Name 'audio') {
        ([string]$clip.audio).ToLowerInvariant()
    }
    elseif ($kind -eq 'motion') {
        'source'
    }
    else {
        'mute'
    }

    $sourceStart = 0.0
    $sourceEnd = 0.0
    $speedMultiplier = 0.0

    switch ($kind) {
        'motion' {
            $sourceStart = [double](
                Get-RequiredProperty `
                    -Object $clip `
                    -Name 'sourceStartSeconds' `
                    -Context $context
            )
            $sourceEnd = [double](
                Get-RequiredProperty `
                    -Object $clip `
                    -Name 'sourceEndSeconds' `
                    -Context $context
            )
            if (
                $sourceStart -lt 0 -or
                $sourceEnd -le $sourceStart -or
                $sourceEnd -gt $source.durationSeconds + 0.05
            ) {
                throw "$context has source bounds outside '$sourceId' duration $($source.durationSeconds)."
            }

            $sourceDuration = $sourceEnd - $sourceStart
            $videoRatio = $outputDuration / $sourceDuration
            $speedMultiplier = $sourceDuration / $outputDuration
            $startText = ConvertTo-InvariantNumber -Value $sourceStart
            $endText = ConvertTo-InvariantNumber -Value $sourceEnd
            $ratioText = ConvertTo-InvariantNumber -Value $videoRatio

            $filterParts.Add(
                "[$($source.inputIndex):v:0]" +
                "trim=start=$startText`:end=$endText," +
                "setpts=$ratioText*(PTS-STARTPTS)," +
                "fps=$frameRateText," +
                "scale=$width`:$height`:force_original_aspect_ratio=decrease:flags=lanczos," +
                "pad=$width`:$height`:(ow-iw)/2:(oh-ih)/2:color=$backgroundColor," +
                "setsar=1,format=yuv420p," +
                "trim=duration=$outputDurationText," +
                "setpts=N/($frameRateText*TB)[$videoLabel]"
            )
        }
        'freeze' {
            $sourceStart = if (
                Test-JsonProperty -Object $clip -Name 'sourceAtSeconds'
            ) {
                [double]$clip.sourceAtSeconds
            }
            elseif (Test-JsonProperty -Object $clip -Name 'sourceStartSeconds') {
                [double]$clip.sourceStartSeconds
            }
            else {
                throw "$context is missing 'sourceAtSeconds'."
            }
            if (
                $sourceStart -lt 0 -or
                $sourceStart -ge $source.durationSeconds
            ) {
                throw "$context freeze point is outside '$sourceId' duration $($source.durationSeconds)."
            }

            $sourceEnd = [Math]::Min(
                $source.durationSeconds,
                $sourceStart + [Math]::Max($frameDuration, 0.05)
            )
            $startText = ConvertTo-InvariantNumber -Value $sourceStart
            $endText = ConvertTo-InvariantNumber -Value $sourceEnd
            $filterParts.Add(
                "[$($source.inputIndex):v:0]" +
                "trim=start=$startText`:end=$endText," +
                'setpts=PTS-STARTPTS,' +
                "fps=$frameRateText," +
                "scale=$width`:$height`:force_original_aspect_ratio=decrease:flags=lanczos," +
                "pad=$width`:$height`:(ow-iw)/2:(oh-ih)/2:color=$backgroundColor," +
                "setsar=1,format=yuv420p," +
                "tpad=stop_mode=clone:stop_duration=$outputDurationText," +
                "trim=duration=$outputDurationText," +
                "setpts=N/($frameRateText*TB)[$videoLabel]"
            )
            if ($audioMode -eq 'source') {
                throw "$context is a freeze clip. Set audio to 'mute' rather than stretching a source audio frame."
            }
        }
        default {
            throw "$context has unsupported kind '$kind'. Use 'motion' or 'freeze'."
        }
    }

    $concatLabels.Add("[$videoLabel]")
    if ($includeAudio) {
        switch ($audioMode) {
            'source' {
                if (-not $source.hasAudio) {
                    throw "$context requests source audio, but '$sourceId' has no audio stream. Set audio to 'mute' explicitly."
                }
                if ($kind -ne 'motion') {
                    throw "$context can use source audio only for a motion clip."
                }

                $tempoFilter = Get-AtempoFilterChain -Tempo $speedMultiplier
                $startText = ConvertTo-InvariantNumber -Value $sourceStart
                $endText = ConvertTo-InvariantNumber -Value $sourceEnd
                $filterParts.Add(
                    "[$($source.inputIndex):a:0]" +
                    "atrim=start=$startText`:end=$endText," +
                    'asetpts=PTS-STARTPTS,' +
                    "$tempoFilter," +
                    "aresample=$sampleRate," +
                    "aformat=sample_fmts=fltp:sample_rates=$sampleRate`:channel_layouts=$channelLayout," +
                    "apad=whole_dur=$outputDurationText," +
                    "atrim=duration=$outputDurationText," +
                    'asetpts=N/SR/TB' +
                    "[$audioLabel]"
                )
            }
            'mute' {
                $filterParts.Add(
                    "anullsrc=r=$sampleRate`:cl=$channelLayout," +
                    "atrim=duration=$outputDurationText," +
                    'asetpts=N/SR/TB' +
                    "[$audioLabel]"
                )
            }
            default {
                throw "$context audio must be 'source' or 'mute'."
            }
        }
        $concatLabels.Add("[$audioLabel]")
    }

    $durationSum += $outputDuration
    $clipManifest.Add([pscustomobject]@{
        id = $index + 1
        kind = $kind
        source = $sourceId
        purpose = $purpose
        sourceStartSeconds = [Math]::Round($sourceStart, 6)
        sourceEndSeconds = [Math]::Round($sourceEnd, 6)
        sourceDurationSeconds = [Math]::Round($sourceEnd - $sourceStart, 6)
        outputDurationSeconds = [Math]::Round($outputDuration, 6)
        speedMultiplier = [Math]::Round($speedMultiplier, 6)
        audio = if ($includeAudio) { $audioMode } else { 'not-rendered' }
    })
}

if ([Math]::Abs($durationSum - $targetDuration) -gt 0.001) {
    throw "Clip output durations total $durationSum seconds instead of the required $targetDuration seconds."
}

if ($includeAudio) {
    $filterParts.Add(
        "$($concatLabels -join '')" +
        "concat=n=$($clips.Count):v=1:a=1[vconcat][aconcat]"
    )
}
else {
    $filterParts.Add(
        "$($concatLabels -join '')" +
        "concat=n=$($clips.Count):v=1:a=0[vconcat]"
    )
}

$videoFilters = [System.Collections.Generic.List[string]]::new()
$videoFilters.Add("trim=duration=$targetDurationText")
$videoFilters.Add("setpts=N/($frameRateText*TB)")
if ($fadeIn -gt 0) {
    $videoFilters.Add(
        "fade=t=in:st=0:d=$(ConvertTo-InvariantNumber -Value $fadeIn -Format '0.###')"
    )
}
if ($fadeOut -gt 0) {
    $fadeOutStart = $targetDuration - $fadeOut
    $videoFilters.Add(
        "fade=t=out:st=$(ConvertTo-InvariantNumber -Value $fadeOutStart -Format '0.###'):" +
        "d=$(ConvertTo-InvariantNumber -Value $fadeOut -Format '0.###')"
    )
}
$videoFilters.Add('format=rgba')
$filterParts.Add("[vconcat]$($videoFilters -join ',')[vbase]")

$overlays = [System.Collections.Generic.List[object]]::new()
if (Test-JsonProperty -Object $definition -Name 'overlayManifests') {
    foreach ($manifestValue in @($definition.overlayManifests)) {
        $overlayManifestPath = Resolve-VideoPath `
            -Path ([string]$manifestValue) `
            -BaseDirectory $configDirectory
        if (-not (Test-Path -LiteralPath $overlayManifestPath -PathType Leaf)) {
            throw "Overlay manifest not found: $overlayManifestPath"
        }

        $overlayManifest = Get-Content -LiteralPath $overlayManifestPath -Raw |
            ConvertFrom-Json
        if (
            (Test-JsonProperty -Object $overlayManifest -Name 'canvas') -and
            (
                [int]$overlayManifest.canvas.width -ne $width -or
                [int]$overlayManifest.canvas.height -ne $height
            )
        ) {
            throw "Overlay canvas in '$overlayManifestPath' does not match output dimensions $width x $height."
        }
        if (-not (Test-JsonProperty -Object $overlayManifest -Name 'items')) {
            throw "Overlay manifest has no items array: $overlayManifestPath"
        }

        $manifestDirectory = [System.IO.Path]::GetDirectoryName(
            $overlayManifestPath
        )
        foreach ($item in @($overlayManifest.items)) {
            $overlays.Add([pscustomobject]@{
                id = [string]$item.id
                file = Resolve-VideoPath `
                    -Path ([string]$item.file) `
                    -BaseDirectory $manifestDirectory
                startSeconds = [double]$item.startSeconds
                endSeconds = [double]$item.endSeconds
                x = if (Test-JsonProperty -Object $item -Name 'x') {
                    [int]$item.x
                }
                else {
                    0
                }
                y = if (Test-JsonProperty -Object $item -Name 'y') {
                    [int]$item.y
                }
                else {
                    0
                }
                opacity = if (
                    Test-JsonProperty -Object $item -Name 'opacity'
                ) {
                    [double]$item.opacity
                }
                else {
                    1.0
                }
                sourceManifest = $overlayManifestPath
            })
        }
    }
}
if (Test-JsonProperty -Object $definition -Name 'overlays') {
    foreach ($item in @($definition.overlays)) {
        $overlays.Add([pscustomobject]@{
            id = if (Test-JsonProperty -Object $item -Name 'id') {
                [string]$item.id
            }
            else {
                "overlay-$($overlays.Count + 1)"
            }
            file = Resolve-VideoPath `
                -Path ([string](
                    Get-RequiredProperty `
                        -Object $item `
                        -Name 'file' `
                        -Context 'overlay'
                )) `
                -BaseDirectory $configDirectory
            startSeconds = [double](
                Get-RequiredProperty `
                    -Object $item `
                    -Name 'startSeconds' `
                    -Context 'overlay'
            )
            endSeconds = [double](
                Get-RequiredProperty `
                    -Object $item `
                    -Name 'endSeconds' `
                    -Context 'overlay'
            )
            x = if (Test-JsonProperty -Object $item -Name 'x') {
                [int]$item.x
            }
            else {
                0
            }
            y = if (Test-JsonProperty -Object $item -Name 'y') {
                [int]$item.y
            }
            else {
                0
            }
            opacity = if (Test-JsonProperty -Object $item -Name 'opacity') {
                [double]$item.opacity
            }
            else {
                1.0
            }
            sourceManifest = $null
        })
    }
}

$overlayManifest = [System.Collections.Generic.List[object]]::new()
$previousVideoLabel = 'vbase'
for ($index = 0; $index -lt $overlays.Count; $index++) {
    $overlay = $overlays[$index]
    if (-not (Test-Path -LiteralPath $overlay.file -PathType Leaf)) {
        throw "Overlay image not found: $($overlay.file)"
    }
    if (
        $overlay.startSeconds -lt 0 -or
        $overlay.endSeconds -le $overlay.startSeconds -or
        $overlay.endSeconds -gt $targetDuration + 0.001
    ) {
        throw "Overlay '$($overlay.id)' has an invalid half-open interval."
    }
    if ($overlay.opacity -lt 0 -or $overlay.opacity -gt 1) {
        throw "Overlay '$($overlay.id)' opacity must be between 0 and 1."
    }
    if (Test-SameVideoPath -First $overlay.file -Second $resolvedOutput) {
        throw "Output must not overwrite an overlay source: $($overlay.file)"
    }

    $ffmpegArguments.AddRange([string[]]@(
        '-loop', '1',
        '-framerate', $frameRateText,
        '-i', [string]$overlay.file
    ))
    $overlayInputIndex = $sourceIndex + $index
    $preparedLabel = "overlayPrepared$index"
    $outputLabel = "overlayResult$index"
    $opacityText = ConvertTo-InvariantNumber `
        -Value ([double]$overlay.opacity) `
        -Format '0.###'
    $startText = ConvertTo-InvariantNumber `
        -Value ([double]$overlay.startSeconds) `
        -Format '0.###'
    $endText = ConvertTo-InvariantNumber `
        -Value ([double]$overlay.endSeconds) `
        -Format '0.###'
    $filterParts.Add(
        "[$overlayInputIndex`:v:0]format=rgba," +
        "colorchannelmixer=aa=$opacityText[$preparedLabel]"
    )
    $filterParts.Add(
        "[$previousVideoLabel][$preparedLabel]" +
        "overlay=x=$($overlay.x):y=$($overlay.y):" +
        "enable='gte(t,$startText)*lt(t,$endText)':" +
        "shortest=0:eof_action=pass[$outputLabel]"
    )
    $previousVideoLabel = $outputLabel

    $overlayManifest.Add([pscustomobject]@{
        id = $overlay.id
        file = $overlay.file
        sha256 = Get-VideoFileHash -Path $overlay.file
        startSeconds = [double]$overlay.startSeconds
        endSeconds = [double]$overlay.endSeconds
        interval = "[$startText, $endText)"
        x = [int]$overlay.x
        y = [int]$overlay.y
        opacity = [double]$overlay.opacity
        sourceManifest = $overlay.sourceManifest
    })
}

$filterParts.Add(
    "[$previousVideoLabel]" +
    "trim=duration=$targetDurationText," +
    "setpts=N/($frameRateText*TB)," +
    'format=yuv420p[vout]'
)

if ($includeAudio) {
    $audioFilters = [System.Collections.Generic.List[string]]::new()
    $audioFilters.Add("atrim=duration=$targetDurationText")
    $audioFilters.Add('asetpts=N/SR/TB')
    if ($fadeIn -gt 0) {
        $audioFilters.Add(
            "afade=t=in:st=0:d=$(ConvertTo-InvariantNumber -Value $fadeIn -Format '0.###')"
        )
    }
    if ($fadeOut -gt 0) {
        $fadeOutStart = $targetDuration - $fadeOut
        $audioFilters.Add(
            "afade=t=out:st=$(ConvertTo-InvariantNumber -Value $fadeOutStart -Format '0.###'):" +
            "d=$(ConvertTo-InvariantNumber -Value $fadeOut -Format '0.###')"
        )
    }
    $filterParts.Add("[aconcat]$($audioFilters -join ',')[aout]")
}

$filterGraph = $filterParts -join ';'
$filterGraph | Set-Content -LiteralPath $filterPath -Encoding utf8NoBOM

$ffmpegArguments.Add('-filter_complex')
$ffmpegArguments.Add($filterGraph)
$ffmpegArguments.AddRange([string[]]@(
    '-map', '[vout]',
    '-c:v', $videoCodec,
    '-preset', $preset,
    '-crf', [string]$crf,
    '-pix_fmt', 'yuv420p',
    '-r', $frameRateText
))
if ($includeAudio) {
    $ffmpegArguments.AddRange([string[]]@(
        '-map', '[aout]',
        '-c:a', 'aac',
        '-b:a', $audioBitrate,
        '-ar', [string]$sampleRate,
        '-ac', [string]$audioChannels
    ))
}
else {
    $ffmpegArguments.Add('-an')
}
$ffmpegArguments.AddRange([string[]]@(
    '-t', $targetDurationText,
    '-movflags', '+faststart',
    $resolvedOutput
))

Invoke-VideoCommand `
    -FilePath $ffmpeg `
    -Arguments $ffmpegArguments.ToArray() `
    -Operation 'building the configured video timeline'

$outputFile = Get-Item -LiteralPath $resolvedOutput
if ($outputFile.Length -le 0) {
    throw "Timeline output is empty: $resolvedOutput"
}

$outputProbe = Get-VideoProbe -Path $resolvedOutput -FfprobePath $ffprobe
$outputVideo = @($outputProbe.streams | Where-Object codec_type -eq 'video')[0]
$outputAudio = @($outputProbe.streams | Where-Object codec_type -eq 'audio')
$actualDuration = [double]::Parse(
    [string]$outputProbe.format.duration,
    [System.Globalization.CultureInfo]::InvariantCulture
)
$durationTolerance = [Math]::Max(0.02, 1.0 / $frameRate + 0.005)
if ([Math]::Abs($actualDuration - $targetDuration) -gt $durationTolerance) {
    throw "Timeline duration is $actualDuration seconds; expected $targetDuration seconds."
}
if (
    [int]$outputVideo.width -ne $width -or
    [int]$outputVideo.height -ne $height
) {
    throw "Timeline dimensions are $($outputVideo.width) x $($outputVideo.height); expected $width x $height."
}
if ($includeAudio -and $outputAudio.Count -eq 0) {
    throw 'Timeline was configured with audio, but the output has no audio stream.'
}
if (-not $includeAudio -and $outputAudio.Count -gt 0) {
    throw 'Timeline was configured without audio, but the output contains an audio stream.'
}

$sourcePreservation = [System.Collections.Generic.List[object]]::new()
$allSourcesPreserved = $true
foreach ($source in $sourceMetadata) {
    $hashAfter = Get-VideoFileHash -Path $source.path
    $preserved = $hashAfter -eq $source.sha256Before
    if (-not $preserved) {
        $allSourcesPreserved = $false
    }
    $sourcePreservation.Add([pscustomobject]@{
        id = $source.id
        path = $source.path
        durationSeconds = $source.durationSeconds
        hasAudio = $source.hasAudio
        sha256Before = $source.sha256Before
        sha256After = $hashAfter
        preserved = $preserved
    })
}

$manifest = [pscustomobject]@{
    schemaVersion = 1
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    config = $config
    output = @{
        path = $resolvedOutput
        sha256 = Get-VideoFileHash -Path $resolvedOutput
        bytes = $outputFile.Length
        targetDurationSeconds = $targetDuration
        actualDurationSeconds = [Math]::Round($actualDuration, 6)
        width = [int]$outputVideo.width
        height = [int]$outputVideo.height
        frameRate = [string]$outputVideo.avg_frame_rate
        videoCodec = [string]$outputVideo.codec_name
        pixelFormat = [string]$outputVideo.pix_fmt
        audioIncluded = $outputAudio.Count -gt 0
    }
    intervalSemantics = 'Overlays use half-open intervals: startSeconds <= t < endSeconds.'
    clips = $clipManifest
    overlays = $overlayManifest
    sourceProtection = @{
        allPreserved = $allSourcesPreserved
        sources = $sourcePreservation
    }
    generatedFilter = $filterPath
}
Write-VideoJson -InputObject $manifest -Path $resolvedManifest

if (-not $allSourcesPreserved) {
    throw "One or more source hashes changed while building the timeline. Inspect: $resolvedManifest"
}

Write-Output "VIDEO=$resolvedOutput"
Write-Output "FILTER=$filterPath"
Write-Output "MANIFEST=$resolvedManifest"
