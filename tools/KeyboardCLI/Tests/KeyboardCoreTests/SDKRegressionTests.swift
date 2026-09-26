import XCTest
import OpenAI
@testable import KeyboardCore

final class SDKRegressionTests: XCTestCase {
  func testLoggedDResponseDecodesThroughSDK() throws {
    let url = Bundle.module.url(forResource: "d-response", withExtension: "json", subdirectory: "Fixtures")!
    let data = try Data(contentsOf: url)
    do { let response = try JSONDecoder().decode(ResponseObject.self, from: data)
      let predictions = try Predictor.decodeSDK(response)
      XCTAssertEqual(predictions.words, ["do", "did", "does"]) }
    catch { XCTFail("SDK response decode failure: \(String(reflecting: error))") }
  }
}
