import Foundation

/// Writes calibration / validation frames as JSONL to the app's Documents directory,
/// for offline replay with `gaze/mac/replay.py`.
final class SessionRecorder {
    let url: URL
    private let handle: FileHandle?

    init?() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .dateSeparator(.dash).timeSeparator(.omitted).dateTimeSeparator(.standard))
        url = docs.appending(path: "calib-\(stamp).jsonl")
        FileManager.default.createFile(atPath: url.path(), contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    func write(_ object: [String: Any]) {
        guard let handle, JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        handle.write(data)
    }

    func close() {
        try? handle?.close()
    }
}
