import Foundation
import KeyboardCore

/// The first three columns hold characters and controls at both levels.
/// Suggestions always occupy cells 3, 7, and 11.
enum Keyboard {
    struct Key: Identifiable {
        let id: Int
        let label: String
        let cells: [Int]
        let kind: GridCell.Kind
        var isBack: Bool { kind == .back }
    }
    static let groupCells = [0, 1, 2, 4, 5, 6]
    static let suggestionCells = [3, 7, 11]
    static let characterCells = [0, 1, 2, 4, 5, 6, 8]

    static func keys(forGroup cell: Int) -> [Key] {
        guard let group = groupCells.firstIndex(of: cell) else { return [] }
        var keys = Array(KeyboardCore.Keyboard.groups[group].uppercased()).enumerated().map { index, letter in
            let cell = characterCells[index]
            return Key(id: cell, label: String(letter), cells: [cell], kind: .letters)
        }
        keys.append(Key(id: 9, label: "Delete", cells: [9], kind: .delete))
        keys.append(Key(id: 10, label: "← back", cells: [10], kind: .back))
        return keys
    }

    static func key(at cell: Int, group: Int) -> Key? {
        keys(forGroup: group).first { $0.cells.contains(cell) }
    }
}
