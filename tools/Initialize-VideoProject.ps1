[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[^\\/]+$')]
    [string]$RevisionName,

    [string[]]$SourcePath = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'video-production-common.ps1')

$projectRootPath = [System.IO.Path]::GetFullPath($ProjectRoot)
$revisionRoot = Join-Path $projectRootPath $RevisionName
$directories = @(
    '01-presentation',
    '02-demo',
    '03-script',
    '04-final',
    '05-qc'
)

if (Test-Path -LiteralPath $revisionRoot) {
    $existingItems = @(Get-ChildItem -LiteralPath $revisionRoot -Force)
    if ($existingItems.Count -gt 0) {
        throw "Revision already exists and is not empty. Create a new revision instead of overwriting it: $revisionRoot"
    }
}

New-Item -ItemType Directory -Path $revisionRoot -Force | Out-Null
foreach ($directory in $directories) {
    New-Item -ItemType Directory -Path (Join-Path $revisionRoot $directory) -Force |
        Out-Null
}

$sources = [System.Collections.Generic.List[object]]::new()
foreach ($path in $SourcePath) {
    $fullPath = [System.IO.Path]::GetFullPath($path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Source file not found: $fullPath"
    }

    $file = Get-Item -LiteralPath $fullPath
    $sources.Add([pscustomobject]@{
        path = $file.FullName
        bytes = $file.Length
        lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
        sha256 = Get-VideoFileHash -Path $file.FullName
    })
}

$manifestPath = Join-Path $revisionRoot 'source-manifest.json'
$manifest = [pscustomobject]@{
    schemaVersion = 1
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    revisionRoot = $revisionRoot
    policy = 'Sources are referenced and hashed, not copied or modified. Create a new revision for each approved iteration.'
    directories = $directories
    sources = $sources
}
Write-VideoJson -InputObject $manifest -Path $manifestPath

Write-Output "REVISION_ROOT=$revisionRoot"
Write-Output "SOURCE_MANIFEST=$manifestPath"
