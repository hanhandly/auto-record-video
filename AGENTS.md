# Copilot instructions

This repository records and produces repeatable Windows product videos.

When asked to create or edit a video:

1. Confirm that `pwsh`, `ffmpeg`, and `ffprobe` are available. Copilot CLI,
   PowerPoint, and Azure CLI are feature-specific prerequisites.
2. If core prerequisites are missing, direct the user to run
   `.\install-prerequisites.ps1`.
3. Preserve raw recordings and approved revisions. Use
   `.\tools\Initialize-VideoProject.ps1` and create a new revision instead of
   overwriting an earlier one.
4. Capture the narrowest useful surface. For Copilot CLI use
   `.\record-copilot-session.ps1`; for another uniquely titled window use
   `.\tools\Record-Window.ps1`. Never switch to full-desktop capture unless the
   user explicitly requests it.
5. Keep project paths, copy, colors, timestamps, and narration in configuration,
   not in reusable tool code.
6. Prefer compact cue tags and short title-only focus boxes. Do not place a
   large rectangle over long Agent output, logs, or scrolling content.
7. Build to an explicit duration. Validate that clip output durations sum to
   the target before rendering.
8. Keep one authoritative narration JSON plan. Generate TTS as independent
   segments so a single line can be regenerated without replacing the full
   voice track.
9. Never place tokens, API keys, credentials, customer data, private URLs, or
   other sensitive content in prompts, recordings, examples, manifests, or
   source control.
10. Validate final media with `.\tools\Test-VideoDeliverable.ps1`, including
    full decode, media properties, source hashes, and representative frames.
11. Keep generated recordings, audio, slide images, manifests, logs, caches,
    local settings, and credentials outside Git.

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

Run the reusable pipeline test after changing production tools:

```powershell
.\tests\Invoke-SyntheticPipelineTest.ps1
```
