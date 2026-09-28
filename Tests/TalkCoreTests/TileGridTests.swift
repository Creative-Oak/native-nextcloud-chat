import CoreGraphics
import Testing
@testable import TalkCore

struct TileGridTests {
    @Test func twoPeopleOnAWideStageSitSideBySide() {
        let grid = TileGrid(count: 2, in: CGSize(width: 1000, height: 500), spacing: 10)
        #expect(grid.columns == 2)
        #expect(grid.rows == 1)
        // 495 wide at 4:3 would be 371 tall: fits.
        #expect(grid.tileSize.width == 495)
    }

    @Test func twoPeopleOnATallStageStack() {
        let grid = TileGrid(count: 2, in: CGSize(width: 400, height: 800), spacing: 10)
        #expect(grid.columns == 1)
        #expect(grid.rows == 2)
    }

    @Test func fourMakeTwoByTwo() {
        let grid = TileGrid(count: 4, in: CGSize(width: 800, height: 600))
        #expect(grid.columns == 2)
        #expect(grid.rows == 2)
    }

    @Test func tilesNeverSpillOutOfTheStage() {
        for count in 1...12 {
            let bounds = CGSize(width: 900, height: 560)
            let grid = TileGrid(count: count, in: bounds)
            let width = grid.tileSize.width * CGFloat(grid.columns) + 12 * CGFloat(grid.columns - 1)
            let height = grid.tileSize.height * CGFloat(grid.rows) + 12 * CGFloat(grid.rows - 1)
            #expect(width <= bounds.width + 0.001, "count \(count)")
            #expect(height <= bounds.height + 0.001, "count \(count)")
            #expect(grid.columns * grid.rows >= count)
        }
    }

    @Test func aShortLastRowIsCentred() {
        // Three on a wide stage: two over one, and the one in the middle.
        let bounds = CGSize(width: 800, height: 600)
        let grid = TileGrid(count: 3, in: bounds)
        #expect(grid.columns == 2)
        #expect(abs(grid.center(of: 2).x - bounds.width / 2) < 0.001)
        #expect(grid.center(of: 0).x < grid.center(of: 1).x)
    }

    @Test func theGridIsCentredVertically() {
        let bounds = CGSize(width: 1000, height: 900)
        let grid = TileGrid(count: 2, in: bounds)
        let top = grid.center(of: 0).y - grid.tileSize.height / 2
        let bottom = grid.center(of: grid.rows == 1 ? 0 : 1).y + grid.tileSize.height / 2
        #expect(abs(top - (bounds.height - bottom)) < 0.001)
    }
}
