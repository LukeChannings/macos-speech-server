# Plan: shave the fixed ~1.6 s per-request latency floor in `speechsynthesis`

Status: **implemented**. Step 1 (breakdown measurement) done; steps 2 + 3
shipped together as the `speech-synthesis-helper` persistent renderer (the
helper pre-warms its channel at startup, so step 2 came for free). Measured
end-to-end over HTTP on the M1 Max dev machine, short utterance, warm:
**0.19 s time-to-first-audio** (was ~1.0 s via `say`; target was < 0.5 s).
After a cancelled request the next one pays ~0.33 s (fresh channel after
`DisposeSpeechChannel`), then back to ~0.2 s.

Implementation deltas from the sketch below, discovered empirically:

- SSM has **no audio callback and cannot stream to a pipe**
  (`kSpeechOutputToFileDescriptorProperty` accepts a pipe fd but writes zero
  bytes and degrades synthesis to realtime). The helper renders to a temp
  AIFF per request — SSM writes it progressively (~25 ms cadence, ~5×
  realtime) — and tails it in-process. Payload is 16-bit big-endian; the
  helper byteswaps.
- `StopSpeech` / `StopSpeechAt(kImmediate)` return `noErr` but are **ignored
  for render-to-file synthesis**; cancellation works by
  `DisposeSpeechChannel` mid-render (safe, verified) + lazy channel
  recreation.
- Voice selection was scoped to the System Voice only (the channel default);
  named/identifier voices keep the `say` path, which also remains the
  automatic fallback whenever the helper is missing, busy, crashed, or its
  output rate doesn't match the configured `sample_rate`.
- The custom stdin/stdout protocol replaced the VoiceSpec/ExtAudioFile ideas
  below; see AGENTS.md → "speech-synthesis-helper" for the shipped design.

Originally a follow-up to the real-time streaming change, PR #1.

## Context

PR #1 made the `speechsynthesis` engine stream in real time by tailing `say`'s
growing WAV output. Synthesis throughput is no longer the bottleneck — the
dominant remaining latency is a **fixed per-request floor** before the first
audio byte reaches the client.

## Measurements (Wyoming, System Voice = Siri natural voice)

Short utterance ("The kitchen lights are now on.", 1.39 s of audio), fully
warm server:

| machine | time to first audio chunk |
|---|---|
| M1 Max (local dev) | ~1.0 s |
| snowman (deployed, slower hardware) | 1.60–1.67 s, very consistent |

Key facts established during testing:

- The floor is identical for short and long inputs (long-passage warm runs on
  snowman: first chunk ~1.95 s).
- It persists after many consecutive requests, so it is **per-`say`-invocation
  cost**, not OS cache warm-up: process spawn + Siri neural voice-model load +
  first AudioFile flush (`say` writes its first bytes ~0.5–0.75 s in even on a
  fast machine).
- Cold first request on snowman was 3.55 s (one-off model/page-cache warm-up
  on top of the floor).
- Network is negligible (2.5 ms RTT). Streaming itself is healthy: once the
  first chunk lands, the playback buffer never underruns (synthesis runs
  2.2–4.4× realtime depending on hardware).

## Step 1 — measure the breakdown ✅ DONE

### Method

Two probes, all runs warm (a discarded warm-up run per voice first), medians
reported:

1. **Direct `say`** on the M1 Max dev machine: spawn
   `say --file-format=WAVE --data-format=LEI16@22050 -o <tmp>` with
   "The kitchen lights are now on." on stdin, poll the output file every
   5 ms, record time to file-creation, to first payload byte (> offset 4096),
   and to process exit. 5 trials per voice. Empty-input runs (`say` exits 0
   with a 4096-byte header-only file, no synthesis) isolate the
   voice-independent process + AudioFile setup cost.
2. **End-to-end Wyoming** against snowman (deployed streaming build), same
   short utterance, `synthesize` with explicit `voice: {name: ...}`,
   4 trials per voice.

### Results — direct `say`, M1 Max

| run | file created | first audio byte | exit |
|---|---|---|---|
| System Voice (Siri), empty input | 0.43 s | — (no synthesis) | 0.43 s |
| Albert (compact), empty input | 0.41 s | — (no synthesis) | 0.41 s |
| System Voice (Siri) | 0.42 s | **0.86 s** | 1.14 s |
| Albert (compact) | 0.40 s | **0.59 s** | 0.66 s |
| Daniel (compact en-GB) | 0.62 s | **1.08 s** | 1.14 s |

### Results — Wyoming end-to-end, snowman (warm, time to first audio chunk)

| voice | trials | floor |
|---|---|---|
| Albert (compact) | 1.21 / 1.07 / 1.08 / 1.17 s | **~1.1 s**, very consistent |
| System Voice (Siri) | 1.88 / 1.53 / 1.58 / 2.55 s | **~1.6 s** (one outlier) |
| Daniel (compact en-GB) | 1.24 / 4.98 / 2.25 / 1.78 s | noisy — model apparently re-paged between runs |

