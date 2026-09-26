import Foundation

/// One of the 12 gaze cells (row-major, 0 = top-left).
struct GridCell: Identifiable {
    enum Kind { case letters, rest, action, suggest }

    let id: Int
    let label: String
    var caption: String?
    var systemImage: String?
    let kind: Kind

    /// What the selection log shows.
    var logLabel: String {
        switch kind {
        case .action: caption ?? label
        default: label
        }
    }

    /// The rest zone never fires a dwell selection.
    var isSelectable: Bool { kind != .rest }

    static let all: [GridCell] = [
        GridCell(id: 0, label: "ABCD", kind: .letters),
        GridCell(id: 1, label: "EFGH", kind: .letters),
        GridCell(id: 2, label: "IJKL", kind: .letters),
        GridCell(id: 3, label: "word 1", caption: "SUGGEST", kind: .suggest),
        GridCell(id: 4, label: "MNOP", kind: .letters),
        GridCell(id: 5, label: "•", caption: "REST", kind: .rest),
        GridCell(id: 6, label: "QRST", kind: .letters),
        GridCell(id: 7, label: "word 2", caption: "SUGGEST", kind: .suggest),
        GridCell(id: 8, label: "UVWXYZ", kind: .letters),
        GridCell(id: 9, label: "␣", caption: "SPACE", kind: .action),
        GridCell(id: 10, label: "⌫", caption: "DELETE", systemImage: "delete.left", kind: .action),
        GridCell(id: 11, label: "word 3", caption: "SUGGEST", kind: .suggest),
    ]
}
