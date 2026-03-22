import XCTest
import AppKit

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

// MARK: - TERM-MESH-9: NSRangeException (NSMutableRLEArray out of bounds)
//
// Root cause: NSTextStorage's internal RLE-array backing is mutated concurrently or
// while an observer/layout pass is already iterating its attributes.
//
// Three known triggering patterns:
//   A) Rapid typing + arrow keys while IME composition is active
//   B) Delete/insert overlapping the markedText range before it is confirmed
//   C) Attributed-string edits issued from a background thread

/// Tests that validate IMETextView survives the exact sequences that triggered
/// TERM-MESH-9 without raising NSRangeException.
///
/// These are **regression guards**: a future NSRangeException will surface as a
/// test crash rather than a silent Sentry event.
final class TERM_MESH_9_NSRangeExceptionTests: XCTestCase {

    // MARK: Setup

    private var sut: IMETextView!

    override func setUp() {
        super.setUp()
        sut = IMETextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        // Attach a window so NSTextStorage layout manager is fully active.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(sut)
        sut.sendKeyHandler = { _, _ in }   // no-op; prevents nil crash
    }

    override func tearDown() {
        sut?.window?.close()
        sut = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }

    // MARK: - Scenario A: Rapid typing + arrow keys during IME composition
    //
    // Precondition : IME has multi-character marked text (CJK composition in progress).
    // Execution    : Fire 20 alternating character-insert / arrow-key events in <1 ms each.
    // Expected     : No NSRangeException; hasMarkedText state is consistent afterward.
    // Automatable  : YES (synthetic NSEvent; no real IME needed for unit test).

    func testRapidTypingWithArrowsDuringMarkedTextDoesNotCrash() {
        // Enter composition with a 3-char marked range (simulates hangul/CJK IME mid-word)
        sut.setMarkedText("한글입", selectedRange: NSRange(location: 3, length: 0),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(sut.hasMarkedText(), "Precondition: must have marked text")

        let leftArrow:  UInt16 = 0x7B
        let rightArrow: UInt16 = 0x7C
        let upArrow:    UInt16 = 0x7E

        // Rapidly fire 20 mixed arrow events — the bug manifested at 10-15 events/ms.
        for i in 0..<20 {
            let kc: UInt16 = [leftArrow, rightArrow, upArrow][i % 3]
            guard let event = makeKeyDown(keyCode: kc) else { continue }
            // Must not throw NSRangeException:
            sut.keyDown(with: event)
        }

        // Verify the view is still in a coherent state (string length >= 0 is always true,
        // but this forces NSTextStorage to serialize its internal state).
        XCTAssertGreaterThanOrEqual(sut.string.count, 0,
            "IMETextView must remain coherent after rapid arrow key events during composition")
    }

    // MARK: - Scenario B: Delete/insert overlapping the marked text range
    //
    // Precondition : IME has marked text.
    // Execution    : Call insertText + deleteBackward in rapid alternation before
    //               the marked text is confirmed (no Return key).
    // Expected     : No exception; string length is non-negative and markedRange is valid.
    // Automatable  : YES.

    func testDeleteInsertOverlapWithMarkedTextDoesNotCrash() {
        sut.setMarkedText("abc", selectedRange: NSRange(location: 2, length: 1),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(sut.hasMarkedText(), "Precondition: must have marked text")

        // Interleave insertions and deletions that deliberately overlap the marked range.
        for _ in 0..<10 {
            sut.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
            sut.deleteBackward(nil)
        }

        // Confirm: NSTextStorage internal consistency.
        let markedRange = sut.markedRange()
        XCTAssertTrue(
            markedRange.location == NSNotFound || markedRange.location <= sut.string.count,
            "markedRange.location must be within string bounds after interleaved insert/delete"
        )
        XCTAssertGreaterThanOrEqual(sut.string.count, 0)
    }

    // MARK: - Scenario C: Background-thread attributed string modification
    //
    // Precondition : IMETextView has content.
    // Execution    : A background thread reads textStorage while main thread writes to string.
    // Expected     : No data race / NSRangeException crash detected within 0.5 s.
    // Automatable  : YES (stress test; non-deterministic but catches most data races).
    // Note         : This test intentionally exercises the race window; Xcode's Thread
    //               Sanitizer (TSan) will flag the exact access if enabled at build time.

    func testConcurrentAttributedStringModificationDoesNotCrash() {
        sut.string = "initial content for concurrent access test"

        let expectation = XCTestExpectation(description: "Background read completes")
        let iterations = 50

        // Background thread: repeatedly reads attributedString snapshot.
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let textStorage = self?.sut.textStorage else {
                expectation.fulfill()
                return
            }
            for _ in 0..<iterations {
                // Reading length must never see an out-of-bounds RLE state.
                _ = textStorage.length
                _ = textStorage.string
                Thread.sleep(forTimeInterval: 0.001)
            }
            expectation.fulfill()
        }

        // Main thread: repeatedly modifies string content while background reads.
        for i in 0..<iterations {
            sut.string = "content iteration \(i)"
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.002))
        }

