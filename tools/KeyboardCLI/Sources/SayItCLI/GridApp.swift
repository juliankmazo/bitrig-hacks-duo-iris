import Foundation
import Darwin
import KeyboardCore

@MainActor final class GridApp {
  let predictor: Predictor
  let model: String
  var renderEnabled = true
  var autoAI: Bool
  var draft = SpellingDraft()
  var words: [String] = []
  var phrases: [String] = []
  var menu = false
  var phraseMode = false
  var status = "Choose a group, then a letter or suggested word."
  var keyHistory: [String] = []
  var lastSelection = "—"
  var running = true
  var generation = 0
  var task: Task<Void, Never>?
  var speech: Process?
  let predictionEngine: PredictionEngine

  init(predictor: Predictor, autoAI: Bool, model: String) {
    self.predictor = predictor; self.autoAI = autoAI; self.model = model
    self.predictionEngine = PredictionEngine(predictor: predictor)
    predictionEngine.onChange = { [weak self] snapshot in
      guard let self, self.autoAI, !self.phraseMode else { return }
      self.words = snapshot.words; self.status = snapshot.status
      self.render()
    }
  }

  func run() async {
    SessionLog.shared.record("session_start", ["model": model, "auto_ai": autoAI,
      "cwd": FileManager.default.currentDirectoryPath, "candidate_filtering": false])
    defer { SessionLog.shared.record("session_end", state()) }
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else { return }
    var raw = original
    cfmakeraw(&raw)
    // Preserve normal newline output while reading one byte per selection.
    raw.c_oflag = original.c_oflag
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return }
    print("\u{1B}[?1049h\u{1B}[?25l", terminator: "")
    defer {
      task?.cancel(); cancelPrefetch()
      if speech?.isRunning == true { speech?.terminate() }
      tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
      print("\u{1B}[?25h\u{1B}[?1049l", terminator: ""); fflush(stdout)
    }
    refresh(); render()
    while running {
      var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      if poll(&descriptor, 1, 0) > 0 {
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { break }
        SessionLog.shared.record("keypress", ["byte": Int(byte), "key": String(UnicodeScalar(byte)), "state_before": state()])
        if byte == 3 || byte == 4 || byte == 27 { break }
        if byte == 10 || byte == 13 { continue }
        handle(String(UnicodeScalar(byte)).lowercased())
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  func invalidate() {
    generation += 1; task?.cancel(); task = nil
  }

  var activePrediction: PredictionState {
    PredictionState(text: draft.text, prefix: draft.prefix, group: draft.pendingGroup ?? 0)
  }

  func cancelPrefetch() { predictionEngine.pause() }

  func refresh() {
    invalidate(); phrases = []; phraseMode = false; words = []
    status = "AI paused. Select letters or use Menu to request predictions."
    if autoAI { predictionEngine.update(activePrediction) }
  }

  func predict(expand: Bool) {
    if expand && (draft.isPending || draft.text.isEmpty) {
      status = "Press 0 / Space to finish the current word, then expand the draft."; return
    }
    invalidate()
    let current = generation; let keys = draft.keys; let text = draft.text; let prefix = draft.prefix
    status = "AI working… You can keep selecting cells."
    task = Task { [weak self, predictor] in
      do {
        let result = try await predictor.predict(keys: keys, draft: text, context: "", expand: expand, exactPrefix: prefix)
        guard let self, !Task.isCancelled, self.generation == current else { return }
        if expand {
          self.phrases = result.phrases; self.phraseMode = true
        } else {
          self.words = result.words
          self.predictionEngine.store(result.words, for: self.activePrediction)
        }
        self.status = "AI suggestions ready"
        self.render()
      } catch {
        guard let self, !Task.isCancelled, self.generation == current else { return }
        self.status = error.localizedDescription; self.render()
      }
    }
  }

  func handle(_ key: String) {
    keyHistory.append(key == " " ? "SPACE" : (key == "\u{7F}" ? "⌫" : key.uppercased()))
    keyHistory = Array(keyHistory.suffix(32))
    let oldText = draft.text
    let oldPrefix = draft.prefix
    let oldGroup = draft.pendingGroup
    lastSelection = key.uppercased()
    do {
      if key == "c" {
        draft.clear(); menu = false; refresh(); status = "Started over."
      } else if key == " " || (key == "0" && (draft.pendingGroup == nil || menu)) {
        try draft.finish(); menu = false; refresh()
        status = "Word finished. Choose a group for the next word."
      } else if menu {
        switch key {
        case "1": menu = false; predict(expand: false)
        case "2": menu = false; predict(expand: true)
        case "3":
          autoAI.toggle(); cancelPrefetch()
          refresh(); status = autoAI ? "Automatic AI and prefetch enabled." : "Automatic AI paused."
        case "4": draft.clear(); menu = false; refresh()
        case "5": running = false
        case "6": try speak()
        case "7", "8", "9": try acceptSuggestion(Int(key)! - 7); menu = false
        case "m": menu = false
        default: status = "Select a labeled cell."
        }
      } else if draft.pendingGroup != nil {
        switch key {
        case "1", "2", "3", "4": try draft.choose(Int(key)! - 1); refresh()
        case "5", "6": try draft.choose(Int(key)! - 1); refresh()
        case "0": try draft.choose(6); refresh()
        case "7", "8", "9": try acceptSuggestion(Int(key)! - 7)
        case "b": draft.back(); refresh()
        case "u", "\u{7F}": draft.delete(); refresh()
        case "m": menu = true; status = "Choose a menu cell. M returns."
        case "s": try speak()
        default: status = "Choose a letter, suggestion, or B to go back."
        }
      } else {
        switch key {
        case "1", "2", "3", "4", "5", "6":
          try draft.open(Int(key)!); refresh()
        case "7", "8", "9":
          try acceptSuggestion(Int(key)! - 7)
        case "u", "\u{7F}": draft.delete(); refresh()
        case "m": menu = true; status = "Choose a menu cell. M returns to the keyboard."
        case "s": try speak()
        default: status = "Press one cell key: 1–9, U, M, or S."
        }
      }
    } catch { status = error.localizedDescription }
    if draft.text != oldText {
      lastSelection += " → message: " + (draft.text.isEmpty ? "(cleared)" : draft.text)
    } else if draft.prefix != oldPrefix {
      lastSelection += " → letters: " + (draft.prefix.isEmpty ? "(empty)" : draft.prefix)
    } else if let group = draft.pendingGroup, group != oldGroup {
      lastSelection += " → group " + Keyboard.groups[group - 1].uppercased()
    } else if oldGroup != nil && draft.pendingGroup == nil {
      lastSelection += " → back (no letter added)"
    }
    render()
  }

  func acceptSuggestion(_ index: Int) throws {
    let options = phraseMode ? phrases : words
    guard options.indices.contains(index) else { throw CLIError.message("That suggestion cell is empty.") }
    SessionLog.shared.record("suggestion_selected", ["index": index, "text": options[index], "phrase": phraseMode])
    if phraseMode { draft.replace(options[index]) } else { try draft.accept(options[index]) }
    refresh()
  }

  func speak() throws {
    if speech?.isRunning == true { speech?.terminate(); status = "Speech stopped."; return }
    guard !draft.isPending, !draft.text.isEmpty else {
      status = "Press 0 / Space to finish the current word before speaking."; return
    }
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    let pipe = Pipe(); process.standardInput = pipe
    try process.run(); pipe.fileHandleForWriting.write(Data(draft.text.utf8))
    try pipe.fileHandleForWriting.close(); speech = process
    status = "Speaking approved draft. Press S to stop."
  }

  // Sanitize model text before sending it to a terminal (no control sequences).
  func clean(_ text: String) -> String {
    String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
  }
  func lines(_ text: String, width: Int) -> [String] {
    let characters = Array(clean(text))
    if characters.isEmpty { return [""] }
    return stride(from: 0, to: characters.count, by: width).map {
      String(characters[$0..<min($0 + width, characters.count)])
    }
  }
  func letterCells() -> [(String, String)] {
    let letters = Array(Keyboard.groups[draft.pendingGroup! - 1].uppercased()).map(String.init)
    func letter(_ n: Int) -> (String, String) { letters.indices.contains(n) ? (n == 6 ? "0" : String(n + 1), letters[n]) : ("", "") }
    func word(_ n: Int) -> (String, String) { (String(n + 7), words.indices.contains(n) ? words[n] : "—") }
    return [letter(0), letter(1), letter(2), word(0),
            letter(3), letter(4), letter(5), word(1),
            letter(6), ("U", "Delete"), ("B", "Back"), word(2)]
  }

  func state() -> [String: Any] {
    ["draft": draft.text, "prefix": draft.prefix, "pending_group": draft.pendingGroup as Any? ?? NSNull(),
     "groups": draft.keys, "words": words, "phrases": phrases, "menu": menu,
     "phrase_mode": phraseMode, "auto_ai": autoAI, "status": status, "last_selection": lastSelection]
  }

  func render() {
    SessionLog.shared.record("render", state())
    guard renderEnabled else { return }
    let options = phraseMode ? phrases : words
    func option(_ n: Int) -> String { options.indices.contains(n) ? options[n] : "—" }
    let cells: [(String, String)] = menu ? [
      ("1", "Predict words"), ("2", "Expand phrase"), ("3", autoAI ? "AI: ON / toggle" : "AI: OFF / toggle"), ("7", option(0)),
      ("4", "Clear draft"), ("5", "Quit"), ("6", "Speak / Stop"), ("8", option(1)),
      ("", ""), ("M", "Back to keyboard"), ("0", "Space / Next word"), ("9", option(2))
    ] : draft.pendingGroup != nil ? letterCells() : [
      ("1", "ABCD · 0 1"), ("2", "EFGH · 2 3"), ("3", "IJKLM · 4 5"), ("7", option(0)),
      ("4", "NOPQ · 6 7"), ("5", "RSTUV · 8 9"), ("6", "WXYZ · ? !"), ("8", option(1)),
      ("0", "Space / New word"), ("U", "Delete"), ("C", "Start over"), ("9", option(2))
    ]
    let width = 18
    print("\u{1B}[H\u{1B}[2J", terminator: "")
    print("SAY IT · \(model) · \(autoAI ? "AI" : "AI paused") · \(menu ? "Menu" : (phraseMode ? "Phrase choices" : "Word choices"))")
    print("4 columns × 3 rows · Press ONE cell key. No Enter. Esc / Ctrl-C quits.")
    for line in lines("Message: " + (draft.text.isEmpty ? "" : draft.text + " ") + draft.prefix + "▌", width: 77) { print(line) }
    print("Current word: \(draft.prefix + "▌") · Group: \(draft.pendingGroup.map(String.init) ?? "—")")
    print("Keys pressed: " + (keyHistory.isEmpty ? "—" : keyHistory.joined(separator: " ")))
    print("Last selection: " + String(clean(lastSelection).suffix(61)))
    let border = "+" + Array(repeating: String(repeating: "-", count: width), count: 4).joined(separator: "+") + "+"
    for row in 0..<3 {
      print(border)
      let slice = Array(cells[(row * 4)..<(row * 4 + 4)])
      let content = slice.map { cell in [cell.0.isEmpty ? "" : "[\(cell.0)]"] + lines(cell.1, width: width - 2) }
      let height = max(3, content.map(\.count).max() ?? 3)
      for y in 0..<height {
        let parts = content.map { column -> String in
          let value = y < column.count ? column[y] : ""
          return " " + value + String(repeating: " ", count: max(0, width - 1 - value.count))
        }
        print("|" + parts.joined(separator: "|") + "|")
      }
    }
    print(border)
    for line in lines(status, width: 77) { print(line) }
    print(menu ? "Menu: 1–6 choose an action. M returns." : "Space finishes a word · U/Backspace deletes · C clears · M menu · S speaks")
    print("Log: logs/sessions.jsonl · session " + String(SessionLog.shared.sessionID.prefix(8)))
    fflush(stdout)
  }
}
