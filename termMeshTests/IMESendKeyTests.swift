import XCTest
import AppKit

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

// Keycode constants (mirroring IMETextView's private VK enum)
private enum VK {
    static let u: UInt16           = 0x20  // 32  — Ctrl+U = clear line
    static let l: UInt16           = 0x25  // 37  — Ctrl+L = clear screen
    static let c: UInt16           = 0x08  //  8  — Ctrl+C
    static let w: UInt16           = 0x0D  // 13  — Ctrl+W = delete word
    static let a: UInt16           = 0x00  //  0  — Ctrl+A = beginning of line
    static let e: UInt16           = 0x0E  // 14  — Ctrl+E = end of line
    static let k: UInt16           = 0x28  // 40  — Ctrl+K = kill to end
    static let j: UInt16           = 0x26  // 38  — Ctrl+J = submit
    static let tab: UInt16         = 0x30  // 48
    static let delete: UInt16      = 0x33  // 51  — Backspace
    static let escape: UInt16      = 0x35  // 53
    static let forwardDelete: UInt16 = 0x75 // 117 — Fn+Delete
    static let returnKey: UInt16   = 0x24  // 36
}

/// GHOSTTY mods raw values (from ghostty C API)
private let ghosttyModsCtrl: UInt32  = 2   // 1 << 1
private let ghosttyModsShift: UInt32 = 1   // 1 << 0
private let ghosttyModsAlt: UInt32   = 4   // 1 << 2

/// Tests for IMETextView keyboard shortcuts that forward keys to the terminal
/// via sendKeyHandler. Extends the existing IMEArrowKeyTests coverage to include
/// Ctrl+U, Ctrl+L, Ctrl+Backspace, Tab variants, Escape, and delete-when-empty.
final class IMESendKeyTests: XCTestCase {

    private var sut: IMETextView!
    private var capturedKeys: [(keycode: UInt16, mods: UInt32)] = []
    private var submitCalled = false
    private var cancelCalled = false
    private var ctrlCCalled = false

