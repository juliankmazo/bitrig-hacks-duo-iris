import XCTest
@testable import KeyboardCore

@MainActor final class PredictionEngineTests: XCTestCase {
  func testSpeculatesLettersSuggestionsAndSpace() {
    let states = PredictionEngine.destinations(for: .init(text: "hello", prefix: "Dan", group: 3), words: ["Daniela"])
    XCTAssertEqual(states.first, .init(text: "hello", prefix: "Dan", group: 3))
    XCTAssertTrue(states.contains(.init(text: "hello", prefix: "Dani")))
    XCTAssertTrue(states.contains(.init(text: "hello", prefix: "Dan5")))
    XCTAssertTrue(states.contains(.init(text: "hello", prefix: "Daniela")))
    for group in 0...6 { XCTAssertTrue(states.contains(.init(text: "hello Daniela", prefix: "", group: group))) }
    XCTAssertEqual(states.count, Set(states).count)
  }

  func testOldResponseIsCachedButCannotReplaceNewScreen() async {
    let gate = Gate()
    let engine = PredictionEngine(concurrency: 1) { state in try await gate.fetch(state) }
    defer { engine.pause(); gate.cancelAll() }
    let old = PredictionState(text: "", prefix: "d")
    let next = PredictionState(text: "", prefix: "da")
    engine.update(old)
    await waitFor { gate.requests[old] != nil }
    engine.update(next)
    gate.finish(old, ["do"])
    await waitFor { gate.requests[next] != nil }
    XCTAssertEqual(engine.snapshot.words, [])
    XCTAssertEqual(engine.cache[old], ["do"])
    gate.finish(next, ["Daniela"])
    await waitFor { engine.snapshot.words == ["Daniela"] }
    engine.update(old)
    XCTAssertEqual(engine.snapshot.words, ["do"])
    XCTAssertEqual(gate.counts[old], 1)
  }

  func testPauseDiscardsLateResultsAndConcurrencyIsBounded() async {
    let gate = Gate()
    let engine = PredictionEngine { state in try await gate.fetch(state) }
    defer { engine.pause(); gate.cancelAll() }
    engine.update(.init(text: "", prefix: "dan", group: 3))
    await waitFor { gate.requests.count == 8 }
    XCTAssertEqual(engine.tasks.count, 8)
    engine.pause()
    gate.cancelAll()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertTrue(engine.cache.isEmpty)
    XCTAssertTrue(engine.tasks.isEmpty)
  }

  func testSuggestionLabelsStayStableUntilDwellEnds() {
    var display = SuggestionDisplay()
    display.receive(["Daniela", "Daniel"])
    display.setDwelling(true)
    display.receive(["Danielle", "Danny"])
    XCTAssertEqual(display.words[0], "Daniela")
    display.setDwelling(false)
    XCTAssertEqual(display.words[0], "Danielle")
    display.setDwelling(true)
    display.receive(["stale"])
    display.reset()
    display.setDwelling(false)
    XCTAssertEqual(display.words, [])
  }

  private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<1000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Prediction task did not reach expected state")
  }
}

@MainActor private final class Gate {
  var requests: [PredictionState: CheckedContinuation<[String], Error>] = [:]
  var counts: [PredictionState: Int] = [:]
  func fetch(_ state: PredictionState) async throws -> [String] {
    counts[state, default: 0] += 1
    return try await withCheckedThrowingContinuation { requests[state] = $0 }
  }
  func finish(_ state: PredictionState, _ words: [String]) {
    requests.removeValue(forKey: state)?.resume(returning: words)
  }
  func cancelAll() {
    for request in requests.values { request.resume(throwing: CancellationError()) }
    requests = [:]
  }
}
