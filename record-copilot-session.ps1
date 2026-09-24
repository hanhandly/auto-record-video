[CmdletBinding()]
param(
    [string]$Prompt = 'Reply with one short sentence introducing GitHub Copilot CLI.',

    [string]$SessionName = 'screen-recording-demo',

    [string]$WorkDirectory = $PSScriptRoot,

    [string]$OutputPath,

    [ValidateRange(3, 3600)]
    [int]$DurationSeconds = 10,

    [ValidateRange(5, 60)]
    [int]$FrameRate = 15
)

$ErrorActionPreference = 'Stop'

function Resolve-ToolPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [string]$WinGetPattern
    )

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    if ($WinGetPattern) {
        $packageRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        if (Test-Path -LiteralPath $packageRoot) {
            $candidate = Get-ChildItem -LiteralPath $packageRoot `
                -Filter "$CommandName.exe" `
                -Recurse `
                -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -like "*$WinGetPattern*" } |
                Select-Object -First 1

            if ($candidate) {
                return $candidate.FullName
            }
        }
    }

    throw "$CommandName was not found. Run .\install-prerequisites.ps1, then open a new PowerShell 7 window."
}

if (-not (Test-Path -LiteralPath $WorkDirectory -PathType Container)) {
    throw "Work directory does not exist: $WorkDirectory"
}

$ffmpegPath = Resolve-ToolPath -CommandName 'ffmpeg' -WinGetPattern 'Gyan.FFmpeg'
$ffprobePath = Resolve-ToolPath -CommandName 'ffprobe' -WinGetPattern 'Gyan.FFmpeg'
$null = Resolve-ToolPath -CommandName 'copilot' -WinGetPattern 'GitHub.Copilot'
$windowsPowerShellPath = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShellPath)) {
    $windowsPowerShellPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
}
if (-not (Test-Path -LiteralPath $windowsPowerShellPath)) {
    throw 'Windows PowerShell was not found.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path $PSScriptRoot "output\copilot-session-$timestamp.mp4"
}

$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$title = "Copilot CLI Capture $([guid]::NewGuid().ToString('N'))"
$sessionScript = Join-Path $PSScriptRoot 'copilot-session.ps1'
$savedEnvironment = @{
    AUTO_RECORD_WINDOW_TITLE = $env:AUTO_RECORD_WINDOW_TITLE
    AUTO_RECORD_PROMPT = $env:AUTO_RECORD_PROMPT
    AUTO_RECORD_SESSION_NAME = $env:AUTO_RECORD_SESSION_NAME
    AUTO_RECORD_WORK_DIRECTORY = $env:AUTO_RECORD_WORK_DIRECTORY
}

$env:AUTO_RECORD_WINDOW_TITLE = $title
$env:AUTO_RECORD_PROMPT = $Prompt
$env:AUTO_RECORD_SESSION_NAME = $SessionName
$env:AUTO_RECORD_WORK_DIRECTORY = [System.IO.Path]::GetFullPath($WorkDirectory)

$console = $null

try {
    $console = Start-Process -FilePath "$env:WINDIR\System32\conhost.exe" `
        -ArgumentList @(
            $windowsPowerShellPath,
            '-NoLogo',
            '-NoProfile',
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            "`"$sessionScript`""
        ) `
        -PassThru

    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 250
        $window = Get-Process |
            Where-Object { $_.MainWindowTitle -eq $title } |
            Select-Object -First 1
    } until ($window -or (Get-Date) -ge $deadline)

    if (-not $window) {
        throw 'The Copilot CLI console window did not appear within 20 seconds.'
    }

    & $ffmpegPath `
        -hide_banner `
        -loglevel warning `
        -y `
        -f gdigrab `
        -framerate $FrameRate `
        -i "title=$title" `
        -t $DurationSeconds `
        -c:v libx264 `
        -preset veryfast `
        -crf 20 `
        -pix_fmt yuv420p `
        -movflags +faststart `
        $OutputPath

    if ($LASTEXITCODE -ne 0) {
        throw "FFmpeg exited with code $LASTEXITCODE."
    }
}
finally {
    if ($console) {
        $processes = Get-CimInstance Win32_Process
        $knownIds = [System.Collections.Generic.HashSet[int]]::new()
        [void]$knownIds.Add($console.Id)

        do {
            $added = $false
            foreach ($process in $processes) {
                if ($knownIds.Contains([int]$process.ParentProcessId) -and
                    $knownIds.Add([int]$process.ProcessId)) {
                    $added = $true
                }
            }
        } while ($added)

        foreach ($processId in @($knownIds) | Sort-Object -Descending) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($entry in $savedEnvironment.GetEnumerator()) {
        Set-Item -Path "Env:$($entry.Key)" -Value $entry.Value
    }
}

$video = Get-Item -LiteralPath $OutputPath
$probeJson = & $ffprobePath `
    -v error `
    -show_format `
    -show_streams `
    -of json `
    $OutputPath
if ($LASTEXITCODE -ne 0) {
    throw "ffprobe could not validate the recording: $OutputPath"
}
$probe = ($probeJson -join [Environment]::NewLine) | ConvertFrom-Json
$videoStream = @($probe.streams | Where-Object codec_type -eq 'video')[0]
if (-not $videoStream -or $video.Length -le 0) {
    throw "The recording is empty or has no video stream: $OutputPath"
}
$actualDuration = [double]::Parse(
    [string]$probe.format.duration,
    [System.Globalization.CultureInfo]::InvariantCulture
)
if ([Math]::Abs($actualDuration - $DurationSeconds) -gt 0.25) {
    throw "The recording duration is $actualDuration seconds; expected approximately $DurationSeconds seconds."
}

Write-Host "Recording created: $($video.FullName)"
Write-Host "Size: $([math]::Round($video.Length / 1KB, 1)) KB"
Write-Host "Duration: $([math]::Round($actualDuration, 3)) seconds"
Write-Host "Video: $($videoStream.codec_name), $($videoStream.width)x$($videoStream.height), $($videoStream.avg_frame_rate) fps"
