import XCTest
import KeyboardCore
@testable import IrisGaze

@MainActor final class PredictionIntegrationTests: XCTestCase {
    func testDanielaStaysEditableUntilSpaceAndDeleteReopensIt() {
        let engine = PredictionEngine { _ in throw CancellationError() }
        let model = GazeModel(predictionEngine: engine)
        defer { model.pausePredictions() }
        engine.store(["Daniela"], for: .init(text: "", prefix: "d"))
        engine.store(["please"], for: .init(text: "Daniela", prefix: ""))
        model.resumePredictions()
        model.select(0) // ABCD
        model.select(4) // D in the second row, leaving the right column for AI
        XCTAssertEqual(model.text, "d")
        XCTAssertEqual(model.suggestions, ["Daniela"])
        model.select(3) // First suggestion
        XCTAssertEqual(model.text, "Daniela")
        XCTAssertEqual(engine.active, .init(text: "", prefix: "Daniela"))
        model.select(8) // Space
        XCTAssertEqual(model.text, "Daniela ")
        XCTAssertEqual(model.suggestions, ["please"])
        model.select(9) // Delete the boundary
        XCTAssertEqual(model.text, "Daniela")
        XCTAssertEqual(engine.active, .init(text: "", prefix: "Daniela"))
    }

    func testOpenGroupKeepsSuggestionsAndBackDoesNotType() {
        let engine = PredictionEngine { _ in throw CancellationError() }
        let model = GazeModel(predictionEngine: engine)
        defer { model.pausePredictions() }
        engine.store(["Daniela"], for: .init(text: "", prefix: "", group: 1))
        model.resumePredictions()
        model.select(0)
        XCTAssertEqual(model.level2Group, 0)
        XCTAssertTrue(model.isSelectable(3))
        XCTAssertEqual(model.suggestions, ["Daniela"])
        model.select(10) // Back, no letter
        XCTAssertNil(model.level2Group)
        XCTAssertEqual(model.text, "")
        model.select(0)
        model.select(3) // Accept from the group screen
        XCTAssertEqual(model.text, "Daniela")
        XCTAssertNil(model.level2Group)
    }

    func testEveryGroupReservesRightColumnAndQIsSeparate() {
        for cell in Keyboard.groupCells {
            let keys = Keyboard.keys(forGroup: cell)
            XCTAssertTrue(keys.allSatisfy { Set($0.cells).isDisjoint(with: Keyboard.suggestionCells) })
            XCTAssertEqual(keys.first { $0.kind == .back }?.cells, [10])
            XCTAssertEqual(keys.first { $0.kind == .delete }?.cells, [9])
        }
        XCTAssertEqual(Keyboard.key(at: 4, group: 4)?.label, "Q")
    }
}