### Findings

1. **Voice-independent `say` process + AudioFile setup ≈ 0.42 s on M1 Max**
   (empty-input runs: identical for Siri and compact voices — the voice model
   is not even loaded when there is nothing to synthesise). Extrapolated to
   snowman: ~0.8–0.9 s (its Albert floor of ~1.1 s minus the ~0.2 s
   voice-dependent part scaled).
2. **Voice-dependent first-buffer cost on top**: +0.17 s (Albert), +0.44 s
   (Siri System Voice), +0.66 s (Daniel) on M1 Max. This per-invocation cost
   persists across back-to-back runs — whatever model caching
   `speechsynthesisd` / the Siri TTS service does, each `say` invocation
   still pays it.
3. **Neither decision-rule extreme holds** — the answer is "both":
   spawn/AudioFile setup is roughly half to two-thirds of the floor, the
   voice-dependent part the rest. Engine plumbing (50 ms tail poll + server
   overhead) adds only ~0.1–0.2 s (local direct 0.86 s vs local HTTP 1.06 s).

### Decision

- **Step 2 (pre-warm) is demoted**: it can only shave the *cold* first
  request (3.55 s → warm floor). Both warm-floor components are
  per-invocation, so pre-warming cannot touch them. Still worth the few
  lines, but it will not approach the < 0.5 s target.
- **Step 3 (persistent renderer) is the only route to the target**: it
  eliminates the ~0.4–0.9 s spawn/AudioFile cost *and* the per-invocation
  voice first-buffer cost (the channel keeps the voice loaded). Expected
  warm floor after step 3: low hundreds of ms (first synthesis buffer +
  streaming latency only). Proceed with step 3.
- Bonus observation: Daniel's noisy floor on snowman (1.2–5.0 s) shows
  per-invocation model re-paging under memory pressure — a persistent
  channel also fixes this variance.

## Step 2 — cheap win: pre-warm at startup (cold-start fix only)

Fire one throwaway synthesis (e.g. a single word to a temp file, discarded)
when `SpeechSynthesisTTSService` initialises. This collapses the cold
first-request cost (3.55 s observed) down to the warm floor. **Step 1
confirmed it does nothing about the warm floor itself** — both floor
components are per-invocation — but it is a few lines and removes the worst
observed case.

Implementation sketch:

- In `init` (or a lazy one-shot on first `synthesizeStream` call, to avoid
  slowing server startup), spawn `say --file-format=WAVE ... -o <tmp>` with a
  one-word input using the configured `default_voice`, discard the output.
- Must be fire-and-forget (don't block init; don't fail init if it errors).
- Test: hard to assert timing in CI; test only that initialisation still
  succeeds and no temp files leak.

## Step 3 — big win: persistent Carbon SSM helper process

A tiny helper binary, spawned once at service init, that:

1. Pumps a `CFRunLoop` on its **main thread** and drives the Carbon Speech
   Synthesis Manager (`NewSpeechChannel` / `SpeakCFString`) with a
   **long-lived speech channel** (voice model stays loaded across requests).
2. Receives synthesis requests over stdin (length-prefixed text + voice id),
   streams raw PCM back over stdout as it renders (SSM delivers audio via a
   callback, so true pipe streaming works here — no file tailing needed).
3. Is restarted by the service if it crashes (treat a dead helper like a
   failed `say` run: throw `.sayFailed`-equivalent, respawn lazily).

Why this works when in-process Carbon doesn't: the Carbon path is **not**
signing-gated and reaches the full voice set including Siri (verified
empirically during the original engine work — see AGENTS.md,
`SpeechSynthesisTTSService` section). Its only blocker was that synthesis
completes only on a main run loop, which a Vapor server never pumps. A
dedicated helper process pumps its own main run loop — exactly the way `say`
does — while keeping the channel (and therefore the voice model) alive
between requests.

Design notes / risks:

- **Packaging**: the helper is a second executable target in `Package.swift`;
  the Homebrew formula and nix package must install it alongside
  `speech-server`, and the service needs to locate it (relative to its own
  binary path via `Bundle.main.executablePath` or a config override).
- **Voice selection**: SSM selects voices by `VoiceSpec`; mapping the engine's
  voice strings (names, identifiers, "System Voice") onto VoiceSpecs needs the
  same care as `resolveVoiceArgument`. The System Voice may need the
  Accessibility-prefs identifier lookup that already exists
  (`configuredSystemVoiceIdentifiers()`).
- **Sample rate**: SSM output format is channel-configurable
  (`SetSpeechProperty` with `kSpeechOutputToExtAudioFileProperty` /
  audio-unit routing); confirm we can get LEI16 @ configured rate or convert
  in the helper.
- **Carbon deprecation**: the SSM API is deprecated but present and
  functional through current macOS; `say` itself still works, and the
  fallback (current `say` tailing path) stays in the codebase — keep the
  helper as an optimisation layered on top, with `say` as the error path.
