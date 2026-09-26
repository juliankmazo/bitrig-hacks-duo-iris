import Foundation
import Darwin
import KeyboardCore

@main struct CLI {
  // Read simple KEY=value settings as data; never execute shell syntax.
  static func settings() -> [String: String] {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env")
    var values: [String: String] = [:]
    if let contents = try? String(contentsOf: path, encoding: .utf8) {
      for rawLine in contents.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
        let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        guard ["OPENAI_API_KEY", "OPENAI_MODEL"].contains(name) else { continue }
        var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
          value.removeFirst(); value.removeLast()
        }
        values[name] = value
      }
    }
    return values.merging(ProcessInfo.processInfo.environment) { _, environment in environment }
  }

  static func main() async {
    let settings = settings()
    let args = Array(CommandLine.arguments.dropFirst())
    let help = """
    Say It · 4-column × 3-row grid
    Usage: swift run say-it [--ai] [--ask-key] [--model MODEL]
    Press the key shown in a cell to select it immediately. No Enter needed.
    Select a group (1–6), then select a letter or word from the new grid. B goes back.
    U / Backspace: Delete. C: Start over. Space: Next word. M: Menu. S: Speak/Stop.
    The menu contains phrase expansion, AI prediction, clear, and quit.
    Escape or Ctrl-C exits. .env loads from the current directory.
    """
    if args.contains("--help") { print(help); return }
    var model = settings["OPENAI_MODEL"] ?? "gpt-6-luna"
    var autoAI = false; var askKey = false; var i = 0
    while i < args.count {
      switch args[i] {
      case "--ai": autoAI = true
      case "--ask-key": askKey = true
      case "--model":
        i += 1
        guard i < args.count, !args[i].hasPrefix("--") else { print("Missing model name."); exit(2) }
        model = args[i]
      default: print("Unknown argument: \(args[i])\n\(help)"); exit(2)
      }
      i += 1
    }
    var key = settings["OPENAI_API_KEY"] ?? ""
    if askKey {
      guard isatty(STDIN_FILENO) == 1 else { print("--ask-key requires a terminal; use OPENAI_API_KEY for piped input."); exit(2) }
      var original = termios()
      guard tcgetattr(STDIN_FILENO, &original) == 0 else { exit(2) }
      var hidden = original
      hidden.c_lflag &= ~tcflag_t(ECHO)
      print("OpenAI API key (hidden): ", terminator: ""); fflush(stdout)
      guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden) == 0 else { exit(2) }
      let entered = readLine()
      tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
      print("")
      guard let entered else { print("Could not read key."); exit(2) }
      key = entered.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard isatty(STDIN_FILENO) == 1 else {
      print("The grid requires an interactive terminal. Run swift run say-it --ai.")
      exit(2)
    }
    await GridApp(predictor: Predictor(key: key, model: model), autoAI: autoAI, model: model).run()
  }
}