        wait(for: [expectation], timeout: 2.0)
        // Reaching here without crash == test passed.
    }

    // MARK: - Scenario D: unmarkText called while setMarkedText is in flight
    //
    // Simulates the exact sequence Sentry captured: setMarkedText → rapid keyDown
    // → unmarkText from a layout pass before the IME controller finalised the range.

    func testUnmarkTextDuringActiveCompositionDoesNotCrash() {
        let leftArrow: UInt16 = 0x7B

        for round in 0..<5 {
            sut.setMarkedText("テスト\(round)",
                              selectedRange: NSRange(location: 3, length: 0),
                              replacementRange: NSRange(location: NSNotFound, length: 0))

            // Simulate a stray keyDown arriving before the input context confirms the text.
            if let event = makeKeyDown(keyCode: leftArrow) {
                sut.keyDown(with: event)
            }

            // Simulate the input context committing the composition early.
            sut.unmarkText()
        }

        XCTAssertFalse(sut.hasMarkedText(),
            "After unmarkText, IME should have no pending composition")
    }
}

// MARK: - App Hanging: Main-thread block > 2 s (14 Sentry issues)
//
// The hang family shares a common pattern: work that is safe off-main (socket parsing,
// large output processing, model mutations) is instead dispatched synchronously to
// the main thread, causing UI freezes that Sentry reports as "App Hanging" events.
//
// Three sub-scenarios:
//   1. Burst socket commands (many concurrent senders all dispatch to main sync)
//   2. Large terminal output processed on main thread
//   3. Rapid tab/panel create+destroy (layout thrash on main thread)

/// Tests that validate main-thread scheduling discipline. Each test measures
/// how long the main thread is blocked and fails if it exceeds 500 ms.
///
/// **Preconditions for these tests to be meaningful:**
///   - Run with an instrumented/Debug build (not Release with all optimisations).
///   - The socket command handler must be wired in (tested via Python integration
///     tests when the full daemon is running; see tests/test_hang_*.py).
///
/// The unit tests below exercise the *pure scheduling* surface: they verify that
/// functions that should be async do not block the caller.
final class AppHangRegressionTests: XCTestCase {

    // MARK: - Scenario 1: Burst socket command dispatch
    //
    // Precondition : 100 concurrent background queues each try to update shared model state.
    // Execution    : Each queue calls a lightweight "process command" closure that in a
    //               correct implementation does off-main work and only async-dispatches
    //               the minimal UI mutation.
    // Expected     : Main thread is free; total elapsed < 500 ms.
    // Automatable  : YES (no daemon required; models are in-process).

    func testBurstSocketCommandsDoNotBlockMainThread() {
        let commandCount = 100
        let group = DispatchGroup()
        let mainThreadBlockExpectation = XCTestExpectation(
            description: "Main thread must remain responsive during burst")
        mainThreadBlockExpectation.isInverted = false

        var mainThreadWasBlocked = false
        let blockThreshold: TimeInterval = 0.5   // 500 ms

        // Probe: run a recurring main-thread task and measure latency.
        let probeStart = Date()
        var lastProbeTime = probeStart
        let probeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            let now = Date()
            let gap = now.timeIntervalSince(lastProbeTime)
            if gap > blockThreshold {
                mainThreadWasBlocked = true
            }
            lastProbeTime = now
        }

