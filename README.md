# Iris · eye-typing for ALS on iPhone Duo (Bitrig Hacks)

Read `../CLAUDE.md` first (toolchain, simulator loop, Duo rules). This README is the product brief plus three independent build tracks. Each track owns its own folder; they only meet through the contracts below. Update the checkboxes as you go.

**The demo is recorded, not live.** Hacking ends 3:30 PM, demos 3:30–5:00.

## The idea

A person with ALS types with their eyes. The iPhone Duo stands **half-open (book pose) on a table or wheelchair tray**. The **inner screen faces the patient**. The **outer screen faces the other person** and shows live captions of what the patient is writing.

1. Inner screen: a 3×3 gaze keyboard with ambiguous letter keys (T9-style), selected by dwell (~1 s) or a long blink.
2. An intent model decodes live: likely words for the ambiguous key sequence, plus whole phrases from conversation context.
3. Outer screen: closed captions for the person facing the patient.

**Pitch facts:** 33k Americans live with ALS (CDC); 80–95% lose functional speech (ALS Association); eye-gaze devices cost $3k–15k (Tobii) plus an insurance fight. This runs on an iPhone. Acknowledge prior art, don't claim "first": Google SpeakFaster (LLM + context for ALS, Nature Comms 2024), Look to Speak, Apple Eye Tracking. What's new: an ordinary phone, large keys sized for camera gaze, and captions facing the partner on the foldable's second screen.

**Why Duo:** Apple only lets an app draw on the outer display while open through `CameraCaptureAccessory`, which requires a live camera session with a visible preview. Eye tracking *is* a camera session, so this is one of the few legitimate reasons to light up the outer screen.

## Architecture

```
Mac webcam ─> tracker/  (eye tracking) ─┐
                                        ├─ ws://127.0.0.1:8765 ─> app/ (SwiftUI, iPhone Duo simulator)
              intent/   (word + phrase  ┘            │
                         prediction)                 └─ captions ─> http://127.0.0.1:8766/outer.html
                                                                     (simulated outer display, Mac browser)
```

- The simulator has no camera, so eye tracking runs on the Mac and streams gaze zones to the app. The simulator shares the Mac's network, so `127.0.0.1` works from the app.
- API keys stay on the Mac (`../.env`, outside this repo). The app never sees them.
- The outer display can't render in the simulator (it needs a real camera). Record `outer.html` in a browser window labeled "Outer display · simulated" next to the simulator. Still write the real `CameraCaptureAccessory` code so it's correct on hardware.
- All three track folders start empty.

## Shared contract (WebSocket, JSON)

Letter groups (key index → letters): **0 ABCD · 1 EFGH · 2 IJKL · 3 MNOP · 4 QRST · 5 UVWXYZ**.

Server → app:
- `{"type":"gaze","zone":0-8|-1,"blink":bool,"face":bool}` at ~20 Hz. Zone −1 means not calibrated or unstable.
- `{"type":"cal_done","zone":k,"count":n}`
- `{"type":"words","id":n,"source":"local"|"model","words":[...],"phrases":[...]}`. Local arrives instantly, the model reply later. Ignore stale ids.
- `{"type":"caption","text":"...","final":bool}`, relayed to every client including outer.html.

App → server:
- `{"type":"cal","zone":k}`: the server samples ~24 frames while the user looks at cell k.
- `{"type":"cal_reset"}`
- `{"type":"suggest","id":n,"keys":[g...],"text":"committed text","history":["partner: ...","me: ..."]}`
- `{"type":"caption","text":"...","final":bool}`

Run:
```sh
uv run --python 3.12 tracker/server.py              # eye tracking (hybrid) + intent
uv run --python 3.12 tracker/server.py --mode head  # nose-pointer fallback
uv run --python 3.12 tracker/server.py --no-camera  # intent + relay only (app testing with taps)
open http://127.0.0.1:8766/outer.html
```

---

## Track 1 · Eye tracking (`tracker/`)

Goal: a reliable gaze zone 0–8 plus a deliberate-blink signal from the MacBook webcam, streamed to the app.

Verified on this Mac (2026-09-26):
- Webcam: 1920×1080 at 30 fps via OpenCV. The terminal already has camera permission.
- **MediaPipe must be pinned to 0.10.21 (Python 3.12).** 1.0.1 crashes ("graph_service Service is unavailable"). Use the Tasks API (`mediapipe.tasks.python.vision.FaceLandmarker`), not `mp.solutions`. Model file: download `https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task` into `tracker/`.
- The face was detected in 120/120 frames. Blendshapes `eyeLookIn/Out/Up/Down{Left,Right}` and `eyeBlink{Left,Right}` work.
- Webcam gaze is decent left/right and weak up/down (eyelids cover the iris). Hence `--mode hybrid` (eyes + head). If it jitters, `--mode head` (nose pointer) is a legitimate fallback that real AAC devices ship.

