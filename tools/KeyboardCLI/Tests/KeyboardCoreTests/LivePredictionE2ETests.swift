import XCTest
@testable import KeyboardCore
@testable import SayItCLI

final class LivePredictionE2ETests: XCTestCase {
  @MainActor
  func testDanielaThroughGridAndRealAPI() async throws {
    guard ProcessInfo.processInfo.environment["RUN_LIVE_AI_TESTS"] == "1" else {
      throw XCTSkip("Set RUN_LIVE_AI_TESTS=1 to call the real API using .env.")
    }
    let settings = CLI.settings()
    let key = try XCTUnwrap(settings["OPENAI_API_KEY"], "Provide OPENAI_API_KEY or run from the package with .env.")
    let app = GridApp(predictor: Predictor(key: key, model: "gpt-6-luna"), autoAI: false, model: "gpt-6-luna")
    app.renderEnabled = false
    SessionLog.shared.record("e2e_start", ["scenario": "Daniela", "real_api": true])
    defer { app.task?.cancel(); app.cancelPrefetch(); SessionLog.shared.record("e2e_end", app.state()) }

    // The real grid handler: 1 opens ABCD; 4 chooses D.
    for key in "14" { app.handle(String(key)) }
    XCTAssertEqual(app.draft.prefix, "d")
    // The same Menu -> Predict path the user can invoke.
    app.handle("m"); app.handle("1")
    await app.task?.value
    XCTAssertFalse(app.words.isEmpty, "D predictions never reached the grid: \(app.status)")
    print("Live D suggestions: \(app.words)")

    // A: 1,1. N: 4,1. I: 3,1. E: 2,1. L: 3,4.
    for key in "1141312134" { app.handle(String(key)) }
    XCTAssertEqual(app.draft.prefix, "daniel")
    // Opening ABCD requests the next letter A/B/C/D after daniel.
    app.handle("1")
    app.handle("m"); app.handle("1")
    await app.task?.value
    print("Live DANIEL + ABCD suggestions: \(app.words)")
    let index = try XCTUnwrap(app.words.firstIndex { $0.lowercased() == "daniela" },
      "Expected Daniela for prefix daniel + ABCD. Got \(app.words); \(app.status)")
    XCTAssertLessThan(index, 3)
    app.handle(String(index + 7))
    XCTAssertEqual(app.draft.prefix.lowercased(), "daniela")
    XCTAssertEqual(app.draft.text, "")
    app.handle("0")
    XCTAssertEqual(app.draft.text.lowercased(), "daniela")
    XCTAssertEqual(app.draft.prefix, "")
    XCTAssertNil(app.draft.pendingGroup)
  }
}
