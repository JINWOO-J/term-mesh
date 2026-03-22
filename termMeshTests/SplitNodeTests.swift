import XCTest
import AppKit

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

@testable import Bonsplit

// MARK: - SplitNode.computePaneBounds Tests

/// Tests for SplitNode's pure recursive tree functions:
/// computePaneBounds, findPane, allPaneIds, allPanes.
final class SplitNodeComputePaneBoundsTests: XCTestCase {

    // MARK: - Helpers

    private func makePane(id: PaneID? = nil) -> (PaneState, PaneID) {
        let paneId = id ?? PaneID()
        let state = PaneState(id: paneId)
        return (state, paneId)
    }

    private func makeSplit(
        orientation: SplitOrientation,
        first: SplitNode,
        second: SplitNode,
        dividerPosition: CGFloat = 0.5
    ) -> SplitNode {
        let state = SplitState(
            orientation: orientation,
            first: first,
            second: second,
            dividerPosition: dividerPosition
        )
        return .split(state)
    }

    // MARK: - Single pane (leaf)

    func testSinglePaneReturnsFullRect() {
        let (pane, paneId) = makePane()
        let node = SplitNode.pane(pane)

        let bounds = node.computePaneBounds()

        XCTAssertEqual(bounds.count, 1, "Single pane should produce exactly one PaneBounds")
        XCTAssertEqual(bounds[0].paneId, paneId)
        XCTAssertEqual(bounds[0].bounds, CGRect(x: 0, y: 0, width: 1, height: 1),
                       accuracy: 0.001, "Single pane should occupy the entire unit rect")
    }

    func testSinglePaneRespectsCustomAvailableRect() {
        let (pane, paneId) = makePane()
        let node = SplitNode.pane(pane)
        let customRect = CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4)

        let bounds = node.computePaneBounds(in: customRect)

