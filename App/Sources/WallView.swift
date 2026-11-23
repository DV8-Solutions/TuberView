import AppKit

/// Lays the pictures out so they touch: one fills the window, two sit side
/// by side, three or four make a two-by-two block. Every picture keeps the
/// TV shape, and there is no gap or frame between them.
final class WallView: NSView {

    var tiles: [NSView] = [] {
        didSet {
            place()
            needsLayout = true
        }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("WallView is built in code")
    }

    /// Columns and rows for a number of pictures.
    static func grid(for count: Int) -> (columns: Int, rows: Int) {
        switch count {
        case ...1: return (1, 1)
        case 2: return (2, 1)
        default: return (2, 2)
        }
    }

    override func layout() {
        super.layout()
        place()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        place()
    }

    private func place() {
        let count = tiles.count
        guard count > 0, bounds.width > 0, bounds.height > 0 else { return }
        if count == 1 {
            tiles[0].frame = bounds
            return
        }
        let grid = WallView.grid(for: count)
        let columns = CGFloat(grid.columns)
        let rows = CGFloat(grid.rows)
        let cellWidth = min(bounds.width / columns, bounds.height / rows * 16 / 9)
        let cellHeight = cellWidth * 9 / 16
        let left = (bounds.width - cellWidth * columns) / 2
        let top = (bounds.height - cellHeight * rows) / 2

        for (i, tile) in tiles.enumerated() {
            let row = i / grid.columns
            let column = i % grid.columns
            // a last row that is not full sits in the middle
            let inRow = min(grid.columns, count - row * grid.columns)
            let shift = CGFloat(grid.columns - inRow) * cellWidth / 2
            // edges are rounded, sizes are the difference between edges, so
            // neighbours always share an edge exactly
            let x0 = (left + shift + CGFloat(column) * cellWidth).rounded()
            let x1 = (left + shift + CGFloat(column + 1) * cellWidth).rounded()
            let y0 = (top + CGFloat(row) * cellHeight).rounded()
            let y1 = (top + CGFloat(row + 1) * cellHeight).rounded()
            tile.frame = NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }
}