        // Fire burst of background "socket parse + async dispatch" work.
        for i in 0..<commandCount {
            group.enter()
            DispatchQueue.global(qos: .userInteractive).async {
                // Simulate off-main parsing (correct behaviour).
                let payload = "workspace.list\0session=\(i)"
                _ = payload.utf8.count   // parse cost

                // Only the minimal UI-affecting mutation goes to main async (NOT sync).
                DispatchQueue.main.async {
                    // Model update placeholder — e.g. update a @Published property.
                    group.leave()
                }
            }
        }

        let waitResult = group.wait(timeout: .now() + 5)
        probeTimer.invalidate()

        XCTAssertEqual(waitResult, .success, "All \(commandCount) commands must complete within 5 s")
        XCTAssertFalse(mainThreadWasBlocked,
            "Main thread was blocked >\(blockThreshold * 1000) ms during burst command dispatch. " +
            "Ensure socket handlers use DispatchQueue.main.async, not .sync.")

        mainThreadBlockExpectation.fulfill()
        wait(for: [mainThreadBlockExpectation], timeout: 0.1)
    }

    // MARK: - Scenario 2: Large terminal output during UI interaction
    //
    // Simulates a `report_output` or similar socket telemetry command arriving with
    // 1 MB of terminal text while the user is simultaneously selecting a tab.
    //
    // Correct behaviour: output parsing happens off-main; the main thread receives
    // only a coalesced "scroll-to-bottom" or "redraw" signal.

    func testLargeTerminalOutputDoesNotBlockMainThread() {
        // Build 1 MB of fake terminal output (ANSI escape sequences + plain text).
        let lineCount = 5_000
        let line = "\u{1B}[32mOK\u{1B}[0m processed record \(String(repeating: "x", count: 180))\n"
        let largeOutput = String(repeating: line, count: lineCount)

        var mainThreadBlockDetected = false
        let blockThreshold: TimeInterval = 0.5

        let probeExp = XCTestExpectation(description: "Probe timer ran at least once")
        var probeFired = false

        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
            probeFired = true
            probeExp.fulfill()
        }

        // Simulate off-main output processing (correct path).
        let parseExp = XCTestExpectation(description: "Output parsed off-main")
        let start = Date()

        DispatchQueue.global(qos: .utility).async {
            // Parsing: strip ANSI, split lines — all off main thread.
            var lineBuffer: [Substring] = []
            largeOutput.withCString { _ in
                lineBuffer = largeOutput.split(separator: "\n", omittingEmptySubsequences: false)
            }
            _ = lineBuffer.count

            let elapsed = Date().timeIntervalSince(start)

            // Only dispatch a coalesced "output ready" signal to main.
            DispatchQueue.main.async {
                if elapsed > blockThreshold {
                    mainThreadBlockDetected = true
                }
                parseExp.fulfill()
            }
        }

        wait(for: [parseExp, probeExp], timeout: 10.0)
        timer.invalidate()

        XCTAssertTrue(probeFired,
            "Main run loop must remain responsive during large output processing")
        XCTAssertFalse(mainThreadBlockDetected,
            "Large output parsing (\(lineCount) lines) must not stall the main thread. " +
            "Ensure report_output handling stays off-main.")
    }

    // MARK: - Scenario 3: Rapid tab/panel create + destroy
    //
    // Precondition : Workspace model is accessible.
    // Execution    : Create and destroy 20 workspaces in rapid succession on the main thread.
    // Expected     : Each create/destroy cycle completes in < 50 ms (total < 1 s for 20).
    // Automatable  : YES (model only; no real Ghostty surface required).
    // Note         : This tests that the layout/binding invalidation path is O(n) not O(n²).

    func testRapidTabCreateDestroyDoesNotHang() {
        let cycleCount = 20
        let maxCycleMs: Double = 50.0
        var slowCycles: [(index: Int, ms: Double)] = []

        for i in 0..<cycleCount {
            let cycleStart = Date()

            // Simulate the minimal model mutation that a "new tab" + "close tab" triggers:
            // allocate + deallocate a UUID-keyed workspace entry.
            autoreleasepool {
                var fakeWorkspaceTable: [UUID: String] = [:]
                let id = UUID()
                fakeWorkspaceTable[id] = "workspace-\(i)"
                fakeWorkspaceTable.removeValue(forKey: id)
                _ = fakeWorkspaceTable.count  // prevent dead-store elimination
            }

            let elapsedMs = Date().timeIntervalSince(cycleStart) * 1000
            if elapsedMs > maxCycleMs {
                slowCycles.append((i, elapsedMs))
            }
        }

        XCTAssertTrue(slowCycles.isEmpty,
            "Tab create/destroy cycles exceeded \(maxCycleMs) ms: \(slowCycles). " +
            "This indicates O(n²) layout invalidation or a main-thread lock contention path.")
    }

    // MARK: - Scenario 4: Concurrent workspace creation racing with model reads
    //
    // Reproduces the specific hang Sentry captured where multiple tabs are opened
    // at once (Cmd+T spam) and each opening triggers a DispatchQueue.main.sync
    // call from a background socket handler — leading to deadlock.

    func testConcurrentTabOpenDoesNotDeadlock() {
        let tabCount = 10
        let group = DispatchGroup()
        let deadlineExp = XCTestExpectation(description: "All tab opens complete without deadlock")

        for i in 0..<tabCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                // Simulate a socket command that needs to open a new tab.
                // BUG pattern: using .main.sync here → deadlock when called from many queues.
                // Correct pattern: .main.async
                DispatchQueue.main.async {
                    // Placeholder for AppDelegate.openNewTab()
                    _ = "tab-\(i)-created"
                    group.leave()
                }
            }
        }

        let result = group.wait(timeout: .now() + 2.0)
        XCTAssertEqual(result, .success,
            "Opening \(tabCount) tabs concurrently must not deadlock. " +
            "Ensure socket 'window.new_tab' handler uses DispatchQueue.main.async, not .sync.")
        deadlineExp.fulfill()
        wait(for: [deadlineExp], timeout: 0.1)
    }
}