- **Cancellation**: same contract as today — consumer disconnect must stop
  the in-flight synthesis (SSM `StopSpeech`) without killing the helper.

TDD order: protocol framing tests for the stdin/stdout wire format (pure
functions, no process); helper integration test (spawn real helper, one
synthesis, assert PCM arrives and channel survives a second request); service
tests asserting fallback to `say` when the helper is missing/dead.

## Explicitly not worth doing

- **Tuning the 50 ms tail poll interval** — noise compared to the floor.
- **Pre-spawned `say` process pools** — `say` takes text at spawn time and
  exits after one synthesis; it cannot be parked.
- **Driving the Siri voice model files directly** — see the appendix below
  for why this was investigated and rejected.

## Appendix — anatomy of the Siri voice asset ("Voice 3" investigation)

Investigated whether a harness could be built around the Siri voice model
files directly, bypassing `say`/`sirittsd`. Conclusion: **no — go through
Apple's stack (step 3)**. Findings below (macOS 26, M1 Max dev machine).

### Where the voice lives

The System Settings Siri voice names "Voice 1"–"Voice 4" map to the
identifier suffixes A–D: the configured System Voice
`com.apple.siri.natural.en-GB-C` *is* "Voice 3" (en-GB, female, 248.7 MB
download / 236 MB installed). Its asset:

```
/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/
  purpose_auto/<sha1>.asset/AssetData/
```

Identified live: during a bare-`say` System Voice synthesis, `sirittsd`
(`SiriTTSService.framework`) holds ~24 files from exactly this asset open
(`lsof`), including the voice-specific `en-GB-C_rewrite_rule.dat`.
`Info.plist` → `MobileAssetProperties`: `Name=en-GB-C`, `Type=natural`,
`Footprint=premium`. All files world-readable. (The older
`…_VoiceServices_GryphonVoice` catalog only carries the legacy
martha/arthur premium pair; the "natural" voices live in the UAF catalog.
The built-in fallback Siri voice is
`/System/Library/Speech/Voices/ArthurSiri.SpeechVoice`, 607 MB,
tacotron/wavernn-era espresso blobs.)

### What's inside — a full pipeline, not one model

| stage | files | format |
|---|---|---|
| Text normalisation | `rewrite_rule.dat`, `tn_prefix_rule.dat`, `en-GB-C_rewrite_rule.dat` | proprietary binary |
| G2P | `g2p_seq2seq.bin` (31 MB) | proprietary binary blob |
| Phoneme symbols | `symmap.json` | readable JSON |
| Acoustic model | `p2a/` encoder+decoder (118 MB) | compiled CoreML `.mlmodelc`; decoder tagged `soundstorm`, 521-dim codes, dynamic shapes |
| Voice identity | `prompts/*.bin` (37 MB) | prompt-conditioning embeddings |
| Streaming vocoder | `anetec/` decoder (44 MB) | `.mlmodelc`; `code_chunk [2,8]` + ring-buffer state → audio |
| Orchestration | `gryphon.cfg`, `frontend.cfg`, per-model sidecar JSONs | readable JSON incl. exact tensor I/O specs; executed via a custom `mil2bnns` path |

### Why a manual harness is rejected

- **Loading** the `.mlmodelc` stages with public CoreML API would work —
  the sidecar JSONs document every tensor and `symmap.json` gives the
  phoneme inventory.
- **Driving** them end-to-end means reimplementing text normalisation, the
  G2P stage (proprietary 31 MB blob — the quality showstopper), prompt
  conditioning, the SoundStorm iterative decoding loop, and the streaming
  codec state machine. Weeks of reverse engineering, fragile across OS
  updates.
- **Legally unshippable**: Apple's licensed voice data; could never go in
  the Homebrew formula even if it worked.
- **And it wouldn't buy anything**: `sirittsd` stays resident (observed:
  3-day uptime, asset still mmapped between requests, only 23 MB RSS) — the
  voice is already "warm" in the OS. The measured +0.44 s/invocation Siri
  cost is per-session pipeline/XPC setup, not cold model load, which is
  precisely what the persistent speech channel of step 3 eliminates through
  the sanctioned path.

A private-SPI harness (talking to `sirittsd` via `SiriTTSService.framework`
directly) was also considered: likely entitlement-gated at the XPC boundary,
definitely private API, not shippable — same verdict.

## Acceptance

- ~~Breakdown measurement (step 1) documented before committing to step 3.~~
  Done — see "Step 1" above.
- Warm time-to-first-audio for a short utterance meaningfully below the
  current floor (target: < 0.5 s on M1-class hardware) **or** a documented
  decision that the floor is acceptable and why.
- No regression to the streaming properties from PR #1: cancellation kills
  the renderer, no leaked processes, even-frame chunks, playback buffer never
  underruns.
