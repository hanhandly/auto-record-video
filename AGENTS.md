# Copilot instructions

This repository records a dedicated GitHub Copilot CLI console window on Windows.

When asked to create a recording:

1. Confirm that `pwsh`, `copilot`, `ffmpeg`, and `ffprobe` are available.
2. If prerequisites are missing, direct the user to run `.\install-prerequisites.ps1`.
3. Use `.\record-copilot-session.ps1` with an explicit prompt, duration, working directory, and output path.
4. Capture only the uniquely titled console window. Do not change the script to record the entire desktop unless the user explicitly requests it.
5. Never place tokens, credentials, customer data, private URLs, or other sensitive content in the prompt or recording.
6. Validate the result with `ffprobe`, checking duration, codec, frame rate, dimensions, and a nonzero file size.
7. If visual validation is requested, extract a representative frame to a temporary directory and inspect it.
8. Keep generated recordings under `output\`. Do not commit recordings, logs, local settings, or credentials.

The recorder intentionally launches the visible child session through the
built-in Windows Console Host and Windows PowerShell. This capture path is more
reliable with FFmpeg `gdigrab`; PowerShell 7 remains an installation
prerequisite for GitHub Copilot CLI.

Example:

```powershell
.\record-copilot-session.ps1 `
  -Prompt 'Reply with one short sentence introducing GitHub Copilot CLI.' `
  -SessionName 'recording-demo' `
  -DurationSeconds 10 `
  -WorkDirectory $PWD
```
