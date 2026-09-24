# Reusable video production workflow

This workflow generalizes the production techniques used for polished product
introductions that combine an animated PowerPoint opening, a real application
Demo, timed visual cues, narration, and exact-duration delivery.

It intentionally separates **capture**, **editing**, **narration**, and
**quality control**. A capture should remain immutable; every editorial change
belongs in a new revision.

## 1. Create an immutable revision

```powershell
.\tools\Initialize-VideoProject.ps1 `
  -ProjectRoot 'C:\path\to\project-introduction' `
  -RevisionName 'revision-1' `
  -SourcePath @(
    'C:\path\to\presentation.pptx',
    'C:\path\to\original-demo.mp4'
  )
```

This creates:

```text
revision-1\
  01-presentation\
  02-demo\
  03-script\
  04-final\
  05-qc\
  source-manifest.json
```

`source-manifest.json` records each source hash. The build and QC tools verify
that source media did not change. Never overwrite an approved revision; create
`revision-2`, `revision-3`, and so on.

## 2. Capture the narrowest useful surface

For a visible application with a unique window title:

```powershell
.\tools\Record-Window.ps1 `
  -WindowTitle 'My Product Demo - Recording' `
  -DurationSeconds 90 `
  -FrameRate 30 `
  -OutputPath 'C:\path\to\revision-1\02-demo\demo-raw.mp4'
```

The existing `record-copilot-session.ps1` remains the easiest entry point for a
dedicated Copilot CLI window.

`gdigrab` captures video, not application audio. When browser playback must
stay sample-aligned with the image, capture the tab's video and audio in one
browser `MediaRecorder` stream. Recording the page and Web Audio separately can
create perceived drift even when both files have valid timestamps.

Keep an action log for automated browser Demos. It should record UTC time,
action name, selector or UI target, and the intended narration segment.

## 3. Export PowerPoint safely

Export editable slides as deterministic 1920 x 1080 PNG files:

```powershell
.\tools\Export-PowerPointSlides.ps1 `
  -PresentationPath 'C:\path\to\story.pptx' `
  -OutputDirectory 'C:\path\to\revision-1\01-presentation'
```

Render PowerPoint animation and narration timing to video:

```powershell
.\tools\Export-PowerPointVideo.ps1 `
  -PresentationPath 'C:\path\to\story.pptx' `
  -OutputPath 'C:\path\to\revision-1\01-presentation\story-raw.mp4'
```

Both tools render under `%LOCALAPPDATA%\auto-record-video\` first, then copy
the verified result to the requested destination. This avoids intermittent
PowerPoint export failures in OneDrive and other synchronized folders.

PowerPoint character-by-character animation can introduce hidden dwell time.
Treat the exported PowerPoint video as source footage and conform its timing in
the same JSON timeline as the Demo.

## 4. Prefer compact cues over large highlight rectangles

Copy `examples\overlays.example.json`, then edit the content and timing:

```powershell
.\tools\New-VideoOverlays.ps1 `
  -ConfigPath '.\my-overlays.json' `
  -OutputDirectory 'C:\path\to\revision-1\02-demo\overlays'
```

Supported overlay types:

| Type | Intended use |
|---|---|
| `cue` | A compact stage chip, action chip, and optional bottom note |
| `focus` | A short-lived rectangle around a heading, button, or small UI target |

Use large rectangles only when the target itself is small and stable. Do not
box long Agent output, scrolling logs, or an entire terminal pane. For those
areas, a stage tag plus a concise side or bottom note is easier to understand.

Suggested semantic colors:

| Color | Meaning |
|---|---|
| Gold | Workflow or authoring |
| Cyan | User action or decision |
| Magenta | Review or freshness |
| Green | Success or saved result |

Overlay intervals are half-open: `startSeconds <= t < endSeconds`. This avoids
the one-frame overlap that occurs when adjacent FFmpeg `between(...)`
expressions both include their shared endpoint.

## 5. Build an exact-duration visual timeline

Copy `examples\timeline.example.json`, replace the source paths, and make the
sum of `outputDurationSeconds` equal `output.durationSeconds`.

```powershell
.\tools\Build-VideoTimeline.ps1 `
  -ConfigPath '.\my-timeline.json'
```

Each clip is one of:

- `motion`: trim a source interval and fit it to an explicit output duration;
- `freeze`: hold one source frame for an explicit output duration.

For motion clips:

```text
speedMultiplier =
  (sourceEndSeconds - sourceStartSeconds) / outputDurationSeconds
```

If `includeAudio` is true, every clip must explicitly resolve to:

- `audio: "source"` to retime its source audio with pitch-preserving `atempo`;
- `audio: "mute"` to insert exact-duration silence.

The builder:

- validates source bounds and exact duration totals;
- supports multiple source recordings;
- normalizes every clip to one size, frame rate, SAR, and pixel format;
- applies overlays from one or more generated manifests;
- writes the exact FFmpeg graph to `*.filter.txt`;
- records clip speeds, source hashes, overlay hashes, and media properties in
  `*.build-manifest.json`;
- verifies all source hashes again after rendering.

