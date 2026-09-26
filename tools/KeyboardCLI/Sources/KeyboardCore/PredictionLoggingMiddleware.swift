import Foundation
import OpenAI

/// Observes the SDK's actual wire payloads; never records authentication headers.
struct PredictionLoggingMiddleware: OpenAIMiddleware {
  let requestID: String
  let secret: String
  func redact(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self).replacingOccurrences(of: secret, with: "[REDACTED]")
  }
  func intercept(request: URLRequest) -> URLRequest {
    SessionLog.shared.record("ai_request", ["request_id": requestID, "sdk": "MacPaw/OpenAI 0.5.1",
      "raw_body": redact(request.httpBody ?? Data())])
    return request
  }
  func intercept(response: URLResponse?, request: URLRequest, data: Data?) -> (response: URLResponse?, data: Data?) {
    SessionLog.shared.record("ai_response", ["request_id": requestID,
      "http_status": (response as? HTTPURLResponse)?.statusCode ?? 0,
      "raw_body": redact(data ?? Data())])
    return (response, data)
  }
}
