[CmdletBinding()]
param(
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..')
)
$toolsRoot = Join-Path $repositoryRoot 'tools'
. (Join-Path $toolsRoot 'video-production-common.ps1')

$ffmpeg = Resolve-VideoTool -CommandName 'ffmpeg' -WinGetPattern 'Gyan.FFmpeg'
$testRoot = Join-Path $env:LOCALAPPDATA (
    'auto-record-video\tests\' + [guid]::NewGuid().ToString('N')
)
$sourceRoot = Join-Path $testRoot 'sources'
$projectRoot = Join-Path $testRoot 'project'
$sourceA = Join-Path $sourceRoot 'source-a.mp4'
$sourceB = Join-Path $sourceRoot 'source-b.mp4'

New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null
New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

try {
    Invoke-VideoCommand -FilePath $ffmpeg -Operation 'creating synthetic source A' -Arguments @(
        '-hide_banner',
        '-loglevel', 'error',
        '-y',
        '-f', 'lavfi',
        '-i', 'testsrc2=size=640x360:rate=30:duration=4',
        '-f', 'lavfi',
        '-i', 'sine=frequency=220:sample_rate=48000:duration=4',
        '-shortest',
        '-c:v', 'libx264',
        '-preset', 'veryfast',
        '-crf', '20',
        '-pix_fmt', 'yuv420p',
        '-c:a', 'aac',
        '-b:a', '128k',
        '-ar', '48000',
        '-ac', '2',
        $sourceA
    )
    Invoke-VideoCommand -FilePath $ffmpeg -Operation 'creating synthetic source B' -Arguments @(
        '-hide_banner',
        '-loglevel', 'error',
        '-y',
        '-f', 'lavfi',
        '-i', 'testsrc=size=640x360:rate=30:duration=3',
        '-f', 'lavfi',
        '-i', 'sine=frequency=330:sample_rate=48000:duration=3',
        '-shortest',
        '-c:v', 'libx264',
        '-preset', 'veryfast',
        '-crf', '20',
        '-pix_fmt', 'yuv420p',
        '-c:a', 'aac',
        '-b:a', '128k',
        '-ar', '48000',
        '-ac', '2',
        $sourceB
    )

    $initializeOutput = & (Join-Path $toolsRoot 'Initialize-VideoProject.ps1') `
        -ProjectRoot $projectRoot `
        -RevisionName 'revision-1' `
        -SourcePath @($sourceA, $sourceB)
    $revisionRoot = Join-Path $projectRoot 'revision-1'
    $sourceManifest = Join-Path $revisionRoot 'source-manifest.json'
    if (-not (Test-Path -LiteralPath $sourceManifest -PathType Leaf)) {
        throw "Revision initialization failed: $($initializeOutput -join '; ')"
    }

    $overlayConfig = Join-Path $revisionRoot '03-script\overlays.json'
    $overlayDirectory = Join-Path $revisionRoot '02-demo\overlays'
    Write-VideoJson -Path $overlayConfig -InputObject ([pscustomobject]@{
        schemaVersion = 1
        canvas = @{
            width = 640
            height = 360
        }
        items = @(
            @{
                id = 'opening-cue'
                type = 'cue'
                startSeconds = 0.0
                endSeconds = 2.0
                color = 'cyan'
                stage = 'SYNTHETIC TEST'
                action = 'TIMELINE'
                note = 'Compact cues stay clear of the main content.'
            },
            @{
                id = 'focus-box'
                type = 'focus'
                startSeconds = 3.0
                endSeconds = 5.0
                color = 'gold'
                x = 30
                y = 80
                width = 260
                height = 80
            }
        )
    })
    & (Join-Path $toolsRoot 'New-VideoOverlays.ps1') `
        -ConfigPath $overlayConfig `
        -OutputDirectory $overlayDirectory `
        -Force | Out-Null

    $timelineConfig = Join-Path $revisionRoot '03-script\timeline.json'
    $timelineVideo = Join-Path $revisionRoot '02-demo\synthetic-timeline.mp4'
    Write-VideoJson -Path $timelineConfig -InputObject ([pscustomobject]@{
        schemaVersion = 1
        output = @{
            path = $timelineVideo
            durationSeconds = 6.0
            width = 640
            height = 360
            frameRate = 30
            includeAudio = $true
            audioSampleRate = 48000
            audioChannels = 2
            videoCodec = 'libx264'
            preset = 'veryfast'
            crf = 20
            audioBitrate = '128k'
            backgroundColor = 'black'
            fadeInSeconds = 0.1
            fadeOutSeconds = 0.2
        }
        sources = @(
            @{
                id = 'a'
                path = $sourceA
            },
            @{
                id = 'b'
                path = $sourceB
            }
        )
        clips = @(
            @{
                kind = 'motion'
                source = 'a'
                sourceStartSeconds = 0.0
                sourceEndSeconds = 2.0
                outputDurationSeconds = 2.0
                audio = 'source'
                purpose = 'normal-speed opening'
            },
            @{
                kind = 'freeze'
                source = 'a'
                sourceAtSeconds = 2.2
                outputDurationSeconds = 1.0
                audio = 'mute'
                purpose = 'readability hold'
            },
            @{
                kind = 'motion'
                source = 'b'
                sourceStartSeconds = 0.0
                sourceEndSeconds = 3.0
                outputDurationSeconds = 2.0
                audio = 'source'
                purpose = 'controlled fast-forward'
            },
            @{
                kind = 'motion'
                source = 'a'
                sourceStartSeconds = 2.0
                sourceEndSeconds = 4.0
                outputDurationSeconds = 1.0
                audio = 'mute'
                purpose = 'muted closing acceleration'
            }
        )
        overlayManifests = @(
            (Join-Path $overlayDirectory 'overlay-manifest.json')
        )
    })
    & (Join-Path $toolsRoot 'Build-VideoTimeline.ps1') `
        -ConfigPath $timelineConfig `
        -Force | Out-Null

    $narrationPlan = Join-Path $revisionRoot '03-script\narration-plan.json'
    Write-VideoJson -Path $narrationPlan -InputObject ([pscustomobject]@{
        schemaVersion = 1
        title = 'Synthetic reusable video pipeline'
        slug = 'synthetic-pipeline'
        language = 'en-US'
        durationSeconds = 6.0
        voice = 'test-tone'
        segments = @(
            @{
                id = 1
                section = 'Opening'
                startSeconds = 0.2
                endSeconds = 1.2
                targetSpeechSeconds = 0.6
                visual = 'Opening cue'
                text = 'Synthetic opening narration.'
            },
            @{
                id = 2
                section = 'Hold'
                startSeconds = 2.2
                endSeconds = 3.2
                targetSpeechSeconds = 0.6
                visual = 'Freeze-frame readability hold'
                text = 'Synthetic hold narration.'
            },
            @{
                id = 3
                section = 'Close'
                startSeconds = 4.2
                endSeconds = 5.2
                targetSpeechSeconds = 0.6
                visual = 'Closing accelerated clip'
                text = 'Synthetic closing narration.'
            }
        )
    })

    $narrationAssets = Join-Path $revisionRoot '03-script\narration-assets'
    & (Join-Path $toolsRoot 'New-NarrationAssets.ps1') `
        -PlanPath $narrationPlan `
        -OutputDirectory $narrationAssets `
        -Force | Out-Null
    $normalizedPlan = Join-Path $narrationAssets 'synthetic-pipeline-Normalized-Plan.json'

    $segmentsRoot = Join-Path $revisionRoot '03-script\segments'
    New-Item -ItemType Directory -Path $segmentsRoot -Force | Out-Null
    foreach ($segment in @(
        @{ Id = 1; Frequency = 440 },
        @{ Id = 2; Frequency = 550 },
        @{ Id = 3; Frequency = 660 }
    )) {
        Invoke-VideoCommand -FilePath $ffmpeg -Operation "creating narration segment $($segment.Id)" -Arguments @(
            '-hide_banner',
            '-loglevel', 'error',
            '-y',
            '-f', 'lavfi',
            '-i', "sine=frequency=$($segment.Frequency):sample_rate=24000:duration=0.6",
            '-c:a', 'pcm_s16le',
            (Join-Path $segmentsRoot ('segment-{0:D2}.wav' -f $segment.Id))
        )
    }

    $finalVideo = Join-Path $revisionRoot '04-final\synthetic-narrated.mp4'
    & (Join-Path $toolsRoot 'Mix-VideoNarration.ps1') `
        -PlanPath $normalizedPlan `
        -SegmentsDirectory $segmentsRoot `
        -SourceVideo $timelineVideo `
        -OutputPath $finalVideo `
        -Force | Out-Null

    $qcManifest = Join-Path $revisionRoot '05-qc\deliverable-qc.json'
    $contactSheet = Join-Path $revisionRoot '05-qc\contact-sheet.png'
    & (Join-Path $toolsRoot 'Test-VideoDeliverable.ps1') `
        -VideoPath $finalVideo `
        -ExpectedDurationSeconds 6.0 `
        -ExpectedWidth 640 `
        -ExpectedHeight 360 `
        -ExpectedFrameRate 30 `
        -RequireAudio `
        -ExpectedAudioSampleRate 48000 `
        -ExpectedAudioChannels 2 `
        -ExpectedIntegratedLufs -25 `
        -IntegratedLufsTolerance 2 `
        -MaximumTruePeakDbfs -1 `
        -SourceManifestPath $sourceManifest `
        -ContactSheetTimes @(0.5, 2.5, 4.5, 5.8) `
        -ContactSheetPath $contactSheet `
        -ManifestPath $qcManifest `
        -Force | Out-Null

    $qc = Get-Content -LiteralPath $qcManifest -Raw | ConvertFrom-Json
    if (-not [bool]$qc.passed) {
        throw "Synthetic pipeline QC did not pass: $qcManifest"
    }

    Write-Output 'SYNTHETIC_PIPELINE_TEST=passed'
    Write-Output "FINAL_VIDEO=$finalVideo"
    Write-Output "QC_MANIFEST=$qcManifest"
    Write-Output "CONTACT_SHEET=$contactSheet"
    Write-Output "TEST_ROOT=$testRoot"
}
finally {
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
