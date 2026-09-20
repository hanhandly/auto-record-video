# Auto Record GitHub Copilot CLI

A small Windows PowerShell project that opens a dedicated GitHub Copilot CLI
session and records only that console window with FFmpeg.

The scripts are intended for repeatable demos and tutorials. They do not record
the full desktop, do not enable `--allow-all`, and do not store credentials.

## Requirements

- Windows 10 or Windows 11
- [PowerShell 7 or later](https://learn.microsoft.com/powershell/)
- An active GitHub Copilot subscription
- [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/copilot-cli/install-copilot-cli)
- [FFmpeg](https://ffmpeg.org/)
- WinGet, recommended for automated installation

This project uses FFmpeg's Windows `gdigrab` input, so recording is currently
Windows-only.

## Download

```powershell
git clone https://github.com/hanhandly/auto-record-video.git
Set-Location .\auto-record-video
```

## Install prerequisites

Open PowerShell and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-prerequisites.ps1
```

The installer uses these WinGet packages:

```powershell
winget install Microsoft.PowerShell
winget install GitHub.Copilot
winget install Gyan.FFmpeg
```

Open a new PowerShell 7 window after installation so updated `PATH` values are
available.

Authenticate Copilot CLI once:

```powershell
copilot
```

If prompted, enter `/login` and complete the GitHub sign-in flow.

## Record a demo

From this repository:

```powershell
.\record-copilot-session.ps1
```

The default recording is 10 seconds and is written to:

```text
output\copilot-session-YYYYMMDD-HHmmss.mp4
```

Record a custom task:

```powershell
.\record-copilot-session.ps1 `
  -Prompt 'Explain what this repository does in two short sentences.' `
  -SessionName 'repository-introduction' `
  -DurationSeconds 15 `
  -WorkDirectory 'C:\path\to\your\project' `
  -OutputPath 'C:\path\to\recordings\demo.mp4'
```

### Parameters

| Parameter | Purpose | Default |
|---|---|---|
| `Prompt` | Initial prompt sent to the new Copilot session | Short Copilot CLI introduction |
| `SessionName` | Name saved in Copilot session history | `screen-recording-demo` |
| `WorkDirectory` | Directory in which Copilot starts | This repository |
| `OutputPath` | Destination MP4 file | Timestamped file under `output\` |
| `DurationSeconds` | Recording duration | `10` |
| `FrameRate` | Frames recorded per second | `15` |

The recorder stops the dedicated console and its child processes after the
requested duration. It does not stop unrelated Copilot or terminal processes.

## Let Copilot operate this project

Start Copilot CLI in the cloned repository:

```powershell
copilot -C C:\path\to\auto-record-video
```

Then ask:

```text
Read AGENTS.md and record a 12-second Copilot CLI demo. Use a harmless prompt,
save it under output, validate the MP4 with ffprobe, and tell me its path.
```

`AGENTS.md` tells Copilot to use window-only capture, avoid sensitive content,
and validate the generated video.

For a non-interactive parent session:

```powershell
copilot -p "Read AGENTS.md and record a 12-second harmless Copilot CLI demo." `
  -C C:\path\to\auto-record-video `
  --allow-tool='shell(pwsh:*)'
```

Review permissions before using broader tool access. This project does not
require `--allow-all` for ordinary recordings.

## Privacy and safety

- The script records only a uniquely titled console window.
- Do not include secrets, tokens, private URLs, customer information, or
  confidential source code in recorded prompts.
- Close authentication dialogs before recording.
- Generated videos, audio, logs, and local settings are ignored by Git.
- Confirm the captured video before sharing it publicly.

## How it works

1. `record-copilot-session.ps1` creates a unique window title and launches a
   dedicated Windows console through `conhost.exe`.
2. `copilot-session.ps1` starts a named interactive Copilot CLI session with
   the requested prompt.
3. FFmpeg captures only the matching window using `gdigrab`.
4. At the requested duration, the recorder stops only the launched process
   tree and saves an H.264 MP4.

FFmpeg is free and open-source software. The `Gyan.FFmpeg` Windows builds
installed by this project are distributed under GPLv3; review the applicable
licenses if redistributing FFmpeg binaries as part of another product.

## Troubleshooting

**`ffmpeg`, `pwsh`, or `copilot` is not found**

Run `.\install-prerequisites.ps1`, then open a new PowerShell 7 window.

**The recording window does not appear**

Run `copilot` directly first and complete `/login`. Then retry the recording.

**The output is blank**

Keep the dedicated console visible and not minimized while recording. Another
window may cover it, but only the target window itself is captured.

**Copilot waits for tool permission**

Use a harmless prompt that does not need tools, or run the task manually once
and grant only the specific permissions it requires.