Tasks:
- [ ] WebSocket server on :8765 that streams gaze and handles `cal` / `cal_reset` / `caption`, and serves `outer.html` on :8766
- [ ] Run with the camera and confirm gaze messages stream (quick Python ws client)
- [ ] Calibration: 9 cells, nearest-centroid classification; test by looking at the 9 regions of the simulator window
- [ ] Tune smoothing (EMA 0.4, 3-frame hysteresis), hybrid vs head, and feature weights; target: can hold each of the 9 zones for 1 s
- [ ] Blink select: both eyes closed > 0.45 s, no false fires from natural blinks
- [ ] Optional: a small debug window (OpenCV) showing the face, the current zone and the confidence, for recording B-roll

## Track 2 · Intent model (`intent/`)

Goal: given the ambiguous key sequence, the committed text and the conversation so far, return the best word candidates and whole-phrase suggestions, fast. **Any model type is fair game.** Pick by measured quality and latency, not by name.

Candidates to evaluate:
- **Local T9 dictionary** (e.g. `https://raw.githubusercontent.com/first20hours/google-10000-english/master/google-10000-english-usa-no-swears.txt`, 10k words by frequency): instant baseline, always on.
- **Hosted LLMs:** `gpt-5.4-nano`, `gpt-5.4-mini`, `gpt-4.1-nano` (all available on the OpenAI key); Claude Haiku 4.5 if a key is available. Structured output (JSON schema), reasoning off, static system prompt first for caching.
- **On-device:** Apple Foundation Models works in the simulator only if the Mac has Apple Intelligence on and a macOS at least as new as the simulator. Check `SystemLanguageModel.default.availability`. Good "private / offline" story.
- **Non-LLM:** an n-gram or small language model over the dictionary for word ranking by context; abbreviation expansion (SpeakFaster-style).

Tasks:
- [ ] Build an eval harness: ~30 realistic ALS-conversation sentences ("I'm cold, can you close the window", "my back hurts", "I love you"). For each, simulate typing: at every keystroke, send the key sequence + context and record whether the target word is in the top 1/3/5, and whether a phrase suggestion matches. Report **keystroke savings** and **p50/p95 latency** per model.
- [ ] Compare the candidates above; pick the default and a fallback
- [ ] Prompt: first person, casual, ≤ 8 words per phrase, use the partner's last message as context. Validate that returned words match the key sequence; drop the ones that don't.
- [ ] Ship it as `intent/predict.py` with `async predict(keys, text, history) -> {words, phrases}`, which the tracker's server imports to answer `suggest`
- [ ] Target: first model reply < 700 ms p50; local words always instant

## Track 3 · App (`app/`)

Goal: the SwiftUI iPhone Duo app. Create the project in `app/` with xcodegen (see `../CLAUDE.md` for `project.yml` and the build/run loop).

Inner-screen layout: a full-screen 3×3 grid. Big targets; calibration maps the 9 centroids to these cells.

```
 cell0 ABCD   | cell1 EFGH   | cell2 IJKL
 cell3 MNOP   | cell4 CENTER | cell5 QRST
 cell6 UVWXYZ | cell7 ␣ word | cell8 ⌫
```
- Cell 4 (center) is a **rest zone**: no dwell action. It shows the sentence so far and the current top candidate. A long dwell (~2 s) on the center opens **suggestions mode**: the 8 outer cells show model words/phrases, and the center means back.
- Cell 7 accepts the top candidate plus a space. Cell 8 deletes the last key (or the last word if no keys are pending).
- Dwell: the zone stays stable for 1.0 s → select, with a progress ring; 0.8 s cooldown. A long blink selects the current zone. Taps on cells also work (for testing without the tracker).
- A small camera tile (on device: the eye-tracking preview, required for `CameraCaptureAccessory`; in the sim: a placeholder with tracker status, face ✓, calibrated n/9).
- Every change sends `caption` (`final:false` while typing, `final:true` when spoken).

Hinge moments (Duo APIs, all demoable in the sim):
- **Book / partially open** → conversation mode (keyboard + captions). Enable `CameraCaptureAccessory` here.
- **Fully open** → setup: calibration screen (9 dots, one at a time, sending `cal` per cell).
- **Closed** → the app is on the outer display: speak the sentence (AVSpeechSynthesizer) and show it large. "Close to speak."
- Keep key labels off the crease (`reservedRegions(.division)`).

Tasks:
- [ ] Project skeleton in `app/` (iOS 27.1), `NSAllowsLocalNetworking` in Info.plist
- [ ] `TrackerClient`: `URLSessionWebSocketTask` to ws://127.0.0.1:8765, auto-reconnect, decode on the main actor
- [ ] Typing model: key sequence, committed text, candidates, phrases, history; send `suggest` and `caption` on every change
- [ ] 3×3 grid + dwell ring + gaze-zone highlight + tap fallback
- [ ] Suggestions mode
- [ ] Calibration screen (fully open)
- [ ] Hinge: `onHingeChange` → mode switching; closed → speak + large text on the outer display
- [ ] `CameraCaptureAccessory` with a `CaptionView` (real code, unavailable in the sim) + camera tile placeholder
- [ ] Polish: typography, colors, motion, app name and icon

---

## Demo (after the tracks come together)

- [ ] Script, 90 s: the problem → the patient's view → the partner's view (outer.html) → the model completes a phrase → close to speak → why Duo → the business line
- [ ] Record the Duo simulator (Device Hub) and the outer.html window side by side, with an optional webcam picture-in-picture of the "patient"
- [ ] Record a backup take
