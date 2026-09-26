# Say It grid CLI

A standalone macOS Swift package alongside `app/bitrig/Say It`. The Xcode app is unchanged.

## Single-file Python version

```sh
cd /Users/andres/Developer/als-comms/swift-keyboard-cli/tools/KeyboardCLI
uv run --locked say_it.py --ai
```

`say_it.py` contains the complete Python application, using the official OpenAI
Python SDK and the same grid, controls, AI-only predictions, and macOS speech.
uv installs its inline dependencies; `say_it.py.lock` fixes their versions.
It reads the existing `.env` from the working directory and appends to
`logs/sessions.jsonl` beside the script (Python sessions include
`implementation: python`). `--model`, `--ask-key`, and `--help` are supported.
Without `--ai`, use Menu → Predict words for an on-demand request.
Errors and empty responses leave suggestions empty; typing never waits for AI.

## Run

```sh
cd /Users/andres/Developer/als-comms/swift-keyboard-cli/tools/KeyboardCLI
swift run say-it --ai
```

Use an interactive terminal at least 80 columns wide. Each keypress selects one cell immediately: **no Enter and no typed commands**.

```text
+------------------+------------------+------------------+------------------+
| [1] ABCD · 0 1   | [2] EFGH · 2 3   | [3] IJKLM · 4 5  | [7] Word 1       |
+------------------+------------------+------------------+------------------+
| [4] NOPQ · 6 7   | [5] RSTUV · 8 9  | [6] WXYZ · ? !   | [8] Word 2       |
+------------------+------------------+------------------+------------------+
| [0] Space        | [U] Delete       | [C] Start over   | [9] Word 3       |
+------------------+------------------+------------------+------------------+
```

1. Press `1` to open A/B/C/D. The grid changes immediately.
2. Press `3` to select C. You return to the main grid with exact prefix `c`.
3. Select another group and letter, or accept a suggested word. Follow the labels: word choices always use `7`–`9` in the rightmost column.
4. Press `B` on the letter grid to return without committing its group. `U` or Backspace cancels a pending group, deletes one character, or reopens the previous word by deleting its boundary space.
5. In the Swift CLI, press `0` or the Space bar to finish the current word. Selecting a suggestion updates the current word without adding a space; keep spelling to extend it. The unfinished word is shown with a cursor, such as `da▌`.
6. Press `M`, then `2` for full-message suggestions. `M`, then `6` speaks or stops speech in the Swift CLI (`S` also remains a shortcut). Finish the current word with Space first. Escape or Ctrl-C exits.

Letter selection remains a 4×3 grid. The rightmost column always holds suggestions on 7, 8, and 9. Group members occupy the first two rows using keys 1–6, with a seventh member (when present) on key 0. Delete and Back occupy the remaining bottom cells. The main grid has Space, Delete, and Start over across the bottom. M opens the menu and S speaks. Q and U remain separate characters; numbers and ?/! are selectable through their displayed groups.

Exact letters are sent to the model as requested constraints; the debug UI currently shows and accepts its responses without local filtering. With accepted text `hello` and pending group 1, suggestions are contextual next words starting A/B/C/D. In the Swift CLI, selecting a suggested word replaces the unfinished word. Only Space commits it and starts a new one. Delete after Space reopens that word.

## OpenAI

API calls use the community-maintained [MacPaw OpenAI Swift SDK](https://github.com/MacPaw/OpenAI), pinned to 0.5.1 with transitive versions in `Package.resolved`. The SDK handles Responses API requests, authentication, cancellation, and response decoding. Logging middleware records actual request/response bodies without authentication headers. The grid still uses GPT-6 Luna and parallel requests.

The CLI reads `OPENAI_API_KEY` and optional `OPENAI_MODEL` from the git-ignored `.env` in the current directory. Environment variables override the file. `--ask-key` optionally prompts for a temporary key without echo. `--model MODEL` overrides the default GPT-6 Luna. Luna uses `reasoning.effort: low` with no explicit output-token limit (the API default applies). The prompt explicitly specifies English.

Suggestions are AI-only: no local dictionary suggestions or dictionary hints are used. The model receives committed text including its word-boundary space, the unfinished current word, and explicit allowed text starts (for example `dan`, `dao`, `dap`, `daq`). The prompt explains that choosing suggestions replaces the unfinished word and only Space finishes it. Completion covers words, names, digits, and ?/! punctuation. The request uses `allowedStarts` and `allowedNextCharacters`. Phrase expansion has separate instructions and preserves names, numbers, and punctuation intent. Returned suggestions are shown and accepted without local word, prefix, duplicate, or phrase-length filtering. The model still receives the requested letter constraints.

Every selection redraws immediately. Cached AI suggestions appear when available; otherwise suggestion cells stay empty while requests run. The current prefix and six possible next groups are prefetched. Opening a group also prefetches each exact letter’s next screen. Visible suggestions prefetch their selected-word screen and the next-word screen after Space, including its six groups. Predictions are retained for the session, so revisiting a state with Back/Delete reuses its AI responses. Up to eight requests run concurrently; the visible state is queued first. Edits drop obsolete queued speculation, while in-flight responses can still populate the cache without changing an unrelated screen. Speculative results never recursively launch more speculation. No latency measurements are collected.

Omit `--ai` to pause automatic requests and use Menu → Predict words on demand. Failed requests leave suggestion cells empty; exact spelling remains available. The grid does not wait for the network.

## Verify

```sh
swift test
```

Run the real-API end-to-end scenario from this directory (reads `.env`):

```sh
RUN_LIVE_AI_TESTS=1 swift test --filter LivePredictionE2ETests
```

It drives the grid's actual single-key handler: `14` selects D, requests real SDK predictions, continues spelling `daniel`, selects the next-letter group ABCD, requests predictions again, selects Daniela as the current word, and presses Space to commit it into the draft. Terminal drawing is suppressed in this test. This is a live model test and its suggestions can vary. A separate recorded-response regression covers SDK output extraction. Suggestions remain unfiltered.

Core tests cover group mapping, prefix matching, invalid selections, undo, exact spelling in the core library, and model-output validation. Interactive grid behavior is checked in a terminal. The Foundation-only core can be adapted for the iOS app.

## Debug log

`logs/sessions.jsonl` is append-only across launches and git-ignored. Each event includes a session UUID, PID, timestamp, and sequence. It records session starts/exits, every keypress, rendered state, suggestion selections, cache events, full API request bodies, raw response bodies, decoded suggestions, and errors/cancellations. API keys and Authorization headers are not logged. The screen shows the log location and session ID. A forced process kill may leave a start without an end event.

Each API request, response, and error is also saved as a separate pretty-printed JSON file under `logs/<session-id>/requests/`, with matching request IDs. Request files include `parsed_input` for easy reading. Files are never overwritten; the append-only session log is retained.
