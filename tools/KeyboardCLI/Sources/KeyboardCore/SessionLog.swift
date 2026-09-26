import Foundation
import Darwin

/// JSON Lines across launches. O_APPEND + flock keep concurrent sessions intact.
public final class SessionLog: @unchecked Sendable {
  public static let shared = SessionLog()
  public let sessionID = UUID().uuidString
  public let path: String
  private let lock = NSLock()
  private let descriptor: Int32
  private var sequence = 0

  private init() {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let directory = package.appendingPathComponent("logs")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    path = directory.appendingPathComponent("sessions.jsonl").path
    descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o600))
    if descriptor < 0 {
      FileHandle.standardError.write(Data("Warning: session log could not be opened at \(path)\n".utf8))
    }
  }

  public func record(_ event: String, _ fields: [String: Any] = [:]) {
    lock.lock(); defer { lock.unlock() }
    guard descriptor >= 0 else { return }
    sequence += 1
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let entry: [String: Any] = ["timestamp": formatter.string(from: Date()),
      "session": sessionID, "pid": ProcessInfo.processInfo.processIdentifier,
      "sequence": sequence, "event": event, "data": fields]
    if event == "ai_request" || event == "ai_response" || event == "ai_error" {
      saveAPIFile(event: event, fields: fields, entry: entry)
    }
    guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
    data.append(10)
    guard flock(descriptor, LOCK_EX) == 0 else { return }
    defer { flock(descriptor, LOCK_UN) }
    data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { break }
        offset += written
      }
    }
  }

  private func saveAPIFile(event: String, fields: [String: Any], entry: [String: Any]) {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
      .appendingPathComponent(sessionID).appendingPathComponent("requests")
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      var details = fields
      if let raw = details.removeValue(forKey: "raw_body") as? String {
        if let body = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) {
          details["body"] = body
          if let object = body as? [String: Any], let input = object["input"] as? String,
             let parsed = try? JSONSerialization.jsonObject(with: Data(input.utf8)) {
            details["parsed_input"] = parsed
          }
        } else { details["raw_body"] = raw }
      }
      var artifact = entry
      artifact["data"] = details
      let requestID = fields["request_id"] as? String ?? "unknown"
      let file = directory.appendingPathComponent("\(requestID).\(event).\(sequence).json")
      let data = try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: file, options: .withoutOverwriting)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    } catch {
      FileHandle.standardError.write(Data("Could not save API JSON log: \(error.localizedDescription)\n".utf8))
    }
  }
  deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
}