    override func setUp() {
        super.setUp()
        sut = IMETextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        capturedKeys = []
        submitCalled = false
        cancelCalled = false
        ctrlCCalled = false

        sut.sendKeyHandler = { [weak self] keycode, mods in
            self?.capturedKeys.append((keycode: keycode, mods: mods))
        }
        sut.submitHandler = { [weak self] in
            self?.submitCalled = true
        }
        sut.cancelHandler = { [weak self] in
            self?.cancelCalled = true
        }
        sut.ctrlCHandler = { [weak self] in
            self?.ctrlCCalled = true
        }
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeKeyDownEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
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

    // MARK: - Ctrl+U (empty → forward to terminal, non-empty → clear IME text)

    func testCtrlUEmptyIMEForwardsToTerminal() {
        XCTAssertTrue(sut.string.isEmpty, "Precondition: IME should be empty")

        guard let event = makeKeyDownEvent(keyCode: VK.u, modifiers: [.control]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(capturedKeys.count, 1, "Should send exactly one key event")
        XCTAssertEqual(capturedKeys.first?.keycode, VK.u, "Should send 'u' keycode")
        XCTAssertEqual(capturedKeys.first?.mods, ghosttyModsCtrl, "Should send Ctrl modifier")
    }

    func testCtrlUNonEmptyIMEClearsText() {
        sut.string = "some text to clear"

        guard let event = makeKeyDownEvent(keyCode: VK.u, modifiers: [.control]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertTrue(sut.string.isEmpty, "Ctrl+U should clear all IME text")
        XCTAssertTrue(capturedKeys.isEmpty, "Should NOT forward to terminal when clearing text")
    }

    // MARK: - Ctrl+L (always forward to terminal)

    func testCtrlLForwardsToTerminal() {
        guard let event = makeKeyDownEvent(keyCode: VK.l, modifiers: [.control]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(capturedKeys.count, 1, "Ctrl+L should always forward to terminal")
        XCTAssertEqual(capturedKeys.first?.keycode, VK.l)
        XCTAssertEqual(capturedKeys.first?.mods, ghosttyModsCtrl)
    }

    // MARK: - Ctrl+Backspace (sends Ctrl+U to terminal)

    func testCtrlBackspaceSendsCtrlUToTerminal() {
        guard let event = makeKeyDownEvent(keyCode: VK.delete, modifiers: [.control]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(capturedKeys.count, 1)
        XCTAssertEqual(capturedKeys.first?.keycode, VK.u,
                       "Ctrl+Backspace should send Ctrl+U keycode")
        XCTAssertEqual(capturedKeys.first?.mods, ghosttyModsCtrl)
    }

    // MARK: - Tab variants

    func testShiftTabForwardsToTerminal() {
        guard let event = makeKeyDownEvent(keyCode: VK.tab, modifiers: [.shift]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(capturedKeys.count, 1, "Shift+Tab should forward to terminal")
        XCTAssertEqual(capturedKeys.first?.keycode, VK.tab)
        XCTAssertEqual(capturedKeys.first?.mods, ghosttyModsShift)
    }

    func testPlainTabEmptyIMEForwardsToTerminal() {
        XCTAssertTrue(sut.string.isEmpty)

        guard let event = makeKeyDownEvent(keyCode: VK.tab) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(capturedKeys.count, 1, "Plain Tab with empty IME should forward to terminal")
        XCTAssertEqual(capturedKeys.first?.keycode, VK.tab)
        XCTAssertEqual(capturedKeys.first?.mods, 0)
    }

    func testOptionTabForwardsAltTabToTerminal() {
        guard let event = makeKeyDownEvent(keyCode: VK.tab, modifiers: [.option]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(capturedKeys.count, 1, "Option+Tab should forward as Alt+Tab")
        XCTAssertEqual(capturedKeys.first?.keycode, VK.tab)
        XCTAssertEqual(capturedKeys.first?.mods, ghosttyModsAlt)
    }

    // MARK: - Escape

    func testSingleEscapeForwardsToTerminal() {
        guard let event = makeKeyDownEvent(keyCode: VK.escape) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(capturedKeys.count, 1, "Single ESC should forward to terminal")
        XCTAssertEqual(capturedKeys.first?.keycode, VK.escape)
        XCTAssertEqual(capturedKeys.first?.mods, 0)
    }

    func testDoubleEscapeSendsCtrlCToTerminal() {
        guard let event1 = makeKeyDownEvent(keyCode: VK.escape),
              let event2 = makeKeyDownEvent(keyCode: VK.escape) else {
            return XCTFail("Failed to create synthetic key events")
        }

        // First ESC
        sut.keyDown(with: event1)
        XCTAssertEqual(capturedKeys.count, 1, "First ESC should forward")

        // Second ESC within threshold
        sut.keyDown(with: event2)
        XCTAssertEqual(capturedKeys.count, 2, "Second ESC should send Ctrl+C")
        XCTAssertEqual(capturedKeys.last?.keycode, VK.c, "Double-ESC should send 'c' keycode")
        XCTAssertEqual(capturedKeys.last?.mods, ghosttyModsCtrl, "Double-ESC should send Ctrl mod")
    }

    func testCmdEscapeCallsCancelHandler() {
        guard let event = makeKeyDownEvent(keyCode: VK.escape, modifiers: [.command]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertTrue(cancelCalled, "Cmd+Escape should call cancelHandler")
        XCTAssertTrue(capturedKeys.isEmpty, "Cmd+Escape should NOT forward to terminal")
    }

    // MARK: - Delete when empty (forward to terminal)

    func testBackspaceEmptyIMEForwardsToTerminal() {
        XCTAssertTrue(sut.string.isEmpty)

        sut.deleteBackward(nil)

        XCTAssertEqual(capturedKeys.count, 1, "Backspace on empty IME should forward to terminal")
        XCTAssertEqual(capturedKeys.first?.keycode, VK.delete)
        XCTAssertEqual(capturedKeys.first?.mods, 0)
    }

    func testBackspaceNonEmptyIMEDoesNotForward() {
        sut.string = "text"

        sut.deleteBackward(nil)

        XCTAssertTrue(capturedKeys.isEmpty,
                      "Backspace on non-empty IME should delete in IME, not forward")
    }

    func testForwardDeleteEmptyIMEForwardsToTerminal() {
        XCTAssertTrue(sut.string.isEmpty)

        sut.deleteForward(nil)

        XCTAssertEqual(capturedKeys.count, 1, "Forward delete on empty IME should forward")
        XCTAssertEqual(capturedKeys.first?.keycode, VK.forwardDelete)
        XCTAssertEqual(capturedKeys.first?.mods, 0)
    }

    // MARK: - Ctrl+C calls ctrlCHandler

    func testCtrlCCallsCtrlCHandler() {
        guard let event = makeKeyDownEvent(keyCode: VK.c, modifiers: [.control]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertTrue(ctrlCCalled, "Ctrl+C should call ctrlCHandler")
        XCTAssertTrue(capturedKeys.isEmpty, "Ctrl+C should NOT use sendKeyHandler")
    }

    // MARK: - Ctrl+J calls submitHandler

    func testCtrlJCallsSubmitHandler() {
        guard let event = makeKeyDownEvent(keyCode: VK.j, modifiers: [.control]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertTrue(submitCalled, "Ctrl+J should call submitHandler")
    }

    // MARK: - Readline editing (Ctrl+A/E/K/W)

    func testCtrlAMovesToBeginningOfLine() {
        sut.string = "hello world"
        // Position cursor at end
        sut.setSelectedRange(NSRange(location: sut.string.count, length: 0))

        guard let event = makeKeyDownEvent(keyCode: VK.a, modifiers: [.control]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(sut.selectedRange().location, 0,
                       "Ctrl+A should move cursor to beginning of line")
        XCTAssertTrue(capturedKeys.isEmpty, "Ctrl+A should NOT forward to terminal")
    }

    func testCtrlEMovesToEndOfLine() {
        sut.string = "hello world"
        // Position cursor at beginning
        sut.setSelectedRange(NSRange(location: 0, length: 0))

        guard let event = makeKeyDownEvent(keyCode: VK.e, modifiers: [.control]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        XCTAssertEqual(sut.selectedRange().location, sut.string.count,
                       "Ctrl+E should move cursor to end of line")
    }

    func testCtrlWDeletesWordBackward() {
        sut.string = "hello world"
        sut.setSelectedRange(NSRange(location: sut.string.count, length: 0))

        guard let event = makeKeyDownEvent(keyCode: VK.w, modifiers: [.control]) else {
            return XCTFail("Failed to create synthetic key event")
        }
        sut.keyDown(with: event)

        // "world" should be deleted
        XCTAssertFalse(sut.string.contains("world"),
                       "Ctrl+W should delete the last word")
        XCTAssertTrue(capturedKeys.isEmpty, "Ctrl+W should NOT forward to terminal")
    }
}
