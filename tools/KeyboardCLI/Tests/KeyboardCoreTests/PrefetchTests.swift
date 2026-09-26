import XCTest
@testable import KeyboardCore
@testable import SayItCLI

final class PrefetchTests: XCTestCase {
  @MainActor func testLetterSuggestionAndSpaceDestinations() throws {
    let app = GridApp(predictor: Predictor(key: "", model: "gpt-6-luna"), autoAI: true, model: "gpt-6-luna")
    app.renderEnabled = false
    defer { app.cancelPrefetch() }
    try app.draft.accept("Dan")
    try app.draft.open(3)
    app.words = ["Daniela"]
    app.prepareCache()
    let planned = Set(app.pendingPredictions + Array(app.predictionTasks.keys))
    XCTAssertTrue(planned.contains(.init(text: "", prefix: "Dani", bucket: 0)))
    XCTAssertTrue(planned.contains(.init(text: "", prefix: "Dan5", bucket: 0)))
    XCTAssertTrue(planned.contains(.init(text: "", prefix: "Daniela", bucket: 0)))
    for bucket in 0...6 {
      XCTAssertTrue(planned.contains(.init(text: "Daniela", prefix: "", bucket: bucket)))
    }
    XCTAssertLessThanOrEqual(app.predictionTasks.count, 8)
  }

  @MainActor func testDeleteRestoresCachedStateAndSpaceUsesCommittedContext() throws {
    let app = GridApp(predictor: Predictor(key: "", model: "gpt-6-luna"), autoAI: true, model: "gpt-6-luna")
    app.renderEnabled = false
    defer { app.cancelPrefetch() }
    try app.draft.accept("hello")
    try app.draft.finish()
    try app.draft.accept("Dan")
    let previous = GridApp.PredictionKey(text: "hello", prefix: "Da", bucket: 0)
    app.cache[previous] = ["Daniela", "David"]
    app.handle("u")
    XCTAssertEqual(app.words, ["Daniela", "David"])
    XCTAssertNil(app.predictionTasks[previous])
    let nextWord = GridApp.PredictionKey(text: "hello Daniela", prefix: "", bucket: 0)
    app.cache[nextWord] = ["please"]
    app.handle("7")
    XCTAssertEqual(app.draft.prefix, "Daniela")
    app.handle(" ")
    XCTAssertEqual(app.words, ["please"])
    XCTAssertEqual(app.cache[previous], ["Daniela", "David"])
  }
}
