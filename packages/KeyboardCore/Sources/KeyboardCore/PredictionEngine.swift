import Foundation

/// Exact input state shared by the terminal and gaze interfaces. Group 0 means
/// no pending character group; 1...6 use Keyboard.groups.
public struct PredictionState: Hashable, Sendable {
  public let text: String
  public let prefix: String
  public let group: Int
  public init(text: String, prefix: String, group: Int = 0) {
    self.text = text; self.prefix = prefix; self.group = group
  }
}

@MainActor public final class PredictionEngine {
  public struct Snapshot: Sendable {
    public let words: [String]
    public let status: String
  }
  public typealias Fetch = @Sendable (PredictionState) async throws -> [String]
  public var onChange: ((Snapshot) -> Void)?
  public private(set) var active: PredictionState?
  public private(set) var snapshot = Snapshot(words: [], status: "AI paused")
  private(set) var cache: [PredictionState: [String]] = [:]
  private(set) var pending: [PredictionState] = []
  private(set) var tasks: [PredictionState: Task<Void, Never>] = [:]
  private var failed: Set<PredictionState> = []
  private var generation = 0
  private let fetch: Fetch
  private let concurrency: Int

  public convenience init(predictor: Predictor) {
    self.init { state in
      let keys = (Keyboard.signature(state.prefix) ?? "") + (state.group == 0 ? "" : String(state.group))
      return try await predictor.predict(keys: keys, draft: state.text, context: "", expand: false, exactPrefix: state.prefix).words
    }
  }

  public init(concurrency: Int = 8, fetch: @escaping Fetch) {
    self.concurrency = max(1, concurrency); self.fetch = fetch
  }

  public func update(_ state: PredictionState) {
    active = state
    failed.remove(state)
    if let words = cache[state] {
      SessionLog.shared.record("cache_hit", ["group": state.group, "words": words])
      publish(words, words.isEmpty ? "AI returned no suggestions" : "Cached AI suggestions")
    } else {
      publish([], "Loading AI suggestions…")
    }
    prepare()
  }

  /// Retain completed responses for Back/Delete; cancel work on pause/background.
  public func pause() {
    generation += 1; active = nil
    for task in tasks.values { task.cancel() }
    tasks = [:]; pending = []; failed = []
  }

  /// A manually requested completion can seed the same session cache.
  public func store(_ words: [String], for state: PredictionState) {
    cache[state] = words
    if active == state { publish(words, "AI suggestions ready"); prepare() }
  }

  public static func destinations(for state: PredictionState, words: [String]) -> [PredictionState] {
    var desired = [state]
    func add(_ text: String, _ prefix: String, groups: Bool = false) {
      for group in 0...(groups ? 6 : 0) {
        let next = PredictionState(text: text, prefix: prefix, group: group)
        if !desired.contains(next) { desired.append(next) }
      }
    }
    add(state.text, state.prefix, groups: true)
    if (1...6).contains(state.group) {
      for letter in Keyboard.groups[state.group - 1] { add(state.text, state.prefix + String(letter)) }
    }
    for word in (state.prefix.isEmpty ? [] : [state.prefix]) + words {
      add(state.text, word)
      add(state.text + (state.text.isEmpty ? "" : " ") + word, "", groups: true)
    }
    return desired
  }

  private func prepare() {
    guard let active else { return }
    // Only visible results create speculative destinations. No recursive fan-out.
    pending = Self.destinations(for: active, words: snapshot.words).filter {
      cache[$0] == nil && tasks[$0] == nil && !failed.contains($0)
    }
    pump()
  }

  private func publish(_ words: [String], _ status: String) {
    snapshot = Snapshot(words: words, status: status)
    onChange?(snapshot)
  }

  private func pump() {
    let current = generation
    while active != nil && tasks.count < concurrency && !pending.isEmpty {
      let state = pending.removeFirst()
      tasks[state] = Task { [weak self, fetch] in
        guard !Task.isCancelled else { return }
        let result: Result<[String], Error>
        do { result = .success(try await fetch(state)) }
        catch { result = .failure(error) }
        guard let self, !Task.isCancelled, self.generation == current else { return }
        self.tasks[state] = nil
        switch result {
        case .success(let words):
          self.cache[state] = words
          SessionLog.shared.record("cache_store", ["group": state.group, "draft": state.text, "prefix": state.prefix, "words": words])
          if self.active == state {
            self.publish(words, words.isEmpty ? "AI returned no suggestions" : "AI suggestions ready")
            self.prepare()
          }
        case .failure:
          self.failed.insert(state)
          if self.active == state { self.publish([], "AI unavailable · see request log") }
        }
        self.pump()
      }
    }
  }
}

/// Keep the actual selectable values and their labels identical while dwelling.
/// A state change (typing, Back, etc.) must call reset and restart dwell timing.
public struct SuggestionDisplay {
  public private(set) var words: [String] = []
  private var pending: [String]?
  private var frozen = false
  public init() {}
  public mutating func receive(_ words: [String]) {
    if frozen { pending = words } else { self.words = words }
  }
  public mutating func setDwelling(_ value: Bool) {
    frozen = value
    if !value, let pending { words = pending; self.pending = nil }
  }
  public mutating func reset() { words = []; pending = nil; frozen = false }
}
