# IrisGaze

Eye/head-gaze typing on iPhone Duo (SwiftUI, iOS 27.1). In the simulator the gaze comes from the Mac webcam.

## Run

```sh
# 1. Mac webcam gaze server (ws://127.0.0.1:8777)
cd gaze/mac && uv run --python 3.12 gaze_server.py            # --show for a debug window

# 2. App (from gaze/)
DUO=AD775DC3-2265-4E6F-B044-05A7BE06FAC8
xcodegen -q
xcodebuild -scheme IrisGaze -destination "id=$DUO" -derivedDataPath build -quiet build
xcrun simctl install $DUO build/Build/Products/Debug-iphonesimulator/IrisGaze.app
xcrun simctl launch --terminate-running-process $DUO dev.julian.irisgaze -backend mac -pose flat -demo YES
```

Screenshots of the inner display: `xcrun simctl io $DUO screenshot --display 94096D3B-2EC2-420D-8B65-A8AB29802B36 out.png`

## Launch flags

| flag | values | default |
|---|---|---|
| `-backend` | `mac` (webcam server), `sim` (finger / tour), `device` | `mac` if it connects within 2 s, else `sim` |
| `-demo` | `YES` clean patient UI, `NO` developer UI | `YES` with the Mac backend |
| `-pose` | `flat` (text top 25 %, keyboard 75 %), `laptop`, `book` | `flat` (real fold regions win unless `flat` is forced) |
| `-dwell` | seconds to select | `1.5` |
| `-intent` | intent server URL, or `off` | `ws://127.0.0.1:8765` |
| `-model` | `hybrid`, `auto` (CV picks), or a family name | `hybrid` |
| `-calPasses` | `1` or `2` | `1` |
| `-corners` | `NO` skips the 4 corner targets | `YES` |
| `-forceScreen` | `grid`, `calibration`, `idle` (ignore the hinge) | – |
| `-tour` / `-autoCalibrate` | `YES`: hands-free demo with the sim backend | – |
| `-speakTest` | text: type it and speak it at launch | – |

## Word suggestions (intent server)

The three blue Word cells come from `SuggestionEngine`: the intent server when it is up, filled up to 3 from a
built-in prefix list. The app connects to `-intent` (default `ws://127.0.0.1:8765`), reconnects every second and
is silent when nothing is listening.

App → server, on every text change (debounced ~80 ms):

```json
{"type": "suggest", "id": 12, "keys": [], "text": "I NEED WA", "history": []}
{"type": "caption", "text": "I NEED WA", "final": false}
```

App → server, when the speaker button is tapped:

```json
{"type": "caption", "text": "I NEED WATER", "final": true}
```

Server → app:

```json
{"type": "words", "id": 12, "source": "local", "words": ["WATER", "WAIT", "WANT"], "phrases": ["I NEED WATER"]}
```

- Only the reply whose `id` equals the last sent `id` is used (stale replies are dropped). A later reply with the
  same id (e.g. `source: "model"` after `"local"`) replaces the words.
- `keys` is always `[]`: the keyboard types exact letters. `text` is the full text so far; the current partial
  word is everything after the last space.
- `words` are shown as returned (case kept). Selecting one replaces the partial word and adds a space.
- `phrases` are only logged for now.

Test stub (returns 3 uppercase words for the current prefix, prints captions):

```sh
cd gaze/mac && uv run --python 3.12 intent_stub.py            # --port 8765
```

## Calibration tools

- Every calibration writes `Documents/calib-*.jsonl` (frames + validation). `cd gaze/mac && uv run --python 3.12 replay.py`
  compares models on the newest recording (`--recompute` rebuilds features from raw landmarks).
- The fitted calibration is saved to `Documents/calibration.json` and restored at launch when the grid geometry
  matches.
