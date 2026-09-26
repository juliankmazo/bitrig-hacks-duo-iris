import XCTest
@testable import KeyboardCore
@testable import SayItCLI

final class WordBoundaryTests: XCTestCase {
  @MainActor func testFragmentSuggestionContinuesUntilSpace() throws {
    let app = GridApp(predictor: Predictor(key: "", model: "gpt-6-luna"), autoAI: false, model: "gpt-6-luna")
    app.renderEnabled = false
    for key in "141" { app.handle(String(key)) }
    // Reproduce the screenshot's AI fragment and acceptance: 1 4 1 7 4.
    app.words = ["da"]
    app.handle("7"); app.handle("4")
    XCTAssertEqual(app.draft.text, "")
    XCTAssertEqual(app.draft.prefix, "da")
    XCTAssertEqual(app.draft.pendingGroup, 4)
    app.handle("1") // N
    XCTAssertEqual(app.draft.prefix, "dan")
    app.words = ["Daniela"]
    app.handle("7")
    XCTAssertEqual(app.draft.prefix, "Daniela")
    XCTAssertEqual(app.draft.text, "")
    app.handle(" ")
    XCTAssertEqual(app.draft.text, "Daniela")
    XCTAssertEqual(app.draft.prefix, "")
    app.handle("u")
    XCTAssertEqual(app.draft.text, "")
    XCTAssertEqual(app.draft.prefix, "Daniela")
    app.handle("0")
    app.handle("1")
    XCTAssertEqual(app.draft.text, "Daniela")
    XCTAssertEqual(app.draft.prefix, "")
    XCTAssertEqual(app.draft.pendingGroup, 1)
  }
}
