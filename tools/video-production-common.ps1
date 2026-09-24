Set-StrictMode -Version Latest

function Resolve-VideoTool {
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

    $installCommand = if ($CommandName -eq 'az') {
        '.\install-prerequisites.ps1 -IncludeAzureCli'
    }
    else {
        '.\install-prerequisites.ps1'
    }
    throw "$CommandName was not found. Run $installCommand and open a new PowerShell 7 window."
}

function Resolve-VideoPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$BaseDirectory
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
}

function Test-SameVideoPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$First,

        [Parameter(Mandatory = $true)]
        [string]$Second
    )

    return [string]::Equals(
        [System.IO.Path]::GetFullPath($First).TrimEnd('\'),
        [System.IO.Path]::GetFullPath($Second).TrimEnd('\'),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Assert-VideoOutputPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$Force
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ((Test-Path -LiteralPath $fullPath) -and -not $Force) {
        throw "Output already exists. Use -Force to replace it: $fullPath"
    }

    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if ([string]::IsNullOrWhiteSpace($directory)) {
        throw "Output path has no parent directory: $fullPath"
    }

    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    return $fullPath
}

function Get-VideoFileHash {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-InvariantNumber {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Value,

        [string]$Format = '0.########'
    )

    return $Value.ToString(
        $Format,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function ConvertFrom-VideoRational {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($Value -notmatch '^(?<numerator>-?\d+(?:\.\d+)?)/(?<denominator>-?\d+(?:\.\d+)?)$') {
        return [double]::Parse(
            $Value,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }

    $numerator = [double]::Parse(
        $Matches.numerator,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $denominator = [double]::Parse(
        $Matches.denominator,
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    if ([Math]::Abs($denominator) -lt [double]::Epsilon) {
        throw "Invalid rational value: $Value"
    }

    return $numerator / $denominator
}

function Invoke-VideoCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Operation
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed. $([System.IO.Path]::GetFileName($FilePath)) exited with code $LASTEXITCODE."
    }
}

function Get-VideoProbe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$FfprobePath
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Media file not found: $Path"
    }

    if (-not $FfprobePath) {
        $FfprobePath = Resolve-VideoTool -CommandName 'ffprobe' -WinGetPattern 'Gyan.FFmpeg'
    }

    $json = & $FfprobePath `
        -v error `
        -show_format `
        -show_streams `
        -of json `
        $Path

    if ($LASTEXITCODE -ne 0) {
        throw "ffprobe could not inspect: $Path"
    }

    return ($json -join [Environment]::NewLine) | ConvertFrom-Json
}

function Get-VideoDuration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$FfprobePath
    )

    $probe = Get-VideoProbe -Path $Path -FfprobePath $FfprobePath
    return [double]::Parse(
        [string]$probe.format.duration,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Get-AtempoFilterChain {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Tempo
    )

    if ($Tempo -le 0) {
        throw "Audio tempo must be positive: $Tempo"
    }

    $filters = [System.Collections.Generic.List[string]]::new()
    $remaining = $Tempo

    while ($remaining -gt 2.0 + 0.0000001) {
        $filters.Add('atempo=2')
        $remaining /= 2.0
    }

    while ($remaining -lt 0.5 - 0.0000001) {
        $filters.Add('atempo=0.5')
        $remaining /= 0.5
    }

    if ([Math]::Abs($remaining - 1.0) -gt 0.0000001 -or $filters.Count -eq 0) {
        $filters.Add(
            "atempo=$(ConvertTo-InvariantNumber -Value $remaining -Format '0.######')"
        )
    }

    return $filters -join ','
}

function Get-LoudnormMeasurement {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,

        [Parameter(Mandatory = $true)]
        [double]$IntegratedLufs,

        [Parameter(Mandatory = $true)]
        [double]$TruePeakDb,

        [Parameter(Mandatory = $true)]
        [double]$LoudnessRange,

        [string]$FfmpegPath,

        [string]$AudioMap = '0:a:0'
    )

    if (-not $FfmpegPath) {
        $FfmpegPath = Resolve-VideoTool -CommandName 'ffmpeg' -WinGetPattern 'Gyan.FFmpeg'
    }

    $targetI = ConvertTo-InvariantNumber -Value $IntegratedLufs -Format '0.###'
    $targetTp = ConvertTo-InvariantNumber -Value $TruePeakDb -Format '0.###'
    $targetLra = ConvertTo-InvariantNumber -Value $LoudnessRange -Format '0.###'
    $output = & $FfmpegPath `
        -hide_banner `
        -nostats `
        -i $InputPath `
        -map $AudioMap `
        -af "loudnorm=I=$targetI`:TP=$targetTp`:LRA=$targetLra`:print_format=json" `
        -f null `
        NUL 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Loudness analysis failed for: $InputPath"
    }

    $match = [regex]::Match(
        ($output -join [Environment]::NewLine),
        '(?s)\{\s*"input_i".*?\}'
    )
    if (-not $match.Success) {
        throw "Could not parse loudness analysis for: $InputPath"
    }

    return $match.Value | ConvertFrom-Json
}

function New-LoudnormFilter {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Measurement,

        [Parameter(Mandatory = $true)]
        [double]$IntegratedLufs,

        [Parameter(Mandatory = $true)]
        [double]$TruePeakDb,

        [Parameter(Mandatory = $true)]
        [double]$LoudnessRange
    )

    $targetI = ConvertTo-InvariantNumber -Value $IntegratedLufs -Format '0.###'
    $targetTp = ConvertTo-InvariantNumber -Value $TruePeakDb -Format '0.###'
    $targetLra = ConvertTo-InvariantNumber -Value $LoudnessRange -Format '0.###'

    return @(
        "loudnorm=I=$targetI`:TP=$targetTp`:LRA=$targetLra"
        "measured_I=$($Measurement.input_i)"
        "measured_TP=$($Measurement.input_tp)"
        "measured_LRA=$($Measurement.input_lra)"
        "measured_thresh=$($Measurement.input_thresh)"
        "offset=$($Measurement.target_offset)"
        'linear=true'
        'print_format=summary'
    ) -join ':'
}

function Write-VideoJson {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [int]$Depth = 12
    )

    $directory = [System.IO.Path]::GetDirectoryName(
        [System.IO.Path]::GetFullPath($Path)
    )
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $InputObject |
        ConvertTo-Json -Depth $Depth |
        Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}
