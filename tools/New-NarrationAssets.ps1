[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PlanPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

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
        [Parameter(Mandatory = $true)][string]$Context,
        [switch]$Optional
    )

    foreach ($name in $Names) {
        if (Test-JsonProperty -Object $Segment -Name $name) {
            return [double]$Segment.$name
        }
    }

    if ($Optional) {
        return $null
    }
    throw "$Context is missing one of: $($Names -join ', ')."
}

function ConvertTo-SrtTimestamp {
    param([Parameter(Mandatory = $true)][double]$Seconds)

    $milliseconds = [int64][Math]::Round($Seconds * 1000)
    $hours = [Math]::Floor($milliseconds / 3600000)
    $milliseconds %= 3600000
    $minutes = [Math]::Floor($milliseconds / 60000)
    $milliseconds %= 60000
    $wholeSeconds = [Math]::Floor($milliseconds / 1000)
    $milliseconds %= 1000
    return '{0:00}:{1:00}:{2:00},{3:000}' -f @(
        $hours,
        $minutes,
        $wholeSeconds,
        $milliseconds
    )
}

function ConvertTo-ClockTimestamp {
    param([Parameter(Mandatory = $true)][double]$Seconds)

    $milliseconds = [int64][Math]::Round($Seconds * 1000)
    $minutes = [Math]::Floor($milliseconds / 60000)
    $milliseconds %= 60000
    $wholeSeconds = [Math]::Floor($milliseconds / 1000)
    $milliseconds %= 1000
    return '{0:00}:{1:00}.{2:000}' -f @(
        $minutes,
        $wholeSeconds,
        $milliseconds
    )
}

$plan = [System.IO.Path]::GetFullPath($PlanPath)
if (-not (Test-Path -LiteralPath $plan -PathType Leaf)) {
    throw "Narration plan not found: $plan"
}

$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$definition = Get-Content -LiteralPath $plan -Raw | ConvertFrom-Json

if (-not (Test-JsonProperty -Object $definition -Name 'durationSeconds')) {
    throw 'Narration plan must contain durationSeconds.'
}
if (-not (Test-JsonProperty -Object $definition -Name 'segments')) {
    throw 'Narration plan must contain a segments array.'
}

$title = if (Test-JsonProperty -Object $definition -Name 'title') {
    [string]$definition.title
}
else {
    [System.IO.Path]::GetFileNameWithoutExtension($plan)
}
$slug = if (Test-JsonProperty -Object $definition -Name 'slug') {
    [string]$definition.slug
}
else {
    $title.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
}
$slug = $slug.Trim('-')
if ([string]::IsNullOrWhiteSpace($slug)) {
    throw 'Narration plan slug resolves to an empty filename.'
}

$duration = [double]$definition.durationSeconds
if ($duration -le 0) {
    throw 'Narration durationSeconds must be positive.'
}

