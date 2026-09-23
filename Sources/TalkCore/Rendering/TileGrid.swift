import CoreGraphics
import Foundation

/// Where a call's tiles go: every tile the same size, as large as the space allows, in rows
/// centred on the stage — the last row too when it isn't full — the way FaceTime lays out a
/// group. No scrolling: more people make smaller tiles.
struct TileGrid: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let tileSize: CGSize
    private let count: Int
    private let spacing: CGFloat
    private let bounds: CGSize

    /// The arrangement of `count` tiles of `aspectRatio` (width over height) that makes them
    /// largest in `bounds`.
    init(count: Int, in bounds: CGSize, aspectRatio: CGFloat = 4 / 3, spacing: CGFloat = 12) {
        self.count = count
        self.spacing = spacing
        self.bounds = bounds
        var best = (columns: 1, rows: max(count, 1), size: CGSize.zero)
        for columns in 1...max(count, 1) {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let across = (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let down = (bounds.height - spacing * CGFloat(rows - 1)) / CGFloat(max(rows, 1))
            // As wide as a column allows, unless that makes the rows too tall.
            var width = max(across, 0)
            var height = width / aspectRatio
            if height > down {
                height = max(down, 0)
                width = height * aspectRatio
            }
            if width * height > best.size.width * best.size.height {
                best = (columns, rows, CGSize(width: width, height: height))
            }
        }
        columns = best.columns
        rows = best.rows
        tileSize = best.size
    }

    /// The centre of tile `index`, with the grid centred in the bounds.
    func center(of index: Int) -> CGPoint {
        let row = index / columns
        let column = index % columns
        // A short last row is centred on its own.
        let inRow = row == rows - 1 ? count - row * columns : columns
        let rowWidth = tileSize.width * CGFloat(inRow) + spacing * CGFloat(inRow - 1)
        let gridHeight = tileSize.height * CGFloat(rows) + spacing * CGFloat(rows - 1)
        let x = (bounds.width - rowWidth) / 2 + CGFloat(column) * (tileSize.width + spacing) + tileSize.width / 2
        let y = (bounds.height - gridHeight) / 2 + CGFloat(row) * (tileSize.height + spacing) + tileSize.height / 2
        return CGPoint(x: x, y: y)
    }
}
