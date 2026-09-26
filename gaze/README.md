# IrisGaze with AI predictions

IrisGaze and `tools/KeyboardCLI` share `packages/KeyboardCore`: the OpenAI SDK client, English prompt, low reasoning effort, default output-token budget, prefetch queue, cache, and logging. IrisGaze has no local word suggestions.

## Try it

Generate the project with XcodeGen, then open it in the Xcode beta that includes the iOS 27.1 Duo SDK:

```sh
xcodegen generate --spec gaze/project.yml
open gaze/IrisGaze.xcodeproj
```

Run the `IrisGaze` scheme on iPhone Duo. For simulated input, add launch arguments `-backend sim -forceScreen grid`. Drag to a cell and hold for one second, or double-tap a cell. Real gaze backends still require calibration.

Set `OPENAI_API_KEY` in your local Xcode scheme environment before running. No credential is embedded in source. A distributed app should use a backend-held credential.

1. Open a letter group, then select an exact character. Q and U are separate.
2. The rightmost column always contains AI suggestions, including inside a letter group.
3. A suggestion replaces the unfinished word without adding a space. Space on the main grid finishes it. Delete removes a character or reopens the previous word by removing its boundary.
4. Back inside a group returns without typing. Delete inside a group cancels that group, matching the CLI.
5. Suggestions stay stable while you dwell on one. New results appear after you leave that selection. Empty cells cannot be selected.

Group, letter, suggestion-selection, and next-word screens are prefetched. At most eight requests run concurrently; only visible results trigger more prefetching. Cached results survive Back/Delete for the app session. Exact typing remains available while the API is loading or unavailable. Retry AI retries the visible request. Leaving the foreground cancels pending work; returning resumes predictions.

## Logs and validation

The app writes append-only `Documents/PredictionLogs/sessions.jsonl` and separate readable request/response JSON files under the session directory. They contain the typed message and AI output. The CLI writes `logs/` in its working directory. Gaze calibration recordings are separate and unchanged.

```sh
swift test --package-path packages/KeyboardCore
swift test --package-path tools/KeyboardCLI
```

The `IrisGazeTests` target checks the actual app model's suggestion acceptance, Space/Delete boundaries, group Back behavior, and fixed suggestion column. Run it from Xcode's Test action. Shared-engine tests cover out-of-order responses, cache reuse, concurrency limits, cancellation, and frozen suggestion labels. Tests inject a fake prediction transport; normal app runs use the real API.
