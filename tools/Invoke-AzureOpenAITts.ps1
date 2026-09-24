[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PlanPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true)]
    [uri]$ResourceEndpoint,

    [Parameter(Mandatory = $true)]
    [string]$DeploymentName,

    [Parameter(Mandatory = $true)]
    [string]$Model,

    [Parameter(Mandatory = $true)]
    [string]$ApiVersion,

    [string]$Voice,

    [string[]]$SegmentIds = @(),

    [ValidateRange(1, 10)]
    [int]$MaximumAttempts = 3,

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

function Get-EntraToken {
    $tokenResult = & $script:azPath account get-access-token `
        --resource https://cognitiveservices.azure.com `
        --only-show-errors `
        -o json
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not obtain a Microsoft Entra token for Azure AI services.'
    }

    return (($tokenResult -join [Environment]::NewLine) | ConvertFrom-Json).
        accessToken
}

$plan = [System.IO.Path]::GetFullPath($PlanPath)
if (-not (Test-Path -LiteralPath $plan -PathType Leaf)) {
    throw "Narration plan not found: $plan"
}
if ($ResourceEndpoint.Scheme -ne 'https') {
    throw 'ResourceEndpoint must use HTTPS.'
}
if ($ResourceEndpoint.AbsolutePath.Trim('/') -ne '') {
    throw 'ResourceEndpoint must be the resource base URL without an API path.'
}
if ([string]::IsNullOrWhiteSpace($DeploymentName)) {
    throw 'DeploymentName cannot be empty.'
}
if ([string]::IsNullOrWhiteSpace($Model)) {
    throw 'Model cannot be empty.'
}

$outputRoot = [System.IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$manifestPath = Join-Path $outputRoot 'tts-generation-manifest.json'
if ((Test-Path -LiteralPath $manifestPath) -and -not $Force) {
    throw "TTS manifest already exists. Use -Force to replace it: $manifestPath"
}
$definition = Get-Content -LiteralPath $plan -Raw | ConvertFrom-Json
if (-not (Test-JsonProperty -Object $definition -Name 'segments')) {
    throw 'Narration plan must contain a segments array.'
}

if ([string]::IsNullOrWhiteSpace($Voice)) {
    if (
        (Test-JsonProperty -Object $definition -Name 'voice') -and
        -not [string]::IsNullOrWhiteSpace([string]$definition.voice)
    ) {
        $Voice = [string]$definition.voice
    }
    else {
        throw 'Specify -Voice or set voice in the narration plan.'
    }
}

$script:azPath = Resolve-VideoTool -CommandName 'az'
$ffprobe = Resolve-VideoTool -CommandName 'ffprobe' -WinGetPattern 'Gyan.FFmpeg'
$contextJson = & $script:azPath account show `
    --query '{user:user.name,tenant:tenantId,sub:id,environment:environmentName}' `
    -o json 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI is not signed in. Select the intended tenant and subscription, then retry.'
}
$azureContext = ($contextJson -join [Environment]::NewLine) |
    ConvertFrom-Json
Write-Host (
    'Azure context: user={0}, tenant={1}, subscription={2}, environment={3}' -f
    $azureContext.user,
    $azureContext.tenant,
    $azureContext.sub,
    $azureContext.environment
)

$deployment = [uri]::EscapeDataString($DeploymentName)
$version = [uri]::EscapeDataString($ApiVersion)
$requestUri = (
    $ResourceEndpoint.AbsoluteUri.TrimEnd('/') +
    "/openai/deployments/$deployment/audio/speech?api-version=$version"
)
$segments = @(
    $definition.segments |
        Where-Object {
            $SegmentIds.Count -eq 0 -or [string]$_.id -in $SegmentIds
        } |
        Sort-Object {
            Get-SegmentNumber `
                -Segment $_ `
                -Names @('startSeconds', 'start') `
                -Context "segment '$($_.id)'"
        }
)
if ($segments.Count -eq 0) {
    throw 'No narration segments matched the requested IDs.'
}

$token = Get-EntraToken
$results = [System.Collections.Generic.List[object]]::new()
$baseInstructions = if (
    Test-JsonProperty -Object $definition -Name 'instructions'
) {
    ([string]$definition.instructions).Trim()
}
else {
    ''
}

