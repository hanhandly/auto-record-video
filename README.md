# Auto Record Video

A Windows PowerShell toolkit for repeatable product videos: narrow window
capture, PowerPoint export, configuration-driven recutting, compact visual
cues, segmented narration, audio mixing, and delivery QC.

The original GitHub Copilot CLI recorder remains supported. The reusable
production tools were extracted from two complete 1:59 project-introduction
workflows and keep raw recordings, earlier revisions, credentials, and
generated media out of source control.

## Requirements

- Windows 10 or Windows 11
- [PowerShell 7 or later](https://learn.microsoft.com/powershell/)
- [FFmpeg](https://ffmpeg.org/)
- WinGet, recommended for automated installation
- An active GitHub Copilot subscription and
  [GitHub Copilot CLI](https://docs.github.com/copilot/how-tos/copilot-cli/install-copilot-cli),
  required only for Copilot CLI capture
- Microsoft PowerPoint, optional for slide or animation export
- Azure CLI, optional for the Azure OpenAI TTS adapter

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

To include Azure CLI for the optional TTS adapter:

```powershell
.\install-prerequisites.ps1 -IncludeAzureCli
```

Open a new PowerShell 7 window after installation so updated `PATH` values are
available.

Authenticate Copilot CLI once:

```powershell
copilot
```

If prompted, enter `/login` and complete the GitHub sign-in flow.

## Quick start: record a Copilot CLI demo

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

## Reusable production pipeline

Create a revision and hash the untouched sources:

```powershell
.\tools\Initialize-VideoProject.ps1 `
  -ProjectRoot 'C:\path\to\project-introduction' `
  -RevisionName 'revision-1' `
  -SourcePath @(
    'C:\path\to\story.pptx',
    'C:\path\to\demo-original.mp4'
  )
```

Build overlays and an exact-duration visual master from JSON:

```powershell
.\tools\New-VideoOverlays.ps1 `
  -ConfigPath '.\my-overlays.json' `
  -OutputDirectory '.\output\overlays'

.\tools\Build-VideoTimeline.ps1 `
  -ConfigPath '.\my-timeline.json'
```

Generate narration assets, mix segmented WAV files, and validate delivery:

```powershell
.\tools\New-NarrationAssets.ps1 `
  -PlanPath '.\narration-plan.json' `
  -OutputDirectory '.\output\script'

.\tools\Mix-VideoNarration.ps1 `
  -PlanPath '.\output\script\my-project-Normalized-Plan.json' `
  -SegmentsDirectory '.\output\segments' `
  -SourceVideo '.\output\visual-master.mp4' `
  -OutputPath '.\output\narrated-final.mp4'

.\tools\Test-VideoDeliverable.ps1 `
  -VideoPath '.\output\narrated-final.mp4' `
  -ExpectedDurationSeconds 119 `
  -ExpectedWidth 1920 `
  -ExpectedHeight 1080 `
  -ExpectedFrameRate 30 `
  -RequireAudio `
  -ExpectedAudioSampleRate 48000 `
  -ExpectedAudioChannels 2
```

See [docs/production-workflow.md](docs/production-workflow.md) for the complete
workflow and [examples](examples) for project-neutral JSON templates.

### Included tools

| Tool | Purpose |
|---|---|
| `Initialize-VideoProject.ps1` | Create revision folders and hash immutable sources |
| `Record-Window.ps1` | Capture any uniquely titled visible window |
| `Export-PowerPointSlides.ps1` | Export predictable PNG files through local staging |
| `Export-PowerPointVideo.ps1` | Render PowerPoint timings and animations to MP4 |
| `New-VideoOverlays.ps1` | Generate compact cue tags and title-only focus boxes |
| `Build-VideoTimeline.ps1` | Trim, retime, freeze, concatenate, overlay, and conform |
| `New-NarrationAssets.ps1` | Generate SRT, TTS text, EDL, HTML, and normalized JSON |
| `Invoke-AzureOpenAITts.ps1` | Optionally synthesize independent WAV segments with Entra auth |
| `Mix-VideoNarration.ps1` | Fit, resample, normalize, duck, limit, and mux narration |
| `New-VideoContactSheet.ps1` | Generate labeled visual-review frames without Python |
| `Test-VideoDeliverable.ps1` | Decode, probe, measure loudness, verify hashes, and report QC |

Run the end-to-end synthetic test:

```powershell
.\tests\Invoke-SyntheticPipelineTest.ps1
```

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

## How Copilot CLI capture works

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

**Narration sounds unnaturally fast or slow**

Regenerate only that TTS segment closer to `targetSpeechSeconds`. The mixer
rejects large tempo corrections by default.

**A large highlighted output block is confusing**

Use a compact `cue` plus a short `focus` overlay on the real step title. Do not
box a long or scrolling output region.