$normalizedSegments = [System.Collections.Generic.List[object]]::new()
$ids = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($segment in @($definition.segments)) {
    if (-not (Test-JsonProperty -Object $segment -Name 'id')) {
        throw 'Every narration segment must have an id.'
    }
    if (-not (Test-JsonProperty -Object $segment -Name 'text')) {
        throw "Narration segment '$($segment.id)' is missing text."
    }

    $id = [string]$segment.id
    if ([string]::IsNullOrWhiteSpace($id) -or -not $ids.Add($id)) {
        throw "Narration segment IDs must be non-empty and unique: $id"
    }

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
        -Context "segment '$id'" `
        -Optional
    if ($null -eq $targetSpeech) {
        $targetSpeech = $end - $start
    }

    if ($start -lt 0 -or $end -le $start -or $end -gt $duration + 0.001) {
        throw "Narration segment '$id' has invalid bounds [$start, $end) for a $duration-second plan."
    }
    if ($targetSpeech -le 0 -or $targetSpeech -gt ($end - $start) + 0.001) {
        throw "Narration segment '$id' targetSpeechSeconds must fit inside its window."
    }

    $text = ([string]$segment.text).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "Narration segment '$id' has empty text."
    }

    $normalizedSegments.Add([pscustomobject]@{
        id = $id
        section = if (Test-JsonProperty -Object $segment -Name 'section') {
            [string]$segment.section
        }
        else {
            ''
        }
        startSeconds = $start
        endSeconds = $end
        targetSpeechSeconds = $targetSpeech
        speed = if (Test-JsonProperty -Object $segment -Name 'speed') {
            [double]$segment.speed
        }
        else {
            1.0
        }
        visual = if (Test-JsonProperty -Object $segment -Name 'visual') {
            [string]$segment.visual
        }
        else {
            ''
        }
        text = $text
        file = if (Test-JsonProperty -Object $segment -Name 'file') {
            [string]$segment.file
        }
        else {
            $null
        }
    })
}

$normalizedSegments = @(
    $normalizedSegments |
        Sort-Object startSeconds, endSeconds
)
if ($normalizedSegments.Count -eq 0) {
    throw 'Narration plan contains no segments.'
}

for ($index = 1; $index -lt $normalizedSegments.Count; $index++) {
    $previous = $normalizedSegments[$index - 1]
    $current = $normalizedSegments[$index]
    if ($current.startSeconds -lt $previous.endSeconds - 0.0001) {
        throw "Narration segments '$($previous.id)' and '$($current.id)' overlap."
    }
}

$paths = @{
    Srt = Join-Path $outputRoot "$slug-Narration.srt"
    Tts = Join-Path $outputRoot "$slug-TTS.txt"
    Edl = Join-Path $outputRoot "$slug-EDL.csv"
    Timeline = Join-Path $outputRoot "$slug-Timeline.html"
    NormalizedPlan = Join-Path $outputRoot "$slug-Normalized-Plan.json"
}
foreach ($path in $paths.Values) {
    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        throw "Narration asset already exists. Use -Force to replace it: $path"
    }
}

$srtLines = [System.Collections.Generic.List[string]]::new()
for ($index = 0; $index -lt $normalizedSegments.Count; $index++) {
    $segment = $normalizedSegments[$index]
    $srtLines.Add([string]($index + 1))
    $srtLines.Add(
        "$(ConvertTo-SrtTimestamp -Seconds $segment.startSeconds) --> " +
        "$(ConvertTo-SrtTimestamp -Seconds $segment.endSeconds)"
    )
    $srtLines.Add($segment.text)
    $srtLines.Add('')
}
$srtLines -join [Environment]::NewLine |
    Set-Content -LiteralPath $paths.Srt -Encoding utf8NoBOM

$ttsLines = [System.Collections.Generic.List[string]]::new()
$ttsLines.Add("$title - narration")
$ttsLines.Add('')
foreach ($segment in $normalizedSegments) {
    $ttsLines.Add(
        "[$(ConvertTo-ClockTimestamp -Seconds $segment.startSeconds) - " +
        "$(ConvertTo-ClockTimestamp -Seconds $segment.endSeconds)] " +
        $segment.text
    )
}
$ttsLines.Add('')
$ttsLines -join [Environment]::NewLine |
    Set-Content -LiteralPath $paths.Tts -Encoding utf8NoBOM

$normalizedSegments |
    Select-Object `
        id,
        section,
        startSeconds,
        endSeconds,
        @{
            Name = 'windowSeconds'
            Expression = {
                [Math]::Round($_.endSeconds - $_.startSeconds, 3)
            }
        },
        targetSpeechSeconds,
        speed,
        visual,
        text |
    Export-Csv -LiteralPath $paths.Edl -NoTypeInformation -Encoding utf8BOM

$htmlRows = foreach ($segment in $normalizedSegments) {
    $section = [System.Net.WebUtility]::HtmlEncode($segment.section)
    $visual = [System.Net.WebUtility]::HtmlEncode($segment.visual)
    $text = [System.Net.WebUtility]::HtmlEncode($segment.text)
    @"
<tr>
<td>$([System.Net.WebUtility]::HtmlEncode($segment.id))</td>
<td>$section</td>
<td>$(ConvertTo-ClockTimestamp -Seconds $segment.startSeconds)<br>$(ConvertTo-ClockTimestamp -Seconds $segment.endSeconds)</td>
<td>$visual</td>
<td>$text</td>
</tr>
"@
}

$encodedTitle = [System.Net.WebUtility]::HtmlEncode($title)
$timelineHtml = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>$encodedTitle - video timeline</title>
<style>
body { margin: 0; background: #080e18; color: #f6f9fc; font-family: Arial, sans-serif; }
.page { max-width: 1120px; margin: 0 auto; padding: 34px 42px 48px; }
h1 { margin: 0 0 8px; font-size: 30px; }
.lead { color: #9cadc4; margin-bottom: 24px; }
.rule { border: 1px solid #49e0a7; background: #101b2d; padding: 14px 18px; color: #49e0a7; }
table { width: 100%; border-collapse: collapse; margin-top: 22px; }
th, td { border: 1px solid #2b3d56; padding: 10px; vertical-align: top; }
th { background: #111d30; color: #37d5ff; text-align: left; }
td { background: #0d1726; line-height: 1.4; }
.foot { margin-top: 18px; color: #93a4bc; font-size: 12px; }
</style>
</head>
<body>
<div class="page">
<h1>$encodedTitle</h1>
<div class="lead">$duration-second narration and visual alignment plan.</div>
<div class="rule"><strong>Timing rule:</strong> every narration segment must finish inside its assigned visual window.</div>
<table>
<thead><tr><th>#</th><th>Section</th><th>Time</th><th>Visual</th><th>Narration</th></tr></thead>
<tbody>$($htmlRows -join [Environment]::NewLine)</tbody>
</table>
<div class="foot">The SRT is an accessibility asset. This workflow does not burn subtitles into the final video automatically.</div>
</div>
</body>
</html>
"@
$timelineHtml | Set-Content -LiteralPath $paths.Timeline -Encoding utf8NoBOM

$normalizedPlan = [pscustomobject]@{
    schemaVersion = 1
    title = $title
    slug = $slug
    language = if (Test-JsonProperty -Object $definition -Name 'language') {
        [string]$definition.language
    }
    else {
        'en-US'
    }
    durationSeconds = $duration
    voice = if (Test-JsonProperty -Object $definition -Name 'voice') {
        [string]$definition.voice
    }
    else {
        ''
    }
    instructions = if (
        Test-JsonProperty -Object $definition -Name 'instructions'
    ) {
        [string]$definition.instructions
    }
    else {
        ''
    }
    segments = $normalizedSegments
}
Write-VideoJson -InputObject $normalizedPlan -Path $paths.NormalizedPlan

$wordCount = 0
foreach ($segment in $normalizedSegments) {
    $wordCount += @(
        $segment.text -split '\s+' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    ).Count
}

Write-Output "SEGMENTS=$($normalizedSegments.Count)"
Write-Output "WORDS=$wordCount"
Write-Output "AVERAGE_WPM=$([Math]::Round($wordCount / $duration * 60, 1))"
Write-Output "SRT=$($paths.Srt)"
Write-Output "TTS=$($paths.Tts)"
Write-Output "EDL=$($paths.Edl)"
Write-Output "TIMELINE=$($paths.Timeline)"
Write-Output "NORMALIZED_PLAN=$($paths.NormalizedPlan)"
