import Foundation

/// One of the 12 level-1 cells (row-major, 0 = top-left). Julian's keyboard design.
struct GridCell: Identifiable {
    enum Kind { case letters, suggest, delete, space, startOver, back }

    let id: Int
    let label: String
    /// Second line (the two extra characters of a letter cell, or "New Word").
    var sub: String?
    let kind: Kind

    /// What the selection log shows.
    var logLabel: String { label }

    var isSelectable: Bool { true }

    /// Level-2 items of a letter cell: its letters (Q and U are separate) followed by the two extras.
    var items: [String] {
        guard kind == .letters else { return [] }
        var letters: [String] = []
        for ch in label {
            if ch == "u", letters.last == "Q" { letters[letters.count - 1] = "Qu" } else { letters.append(String(ch)) }
        }
        return letters + (sub?.split(separator: " ").map(String.init) ?? [])
    }

    static let all: [GridCell] = [
        GridCell(id: 0, label: "ABCD", sub: "0 1", kind: .letters),
        GridCell(id: 1, label: "EFGH", sub: "2 3", kind: .letters),
        GridCell(id: 2, label: "IJKLM", sub: "4 5", kind: .letters),
        GridCell(id: 3, label: "Word 1", kind: .suggest),
        GridCell(id: 4, label: "NOPQ", sub: "6 7", kind: .letters),
        GridCell(id: 5, label: "RSTUV", sub: "8 9", kind: .letters),
        GridCell(id: 6, label: "WXYZ", sub: "? !", kind: .letters),
        GridCell(id: 7, label: "Word 2", kind: .suggest),
        GridCell(id: 8, label: "Space", sub: "New Word", kind: .space),
        GridCell(id: 9, label: "Delete", kind: .delete),
        GridCell(id: 10, label: "Start over", kind: .startOver),
        GridCell(id: 11, label: "Word 3", kind: .suggest),
    ]
}
