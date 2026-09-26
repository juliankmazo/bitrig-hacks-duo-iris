import Foundation
import Observation

/// A source of word suggestions for the current text.
@MainActor
protocol WordPredictor: AnyObject {
    func predict(text: String, history: [String]) async -> [String]
}

/// Instant fallback: the built-in ~200-word prefix list.
@MainActor
final class LocalPredictor: WordPredictor {
    func predict(text: String, history: [String]) async -> [String] {
        Keyboard.suggestions(for: text)
    }
}

/// The intent server (README "Shared contract"), ws://127.0.0.1:8765 by default (`-intent <url>`).
/// App -> server: {"type":"suggest","id":n,"keys":[],"text":"...","history":[]}
///                {"type":"caption","text":"...","final":bool}
/// Server -> app: {"type":"words","id":n,"source":"local"|"model","words":[...],"phrases":[...]}
/// Only the reply to the last sent id is used; silent when the server is down (auto-reconnect 1 s).
@MainActor
final class RemotePredictor: WordPredictor {
    static let defaultURL = URL(string: "ws://127.0.0.1:8765")!

    let url: URL
    private(set) var isConnected = false
    /// Called with every fresh reply (a "model" reply can arrive after the "local" one).
    var onWords: (([String]) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private var lastID = 0
    private var pending: [Int: CheckedContinuation<[String], Never>] = [:]

    init(url: URL) {
        self.url = url
    }

    private struct Reply: Decodable {
        let type: String
        let id: Int?
        let source: String?
        let words: [String]?
        let phrases: [String]?
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runConnection()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Sends `suggest`, then waits up to 250 ms for the matching reply (later replies go to `onWords`).
    func predict(text: String, history: [String]) async -> [String] {
        guard isConnected, let task else { return [] }
        lastID += 1
        let id = lastID
        send(["type": "suggest", "id": id, "keys": [], "text": text, "history": history], on: task)
        return await withCheckedContinuation { cont in
            pending[id] = cont
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                self?.resolve(id: id, words: [])
            }
        }
    }

    func caption(_ text: String, final: Bool) {
        guard isConnected, let task else { return }
        send(["type": "caption", "text": text, "final": final], on: task)
    }

    private func resolve(id: Int, words: [String]) {
        pending.removeValue(forKey: id)?.resume(returning: words)
    }

    private func send(_ object: [String: Any], on task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let s = String(data: data, encoding: .utf8) else { return }
        task.send(.string(s)) { _ in }
    }

    private func runConnection() async {
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            if isConnected { GazeModel.logger.notice("intent server disconnected") }
            isConnected = false
            for id in pending.keys { resolve(id: id, words: []) }
        }
        // A ping tells us quickly whether anything is listening.
        let alive = await withCheckedContinuation { cont in
            task.sendPing { error in cont.resume(returning: error == nil) }
        }
        guard alive else { return }
        isConnected = true
        GazeModel.logger.notice("intent server connected \(self.url.absoluteString, privacy: .public)")
        while !Task.isCancelled {
            guard let message = try? await task.receive() else { return }
            let data: Data? = switch message {
            case .string(let s): s.data(using: .utf8)
            case .data(let d): d
            @unknown default: nil
            }
            guard let data, let r = try? JSONDecoder().decode(Reply.self, from: data), r.type == "words",
                  let id = r.id, id == lastID else { continue }   // ignore stale replies
            let words = r.words ?? []
            if let phrases = r.phrases, !phrases.isEmpty {
                GazeModel.logger.notice("intent phrases (\(r.source ?? "?", privacy: .public)): \(phrases.joined(separator: " | "), privacy: .public)")
            }
            if pending[id] != nil { resolve(id: id, words: words) } else { onWords?(words) }
        }
    }
}

/// Owns the 3 suggestion slots. Debounced ~80 ms after each text change: remote words first (when the intent
/// server is up), remaining slots filled from the local list.
@Observable
@MainActor
final class SuggestionEngine {
    private(set) var suggestions: [String] = Keyboard.suggestions(for: "")
    private(set) var source = "local"

    @ObservationIgnored let local = LocalPredictor()
    @ObservationIgnored let remote: RemotePredictor?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var lastText = ""

    init() {
        let flag = UserDefaults.standard.string(forKey: "intent")
        if flag == "off" {
            remote = nil
        } else {
            remote = RemotePredictor(url: flag.flatMap(URL.init(string:)) ?? RemotePredictor.defaultURL)
        }
        remote?.onWords = { [weak self] words in
            guard let self else { return }
            Task { await self.apply(remote: words, text: self.lastText) }
        }
        remote?.start()
    }

    func textChanged(_ text: String) {
        lastText = text
        remote?.caption(text, final: false)
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            let words = await self.remote?.predict(text: text, history: []) ?? []
            guard !Task.isCancelled, text == self.lastText else { return }
            await self.apply(remote: words, text: text)
        }
    }

    func spoke(_ text: String) {
        remote?.caption(text, final: true)
    }

    private func apply(remote words: [String], text: String) async {
        var out: [String] = []
        for w in words where !w.isEmpty && !out.contains(where: { $0.lowercased() == w.lowercased() }) && out.count < 3 {
            out.append(w)
        }
        let fallback = await local.predict(text: text, history: [])
        for w in fallback where out.count < 3 && !out.contains(where: { $0.lowercased() == w.lowercased() }) {
            out.append(w)
        }
        source = words.isEmpty ? "local" : "remote"
        if out != suggestions {
            suggestions = out
            GazeModel.logger.notice("suggestions (\(self.source, privacy: .public)) for '\(text, privacy: .public)': \(out.joined(separator: ", "), privacy: .public)")
        }
    }
}