When old highlights are baked into encoded pixels, do not try to erase them.
Return to the untouched recording and recut representative intervals.

## 6. Maintain one authoritative narration plan

Copy `examples\narration-plan.example.json` and keep all timing and wording in
that file.

```powershell
.\tools\New-NarrationAssets.ps1 `
  -PlanPath '.\narration-plan.json' `
  -OutputDirectory 'C:\path\to\revision-1\03-script'
```

The command validates non-overlapping windows and generates:

- SRT accessibility captions;
- a timestamped TTS text file;
- a CSV edit decision list;
- a human-readable HTML timeline;
- a normalized JSON plan for synthesis and mixing.

Narration is intentionally segmented. If one line changes, regenerate only
that segment rather than replacing the full voice track.

### Optional Azure OpenAI TTS adapter

The repository includes a parameterized Microsoft Entra adapter. It contains
no endpoint, deployment, subscription, account, or credential defaults.

First select and verify the intended Azure context:

```powershell
az account show --query "{user:user.name, tenant:tenantId, sub:id, env:environmentName}" -o json
```

Then generate WAV segments:

```powershell
.\tools\Invoke-AzureOpenAITts.ps1 `
  -PlanPath '.\example-project-Normalized-Plan.json' `
  -OutputDirectory 'C:\path\to\revision-1\03-script\segments' `
  -ResourceEndpoint 'https://<resource>.openai.azure.com' `
  -DeploymentName '<tts-deployment>' `
  -Model 'gpt-4o-mini-tts' `
  -ApiVersion '<supported-api-version>' `
  -Voice 'marin'
```

The adapter obtains a short-lived token through Azure CLI and never writes it
to disk. The manifest retains request IDs and durations, not credentials.

## 7. Fit, normalize, duck, and mix narration

```powershell
.\tools\Mix-VideoNarration.ps1 `
  -PlanPath '.\example-project-Normalized-Plan.json' `
  -SegmentsDirectory 'C:\path\to\revision-1\03-script\segments' `
  -SourceVideo 'C:\path\to\revision-1\04-final\visual-master.mp4' `
  -OutputPath 'C:\path\to\revision-1\04-final\narrated-final.mp4'
```

By default the tool:

- resamples every narration segment to 48 kHz;
- fits each segment to `targetSpeechSeconds` with pitch-preserving `atempo`;
- refuses large tempo corrections outside 0.75-1.35;
- normalizes narration near -17 LUFS;
- uses the source video's audio as background, or an explicit
  `-BackgroundAudio`;
- normalizes background near -29 LUFS;
- applies sidechain ducking beneath narration;
- limits peaks, fades the final 0.5 seconds, and writes 48 kHz stereo AAC;
- leaves the source video unchanged and writes a voiceover manifest.

If the generated line needs a large tempo correction, regenerate the TTS
segment closer to its target instead of forcing unnatural speech.

## 8. Run delivery QC

```powershell
.\tools\Test-VideoDeliverable.ps1 `
  -VideoPath 'C:\path\to\revision-1\04-final\narrated-final.mp4' `
  -ExpectedDurationSeconds 119 `
  -ExpectedWidth 1920 `
  -ExpectedHeight 1080 `
  -ExpectedFrameRate 30 `
  -RequireAudio `
  -ExpectedAudioSampleRate 48000 `
  -ExpectedAudioChannels 2 `
  -ExpectedIntegratedLufs -17 `
  -IntegratedLufsTolerance 2 `
  -MaximumTruePeakDbfs -1 `
  -SourceManifestPath 'C:\path\to\revision-1\source-manifest.json' `
  -ContactSheetTimes @(0.5, 34.8, 35.2, 58.0, 82.0, 118.2)
```

QC validates:

- nonzero output and a readable video stream;
- exact duration within the configured tolerance;
- resolution, frame rate, audio sample rate, and channel count;
- no unintended subtitle stream;
- full FFmpeg audio/video decode;
- integrated loudness, loudness range, and true peak measurement;
- every original source hash;
- representative labeled frames in a PNG contact sheet.

Encoded H.264 frames that look frozen are not guaranteed to have identical
pixel hashes. When verifying a hold, compare a small image-difference threshold
across representative frames rather than demanding byte-identical frames.

## 9. Run the repository self-test

```powershell
.\tests\Invoke-SyntheticPipelineTest.ps1
```

The test creates all temporary media under
`%LOCALAPPDATA%\auto-record-video\tests\`, exercises motion clips, fast-forward,
a freeze hold, source/muted audio, cue and focus overlays, narration assets,
24 kHz input narration, 48 kHz mixing, source-hash verification, full decode,
and contact-sheet generation. It removes its temporary directory unless
`-KeepArtifacts` is specified.

## Delivery checklist

1. Raw recordings and approved revisions are unchanged.
2. Clip durations sum to the declared target.
3. Narration describes what is visible in the same time window.
4. Long output uses compact tags, not oversized rectangles.
5. Speech fits without aggressive tempo correction.
6. Final audio is 48 kHz stereo and narration remains intelligible.
7. Full decode, media properties, source hashes, and contact sheets pass.
8. Generated videos, audio, logs, credentials, and local settings remain
   outside Git.
