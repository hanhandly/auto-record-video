[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PresentationPath,

    [string]$OutputDirectory,

    [string]$Prefix,

    [ValidateRange(320, 7680)]
    [int]$Width = 1920,

    [ValidateRange(180, 4320)]
    [int]$Height = 1080,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'video-production-common.ps1')

Add-Type -AssemblyName System.Drawing

$presentationFile = [System.IO.Path]::GetFullPath($PresentationPath)
if (-not (Test-Path -LiteralPath $presentationFile -PathType Leaf)) {
    throw "PowerPoint presentation not found: $presentationFile"
}

$destinationRoot = if ($OutputDirectory) {
    [System.IO.Path]::GetFullPath($OutputDirectory)
}
else {
    [System.IO.Path]::GetDirectoryName($presentationFile)
}
New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($Prefix)) {
    $Prefix = [System.IO.Path]::GetFileNameWithoutExtension($presentationFile) +
        '-Slide'
}
if ($Prefix -match '[\\/:*?"<>|]') {
    throw 'Prefix contains characters that are invalid in a Windows filename.'
}

$manifestPath = Join-Path $destinationRoot "$Prefix-manifest.json"
if ((Test-Path -LiteralPath $manifestPath) -and -not $Force) {
    throw "Slide manifest already exists. Use -Force to replace it: $manifestPath"
}

$sourceHashBefore = Get-VideoFileHash -Path $presentationFile
$stagingRoot = Join-Path $env:LOCALAPPDATA (
    'auto-record-video\powerpoint-slides\' + [guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

$powerPoint = $null
$presentation = $null
$exportedSlides = [System.Collections.Generic.List[object]]::new()

try {
    $powerPoint = New-Object -ComObject PowerPoint.Application
    $presentation = $powerPoint.Presentations.Open(
        $presentationFile,
        -1,
        0,
        0
    )
    $slideCount = [int]$presentation.Slides.Count
    if ($slideCount -le 0) {
        throw 'The presentation contains no slides.'
    }

    $digits = [Math]::Max(2, $slideCount.ToString().Length)
    for ($index = 1; $index -le $slideCount; $index++) {
        $number = $index.ToString("D$digits")
        $destination = Join-Path $destinationRoot "$Prefix-$number.png"
        if ((Test-Path -LiteralPath $destination) -and -not $Force) {
            throw "Slide image already exists. Use -Force to replace it: $destination"
        }
    }

    for ($index = 1; $index -le $slideCount; $index++) {
        $number = $index.ToString("D$digits")
        $fileName = "$Prefix-$number.png"
        $stagedPath = Join-Path $stagingRoot $fileName
        $destination = Join-Path $destinationRoot $fileName

        $slide = $presentation.Slides.Item($index)
        try {
            $slide.Export($stagedPath, 'PNG', $Width, $Height)
        }
        finally {
            [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject(
                $slide
            )
        }

        if (-not (Test-Path -LiteralPath $stagedPath -PathType Leaf)) {
            throw "PowerPoint did not export slide $index."
        }

        $image = [System.Drawing.Image]::FromFile($stagedPath)
        try {
            if ($image.Width -ne $Width -or $image.Height -ne $Height) {
                throw (
                    "Slide $index rendered at $($image.Width) x $($image.Height), " +
                    "expected $Width x $Height."
                )
            }
        }
        finally {
            $image.Dispose()
        }

        Copy-Item `
            -LiteralPath $stagedPath `
            -Destination $destination `
            -Force:$Force
        $file = Get-Item -LiteralPath $destination
        $exportedSlides.Add([pscustomobject]@{
            slide = $index
            path = $file.FullName
            width = $Width
            height = $Height
            bytes = $file.Length
            sha256 = Get-VideoFileHash -Path $file.FullName
        })
    }
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
        format = 'PNG'
        width = $Width
        height = $Height
        slideCount = $exportedSlides.Count
        localStagingUsed = $true
    }
    slides = $exportedSlides
})

if (-not $sourcePreserved) {
    throw "Presentation hash changed during export. Inspect: $manifestPath"
}

Write-Output "SLIDES=$($exportedSlides.Count)"
Write-Output "OUTPUT_DIRECTORY=$destinationRoot"
Write-Output "MANIFEST=$manifestPath"