        XCTAssertEqual(bounds.count, 1)
        XCTAssertEqual(bounds[0].paneId, paneId)
        XCTAssertEqual(bounds[0].bounds, customRect, accuracy: 0.001)
    }

    // MARK: - Horizontal split (left | right)

    func testHorizontalSplitEvenDivider() {
        let (leftPane, leftId) = makePane()
        let (rightPane, rightId) = makePane()

        let node = makeSplit(
            orientation: .horizontal,
            first: .pane(leftPane),
            second: .pane(rightPane),
            dividerPosition: 0.5
        )

        let bounds = node.computePaneBounds()
        XCTAssertEqual(bounds.count, 2)

        let left = bounds.first { $0.paneId == leftId }!
        let right = bounds.first { $0.paneId == rightId }!

        // Left half: x=0, width=0.5
        XCTAssertEqual(left.bounds.minX, 0, accuracy: 0.001)
        XCTAssertEqual(left.bounds.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(left.bounds.height, 1, accuracy: 0.001)

        // Right half: x=0.5, width=0.5
        XCTAssertEqual(right.bounds.minX, 0.5, accuracy: 0.001)
        XCTAssertEqual(right.bounds.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(right.bounds.height, 1, accuracy: 0.001)
    }

    func testHorizontalSplitUnevenDivider() {
        let (leftPane, leftId) = makePane()
        let (rightPane, rightId) = makePane()

        let node = makeSplit(
            orientation: .horizontal,
            first: .pane(leftPane),
            second: .pane(rightPane),
            dividerPosition: 0.3
        )

        let bounds = node.computePaneBounds()
        let left = bounds.first { $0.paneId == leftId }!
        let right = bounds.first { $0.paneId == rightId }!

        XCTAssertEqual(left.bounds.width, 0.3, accuracy: 0.001)
        XCTAssertEqual(right.bounds.minX, 0.3, accuracy: 0.001)
        XCTAssertEqual(right.bounds.width, 0.7, accuracy: 0.001)
    }

    // MARK: - Vertical split (top / bottom)

    func testVerticalSplitEvenDivider() {
        let (topPane, topId) = makePane()
        let (bottomPane, bottomId) = makePane()

        let node = makeSplit(
            orientation: .vertical,
            first: .pane(topPane),
            second: .pane(bottomPane),
            dividerPosition: 0.5
        )

        let bounds = node.computePaneBounds()
        XCTAssertEqual(bounds.count, 2)

        let top = bounds.first { $0.paneId == topId }!
        let bottom = bounds.first { $0.paneId == bottomId }!

        // Top: y=0, height=0.5
        XCTAssertEqual(top.bounds.minY, 0, accuracy: 0.001)
        XCTAssertEqual(top.bounds.height, 0.5, accuracy: 0.001)
        XCTAssertEqual(top.bounds.width, 1, accuracy: 0.001)

        // Bottom: y=0.5, height=0.5
        XCTAssertEqual(bottom.bounds.minY, 0.5, accuracy: 0.001)
        XCTAssertEqual(bottom.bounds.height, 0.5, accuracy: 0.001)
    }

    // MARK: - Nested splits (3+ panes)

    func testNestedHorizontalSplitProducesThreePanes() {
        let (paneA, idA) = makePane()
        let (paneB, idB) = makePane()
        let (paneC, idC) = makePane()

        // Layout: [A | [B | C]]
        let rightSplit = makeSplit(
            orientation: .horizontal,
            first: .pane(paneB),
            second: .pane(paneC),
            dividerPosition: 0.5
        )
        let root = makeSplit(
            orientation: .horizontal,
            first: .pane(paneA),
            second: rightSplit,
            dividerPosition: 0.5
        )

        let bounds = root.computePaneBounds()
        XCTAssertEqual(bounds.count, 3)

        let a = bounds.first { $0.paneId == idA }!
        let b = bounds.first { $0.paneId == idB }!
        let c = bounds.first { $0.paneId == idC }!

        // A takes left half: [0, 0.5)
        XCTAssertEqual(a.bounds.minX, 0, accuracy: 0.001)
        XCTAssertEqual(a.bounds.width, 0.5, accuracy: 0.001)

        // B takes left half of right half: [0.5, 0.75)
        XCTAssertEqual(b.bounds.minX, 0.5, accuracy: 0.001)
        XCTAssertEqual(b.bounds.width, 0.25, accuracy: 0.001)

        // C takes right half of right half: [0.75, 1.0)
        XCTAssertEqual(c.bounds.minX, 0.75, accuracy: 0.001)
        XCTAssertEqual(c.bounds.width, 0.25, accuracy: 0.001)
    }

    func testMixedOrientationSplit() {
        let (paneA, idA) = makePane()
        let (paneB, idB) = makePane()
        let (paneC, idC) = makePane()

        // Layout: [A] on top, [B | C] on bottom
        let bottomSplit = makeSplit(
            orientation: .horizontal,
            first: .pane(paneB),
            second: .pane(paneC),
            dividerPosition: 0.5
        )
        let root = makeSplit(
            orientation: .vertical,
            first: .pane(paneA),
            second: bottomSplit,
            dividerPosition: 0.4
        )

        let bounds = root.computePaneBounds()
        XCTAssertEqual(bounds.count, 3)

        let a = bounds.first { $0.paneId == idA }!
        let b = bounds.first { $0.paneId == idB }!
        let c = bounds.first { $0.paneId == idC }!

        // A: full width, top 40%
        XCTAssertEqual(a.bounds.minY, 0, accuracy: 0.001)
        XCTAssertEqual(a.bounds.height, 0.4, accuracy: 0.001)
        XCTAssertEqual(a.bounds.width, 1, accuracy: 0.001)

        // B: left half of bottom 60%
        XCTAssertEqual(b.bounds.minY, 0.4, accuracy: 0.001)
        XCTAssertEqual(b.bounds.height, 0.6, accuracy: 0.001)
        XCTAssertEqual(b.bounds.width, 0.5, accuracy: 0.001)

        // C: right half of bottom 60%
        XCTAssertEqual(c.bounds.minX, 0.5, accuracy: 0.001)
        XCTAssertEqual(c.bounds.height, 0.6, accuracy: 0.001)
    }

    // MARK: - Bounds cover full area (no gaps)

    func testBoundsCoverFullUnitRect() {
        let (paneA, _) = makePane()
        let (paneB, _) = makePane()
        let (paneC, _) = makePane()
        let (paneD, _) = makePane()

        // 2x2 grid: [[A|B] / [C|D]]
        let topSplit = makeSplit(orientation: .horizontal,
                                first: .pane(paneA), second: .pane(paneB))
        let bottomSplit = makeSplit(orientation: .horizontal,
                                   first: .pane(paneC), second: .pane(paneD))
        let root = makeSplit(orientation: .vertical,
                             first: topSplit, second: bottomSplit)

        let bounds = root.computePaneBounds()
        XCTAssertEqual(bounds.count, 4)

        // Sum of all areas should equal 1.0 (unit rect)
        let totalArea = bounds.reduce(0.0) { $0 + $1.bounds.width * $1.bounds.height }
        XCTAssertEqual(totalArea, 1.0, accuracy: 0.001, "All pane bounds should cover the full unit rect")
    }
}

// MARK: - SplitNode utility methods

final class SplitNodeUtilityTests: XCTestCase {

    // MARK: - allPaneIds

    func testAllPaneIdsSinglePane() {
        let paneId = PaneID()
        let node = SplitNode.pane(PaneState(id: paneId))
        XCTAssertEqual(node.allPaneIds, [paneId])
    }

    func testAllPaneIdsMultiplePanes() {
        let idA = PaneID(), idB = PaneID(), idC = PaneID()
        let split = SplitNode.split(SplitState(
            orientation: .horizontal,
            first: .pane(PaneState(id: idA)),
            second: .split(SplitState(
                orientation: .vertical,
                first: .pane(PaneState(id: idB)),
                second: .pane(PaneState(id: idC))
            ))
        ))

        let ids = split.allPaneIds
        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(ids.contains(idA))
        XCTAssertTrue(ids.contains(idB))
        XCTAssertTrue(ids.contains(idC))
    }

    // MARK: - findPane

    func testFindPaneExistingId() {
        let targetId = PaneID()
        let node = SplitNode.split(SplitState(
            orientation: .horizontal,
            first: .pane(PaneState(id: PaneID())),
            second: .pane(PaneState(id: targetId))
        ))

        let found = node.findPane(targetId)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, targetId)
    }

    func testFindPaneNonExistentIdReturnsNil() {
        let node = SplitNode.pane(PaneState(id: PaneID()))
        XCTAssertNil(node.findPane(PaneID()), "Should return nil for non-existent pane ID")
    }

    // MARK: - allPanes

    func testAllPanesReturnsCorrectCount() {
        let split = SplitNode.split(SplitState(
            orientation: .vertical,
            first: .pane(PaneState()),
            second: .pane(PaneState())
        ))
        XCTAssertEqual(split.allPanes.count, 2)
    }
}

// MARK: - CGRect accuracy helper

private func XCTAssertEqual(_ actual: CGRect, _ expected: CGRect, accuracy: CGFloat,
                            _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, message, file: file, line: line)
    XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, message, file: file, line: line)
    XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, message, file: file, line: line)
    XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, message, file: file, line: line)
}
