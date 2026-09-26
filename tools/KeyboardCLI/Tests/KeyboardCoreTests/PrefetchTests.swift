import XCTest
import KeyboardCore
@testable import SayItCLI

final class PrefetchTests: XCTestCase {
  @MainActor func testDeleteAndSpaceRestoreSharedCache() throws {
    let app = GridApp(predictor: Predictor(key: "", model: "gpt-6-luna"), autoAI: true, model: "gpt-6-luna")
    app.renderEnabled = false
    defer { app.cancelPrefetch() }
    try app.draft.accept("hello"); try app.draft.finish(); try app.draft.accept("Dan")
    app.predictionEngine.store(["Daniela", "David"], for: .init(text: "hello", prefix: "Da"))
    app.handle("u")
    XCTAssertEqual(app.words, ["Daniela", "David"])
    app.predictionEngine.store(["please"], for: .init(text: "hello Daniela", prefix: ""))
    app.handle("7")
    XCTAssertEqual(app.draft.prefix, "Daniela")
    app.handle(" ")
    XCTAssertEqual(app.words, ["please"])
  }
}