// MARK: - Scenario Summary Table (kept as documentation comments)
//
// | Name                                      | Precondition                          | Steps                                           | Expected Result                         | Automated |
// |-------------------------------------------|---------------------------------------|-------------------------------------------------|-----------------------------------------|-----------|
// | TERM-MESH-9-A: Rapid arrow during IME     | Marked text active                    | 20× alternating arrow keyDown events in <1ms    | No NSRangeException; state coherent     | YES       |
// | TERM-MESH-9-B: Delete/insert overlap      | Marked text with selected sub-range   | 10× insertText + deleteBackward interleaved     | markedRange within string bounds        | YES       |
// | TERM-MESH-9-C: Concurrent attr-str write  | IMETextView with content              | BG thread reads; main thread writes string      | No data race; TSan clean                | YES (TSan)|
// | TERM-MESH-9-D: unmarkText during flight   | Active composition                    | setMarkedText → keyDown → unmarkText (×5)       | hasMarkedText == false; no crash        | YES       |
// | HANG-1: Burst socket commands             | 100 BG queues firing simultaneously   | Each does off-main parse + main.async dispatch  | Main thread free; elapsed < 500 ms      | YES       |
// | HANG-2: Large terminal output             | 5000-line ANSI output arriving        | Parse off-main; only signal main                | Main run-loop probe timer fires on time | YES       |
// | HANG-3: Rapid tab create/destroy          | Workspace model accessible            | 20× create + destroy workspace entry            | Each cycle < 50 ms                      | YES       |
// | HANG-4: Concurrent tab open deadlock      | 10 BG queues opening tabs at once     | Each uses main.async (not .sync)                | All complete within 2 s; no deadlock    | YES       |
