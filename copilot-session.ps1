$ErrorActionPreference = 'Stop'

$title = $env:AUTO_RECORD_WINDOW_TITLE
$prompt = $env:AUTO_RECORD_PROMPT
$sessionName = $env:AUTO_RECORD_SESSION_NAME
$workDirectory = $env:AUTO_RECORD_WORK_DIRECTORY

if ([string]::IsNullOrWhiteSpace($title) -or
    [string]::IsNullOrWhiteSpace($prompt) -or
    [string]::IsNullOrWhiteSpace($sessionName) -or
    [string]::IsNullOrWhiteSpace($workDirectory)) {
    throw 'The recording environment is incomplete. Start this script through record-copilot-session.ps1.'
}

$Host.UI.RawUI.WindowTitle = $title
Set-Location -LiteralPath $workDirectory
Clear-Host

copilot -i $prompt `
    --name $sessionName `
    --no-auto-update

Start-Sleep -Seconds 3
