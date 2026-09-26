import Foundation

/// Two-level gaze keyboard over the fixed 4x3 cell geometry (the gaze model never changes).
/// Level 2: row 0 = the group's first 4 items (one per column), row 1 = the remaining 2-3 items,
/// row 2 = a whole-row "← back".
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
        let items = GazeModel.cells[safe: cell]?.items ?? []
        var keys: [Key] = []
        for (c, item) in items.prefix(4).enumerated() { keys.append(Key(id: c, label: item, cells: [c])) }
        let rest = Array(items.dropFirst(4))
        switch rest.count {
        case 2:   // spread: each spans two columns
            keys.append(Key(id: 4, label: rest[0], cells: [4, 5]))
            keys.append(Key(id: 5, label: rest[1], cells: [6, 7]))
        default:  // 3 (or 1): one per column, unused cells empty
            for (i, item) in rest.prefix(4).enumerated() { keys.append(Key(id: 4 + i, label: item, cells: [4 + i])) }
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
    again little bit better worse hurts hurt head leg arm chest breathe breathing air blanket pillow chair \
    move lift sit stand lie left right family friend wife husband mom dad son daughter kids name morning night \
    later soon something nothing anything everything someone people way work read book watch hear listen talk \
    speak slowly quiet loud happy sad scared worried fine great nice new old first last next other same did \
    does done been had has am were then than because only still even too over after before into
    """
    .split(whereSeparator: \.isWhitespace).map(String.init)

    /// Top 3 words for the current partial word (text after the last space). No prefix: I, you, the.
    static func suggestions(for text: String) -> [String] {
        let partial = currentWord(in: text).lowercased()
        guard !partial.isEmpty else { return ["I", "you", "the"] }
        var seen = Set<String>()
        let matches = words.filter {
            $0.lowercased().hasPrefix(partial) && $0.lowercased() != partial && seen.insert($0.lowercased()).inserted
        }
        return Array(matches.prefix(3))
    }

    static func currentWord(in text: String) -> Substring {
        text.split(separator: " ", omittingEmptySubsequences: false).last ?? ""
    }
}