foreach ($segment in $segments) {
    if (
        -not (Test-JsonProperty -Object $segment -Name 'id') -or
        -not (Test-JsonProperty -Object $segment -Name 'text')
    ) {
        throw 'Every narration segment must contain id and text.'
    }

    $id = [string]$segment.id
    $numericId = 0
    $fileName = if ([int]::TryParse($id, [ref]$numericId)) {
        'segment-{0:D2}.wav' -f $numericId
    }
    else {
        'segment-{0}.wav' -f ($id -replace '[^A-Za-z0-9._-]', '-')
    }
    $destination = Join-Path $outputRoot $fileName
    if ((Test-Path -LiteralPath $destination) -and -not $Force) {
        throw "Narration segment already exists. Use -Force to replace it: $destination"
    }

    $targetSpeech = Get-SegmentNumber `
        -Segment $segment `
        -Names @('targetSpeechSeconds') `
        -Context "segment '$id'"
    $segmentInstructions = if (
        Test-JsonProperty -Object $segment -Name 'instructions'
    ) {
        ([string]$segment.instructions).Trim()
    }
    else {
        ''
    }
    $instructions = @(
        $baseInstructions
        $segmentInstructions
        "Complete the supplied line naturally in about $(ConvertTo-InvariantNumber -Value $targetSpeech -Format '0.0') seconds."
        'Speak only the supplied text.'
    ) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    $payload = @{
        model = $Model
        input = ([string]$segment.text).Trim()
        voice = $Voice
        response_format = 'wav'
        speed = if (Test-JsonProperty -Object $segment -Name 'speed') {
            [double]$segment.speed
        }
        else {
            1.0
        }
        instructions = $instructions -join ' '
    } | ConvertTo-Json -Compress

    $responseMetadata = $null
    $lastError = $null
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $client = [System.Net.Http.HttpClient]::new()
        try {
            $client.Timeout = [TimeSpan]::FromSeconds(180)
            $client.DefaultRequestHeaders.Authorization =
                [System.Net.Http.Headers.AuthenticationHeaderValue]::new(
                    'Bearer',
                    $token
                )
            $content = [System.Net.Http.StringContent]::new(
                $payload,
                [System.Text.Encoding]::UTF8,
                'application/json'
            )
            $started = [DateTimeOffset]::UtcNow
            $response = $client.PostAsync(
                $requestUri,
                $content
            ).GetAwaiter().GetResult()
            $elapsed = ([DateTimeOffset]::UtcNow - $started).TotalSeconds
            $bytes = $response.Content.ReadAsByteArrayAsync().
                GetAwaiter().GetResult()

            $requestId = $null
            foreach ($headerName in @(
                'apim-request-id',
                'x-request-id',
                'request-id'
            )) {
                if ($response.Headers.Contains($headerName)) {
                    $requestId = $response.Headers.GetValues($headerName) -join ','
                    break
                }
            }

            if (-not $response.IsSuccessStatusCode) {
                $errorText = [System.Text.Encoding]::UTF8.GetString($bytes)
                throw (
                    "TTS request for segment '$id' failed with HTTP " +
                    "$([int]$response.StatusCode), requestId=$requestId, " +
                    "body=$errorText"
                )
            }

            [System.IO.File]::WriteAllBytes($destination, $bytes)
            $responseMetadata = [pscustomobject]@{
                requestId = $requestId
                elapsedSeconds = [Math]::Round($elapsed, 3)
                bytes = $bytes.Length
                attempt = $attempt
            }
            $lastError = $null
            break
        }
        catch {
            $lastError = $_
            if ($attempt -lt $MaximumAttempts) {
                if ($_.Exception.Message -match 'HTTP 401') {
                    $token = Get-EntraToken
                }
                Start-Sleep -Seconds ([Math]::Min(10, 2 * $attempt))
            }
        }
        finally {
            $client.Dispose()
        }
    }

    if ($lastError) {
        throw $lastError
    }

    $generatedDuration = Get-VideoDuration `
        -Path $destination `
        -FfprobePath $ffprobe
    $start = Get-SegmentNumber `
        -Segment $segment `
        -Names @('startSeconds', 'start') `
        -Context "segment '$id'"
    $end = Get-SegmentNumber `
        -Segment $segment `
        -Names @('endSeconds', 'end') `
        -Context "segment '$id'"
    $results.Add([pscustomobject]@{
        id = $id
        file = $destination
        sha256 = Get-VideoFileHash -Path $destination
        bytes = $responseMetadata.bytes
        startSeconds = $start
        endSeconds = $end
        windowSeconds = [Math]::Round($end - $start, 3)
        targetSpeechSeconds = $targetSpeech
        generatedSeconds = [Math]::Round($generatedDuration, 3)
        requestId = $responseMetadata.requestId
        requestElapsedSeconds = $responseMetadata.elapsedSeconds
        attempt = $responseMetadata.attempt
    })

    Start-Sleep -Milliseconds 250
}

Write-VideoJson -Path $manifestPath -InputObject ([pscustomobject]@{
    schemaVersion = 1
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    plan = $plan
    apiSurface = '/openai/deployments/{deployment}/audio/speech'
    apiVersion = $ApiVersion
    model = $Model
    voice = $Voice
    responseFormat = 'wav'
    authentication = 'Microsoft Entra ID through Azure CLI'
    azureEnvironment = [string]$azureContext.environment
    segments = $results
})

Write-Output "SEGMENTS=$($results.Count)"
Write-Output "MANIFEST=$manifestPath"
