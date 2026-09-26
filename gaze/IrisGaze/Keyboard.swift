import Foundation

/// Two-level gaze keyboard over the fixed 4x3 cell geometry (the gaze model never changes).
///
/// Level 2 layout: columns are what the eyes resolve reliably, rows need a nod. So each letter owns a whole
/// column span (two stacked cells), and "back" owns the bottom row: picking a letter only needs the column
/// right, and a one-row error can't type the wrong letter.
enum Keyboard {
    /// A level-2 key: a label and the cells (row-major 0...11) it covers.
    struct Key: Identifiable {
        let id: Int
        let label: String
        let cells: [Int]
        var isBack: Bool { label == Keyboard.backLabel }
    }

    static let backLabel = "← back"

    static func keys(forGroup cell: Int) -> [Key] {
        let letters = GazeModel.cells[safe: cell].map { Array($0.label).map(String.init) } ?? []
        var keys: [Key] = []
        switch letters.count {
        case 4:
            // A B C D, each in rows 0-1 of its column
            for (c, l) in letters.enumerated() { keys.append(Key(id: c, label: l, cells: [c, c + 4])) }
        case 6:
            // U V W X in row 0, Y / Z split row 1
            for (c, l) in letters.prefix(4).enumerated() { keys.append(Key(id: c, label: l, cells: [c])) }
            keys.append(Key(id: 4, label: letters[4], cells: [4, 5]))
            keys.append(Key(id: 5, label: letters[5], cells: [6, 7]))
        default:
            for (i, l) in letters.enumerated() where i < 8 { keys.append(Key(id: i, label: l, cells: [i])) }
        }
        keys.append(Key(id: 99, label: backLabel, cells: [8, 9, 10, 11]))
        return keys
    }

    static func key(at cell: Int, group: Int) -> Key? {
        keys(forGroup: group).first { $0.cells.contains(cell) }
    }

    // MARK: Word suggestions

    /// ~200 most frequent English words (roughly by frequency), plus a few AAC staples.
    static let words: [String] = """
    I you the to and a it is that of in my me we what not be do have this for on are with your can was he she \
    they no yes but so just like know get go want need help please thank thanks feel pain water now here there \
    good okay ok how when where why who time day today tomorrow yesterday home more some all out up down one \
    about would could will if or at as from by an his her them their our us him think see come make take give \
    tell say said look back well also very really much many sorry love hot cold tired hungry thirsty bathroom \
    bed sleep eat drink food medicine doctor nurse call phone tv music light turn off open close stop wait \
    again little bit better worse hurts hurt head leg arm back chest breathe breathing air blanket pillow chair \
    move lift sit stand lie left right family friend wife husband mom dad son daughter kids name morning night \
    later soon something nothing anything everything someone people way work read book watch hear listen talk \
    speak slowly quiet loud happy sad scared worried fine great nice new old first last next other same did \
    does done been had has am were then than because only still even too off over after before into
    """
    .split(whereSeparator: \.isWhitespace).map(String.init)

    /// Top 3 words for the current partial word (text after the last space). No prefix: I, you, the.
    static func suggestions(for text: String) -> [String] {
        let partial = currentWord(in: text).lowercased()
        guard !partial.isEmpty else { return ["I", "you", "the"] }
        var seen = Set<String>()
        let matches = words.filter { $0.lowercased().hasPrefix(partial) && $0.lowercased() != partial && seen.insert($0.lowercased()).inserted }
        return Array(matches.prefix(3))
    }

    static func currentWord(in text: String) -> Substring {
        text.split(separator: " ", omittingEmptySubsequences: false).last ?? ""
    }
}
