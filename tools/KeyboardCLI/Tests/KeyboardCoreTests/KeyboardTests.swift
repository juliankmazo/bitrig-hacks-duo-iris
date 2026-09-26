import XCTest
@testable import KeyboardCore
final class KeyboardTests: XCTestCase {
  func testTwoStepSpellingAndBack() throws {
    var draft = SpellingDraft()
    try draft.open(1); draft.back()
    XCTAssertEqual(draft.prefix, ""); XCTAssertEqual(draft.keys, "")
    try draft.open(1); try draft.choose(2)
    XCTAssertEqual(draft.prefix, "c"); XCTAssertNil(draft.pendingGroup)
    try draft.open(3)
    try draft.accept("close"); XCTAssertEqual(draft.prefix, "close"); XCTAssertEqual(draft.text, "")
    draft.undo(); XCTAssertEqual(draft.prefix, "c"); XCTAssertEqual(draft.text, "")
    try draft.open(3); try draft.choose(4)
    XCTAssertEqual(draft.prefix, "cm")
    try draft.finish(); XCTAssertEqual(draft.text, "cm")
  }
  func testPrefetchRespectsExactPrefixAndNextGroup() {
    let branches = Predictor.validatedBranches(["1": ["can", "call", "are", "close"], "3": ["close", "clay", "can"]], prefix: "c")
    XCTAssertEqual(branches["1"], ["can", "call"])
    XCTAssertEqual(branches["3"], ["close", "clay"])
    let next = Predictor.validatedBranches(["1": ["can", "are", "water"]], prefix: "")
    XCTAssertEqual(next["1"], ["can", "are"])
  }
  func testImageMappingAndPrefix() {
    XCTAssertEqual(Keyboard.signature("WATER"), "61525")
    XCTAssertEqual(Keyboard.signature("qu"), "45")
    XCTAssertEqual(Keyboard.signature("I'm"), "33")
    XCTAssertEqual(Keyboard.filter(["water", "watch", "wave", "coffee", "WATER"], keys: "615"), ["water", "watch", "wave"])
    XCTAssertNil(Keyboard.signature("two words"))
  }
  func testUndoAndValidation() throws {
    var draft = Draft()
    try draft.append("61525")
    XCTAssertThrowsError(try draft.accept("coffee"))
    try draft.accept("water")
    XCTAssertEqual(draft.text, "water")
    draft.undo(); XCTAssertEqual(draft.keys, "61525"); XCTAssertEqual(draft.text, "")
    draft.undo(); XCTAssertEqual(draft.keys, "6152")
    XCTAssertThrowsError(try draft.append("70")); XCTAssertEqual(draft.keys, "6152")
    try draft.spell("Andres"); XCTAssertEqual(draft.text, "Andres"); XCTAssertEqual(draft.keys, "")
    draft.clear(); draft.undo(); XCTAssertEqual(draft.text, "Andres")
  }
  func testUntrustedModelOutput() throws {
    let payload = #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"words\":[\"coffee\",\"water\",\"WATER\",\"watch\"],\"phrases\":[\"Water, please.\"]}"}]}]}"#
    let result = try Predictor.decode(Data(payload.utf8), keys: "615", expand: false)
    XCTAssertEqual(result.words, ["coffee", "water", "WATER", "watch"]); XCTAssertEqual(result.phrases, ["Water, please."])
    XCTAssertThrowsError(try Predictor.decode(Data(#"{"status":"incomplete","output":[]}"#.utf8), keys: "6", expand: true))
    let expanded = try Predictor.decode(Data(payload.utf8), keys: "615", expand: true)
    XCTAssertEqual(expanded.phrases, ["Water, please."])
  }
}
