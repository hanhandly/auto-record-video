[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'WinGet is required. Install or update App Installer from Microsoft Store, then run this script again.'
}

$packages = @(
    @{
        Command = 'pwsh'
        Id = 'Microsoft.PowerShell'
        Name = 'PowerShell 7'
    },
    @{
        Command = 'copilot'
        Id = 'GitHub.Copilot'
        Name = 'GitHub Copilot CLI'
    },
    @{
        Command = 'ffmpeg'
        Id = 'Gyan.FFmpeg'
        Name = 'FFmpeg'
    }
)

foreach ($package in $packages) {
    if (Get-Command $package.Command -ErrorAction SilentlyContinue) {
        Write-Host "$($package.Name) is already installed."
        continue
    }

    Write-Host "Installing $($package.Name)..."
    & winget install `
        --id $package.Id `
        --exact `
        --accept-package-agreements `
        --accept-source-agreements `
        --silent `
        --disable-interactivity

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install $($package.Name). WinGet exited with code $LASTEXITCODE."
    }
}

Write-Host ''
Write-Host 'Prerequisites are installed. Open a new PowerShell 7 window so PATH changes take effect.'
Write-Host 'Run "copilot", then use /login if authentication is required.'
