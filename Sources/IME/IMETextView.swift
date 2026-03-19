import AppKit

/// Custom NSTextView that intercepts Enter (submit), Shift+Enter (newline),
/// Up/Down (history navigation), and Escape (cancel).
final class IMETextView: NSTextView {
    var submitHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?
    var ctrlCHandler: (() -> Void)?
    var historyUpHandler: (() -> Void)?
    var historyDownHandler: (() -> Void)?
    var historySearchHandler: (() -> Void)?
    var composingHandler: ((Bool) -> Void)?
    /// Send a raw key event (keycode + mods) directly to the terminal surface,
    /// bypassing text input.  Used for Shift+Tab, Ctrl+Tab, and similar TUI shortcuts.
    var sendKeyHandler: ((_ keycode: UInt16, _ mods: UInt32) -> Void)?
    /// Submit current text and close the IME box in one action (Cmd+Enter).
    var submitAndCloseHandler: (() -> Void)?
    /// Tracks the last ESC keypress time for double-ESC detection.
    private var lastEscapeTime: TimeInterval = 0
    /// Double-ESC threshold in seconds.
    private let doubleEscapeThreshold: TimeInterval = 0.4

    // MARK: - Focus activation

    override func mouseDown(with event: NSEvent) {
        // When the user clicks the IME box, ensure the app is activated and the
        // window is key — so typing works even when another app had focus.
        if let w = window, !w.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
        super.mouseDown(with: event)
    }

    // MARK: - Key equivalents

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+C: if IME has no text selection but a terminal in the window does, copy the
        // terminal selection. This lets users mouse-select terminal text while IME is active
        // and copy it without losing IME focus.
        if event.keyCode == 8 && flags == .command && selectedRange().length == 0 {
            if let surfaceView = Self.findTerminalSurfaceWithSelection(in: window) {
                surfaceView.copy(nil)
                return true
            }
        }

        return super.performKeyEquivalent(with: event)
    }

    /// Walk the window's view hierarchy to find a GhosttyNSView that has an active selection.
    private static func findTerminalSurfaceWithSelection(in window: NSWindow?) -> GhosttyNSView? {
        guard let contentView = window?.contentView else { return nil }
        return findGhosttyViewWithSelection(in: contentView)
    }

    private static func findGhosttyViewWithSelection(in view: NSView) -> GhosttyNSView? {
        if let gv = view as? GhosttyNSView,
           let surface = gv.surface,
           ghostty_surface_has_selection(surface) {
            return gv
        }
        for sub in view.subviews {
            if let found = findGhosttyViewWithSelection(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        // Cmd+V → paste (ensure image paste works even if menu dispatch is intercepted)
        if event.keyCode == 9 && event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
            paste(nil)
            return
        }
        // Cmd+Enter → submit and close IME box
        if event.keyCode == 36 && event.modifierFlags.contains(.command) {
            if hasMarkedText() {
                super.keyDown(with: event)
                if !hasMarkedText() {
                    if string.hasSuffix("\n") {
                        string = String(string.dropLast())
                    }
                    submitAndCloseHandler?()
                }
                return
            }
            submitAndCloseHandler?()
            return
        }
        // Enter without Shift → submit (guard: let IME commit composed text first)
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
            if hasMarkedText() {
                super.keyDown(with: event)
                // IME confirmed composition via super.keyDown. If no longer composing,
                // strip any trailing newline that NSTextView's insertNewline added,
                // then submit immediately so the user doesn't need a second Enter.
                if !hasMarkedText() {
                    if string.hasSuffix("\n") {
                        string = String(string.dropLast())
                    }
                    submitHandler?()
                }
                return
            }
            submitHandler?()
            return
        }
        // Shift+Enter → insert newline (guard: let IME handle if composing)
        if event.keyCode == 36 && event.modifierFlags.contains(.shift) {
            if hasMarkedText() {
                super.keyDown(with: event)
                return
            }
            insertNewline(nil)
            return
        }
        // Ctrl+C → send ETX interrupt + key event (enables Claude double Ctrl+C exit)
        if event.keyCode == 8 && event.modifierFlags.contains(.control) {
            ctrlCHandler?()
            return
        }
        // Ctrl+A → move to beginning of line (readline)
        if event.keyCode == 0 && event.modifierFlags.contains(.control) {
            moveToBeginningOfLine(nil)
            return
        }
        // Ctrl+E → move to end of line (readline)
        if event.keyCode == 14 && event.modifierFlags.contains(.control) {
            moveToEndOfLine(nil)
            return
        }
        // Ctrl+K → delete to end of paragraph (readline)
        if event.keyCode == 40 && event.modifierFlags.contains(.control) {
            deleteToEndOfParagraph(nil)
            return
        }
        // Ctrl+W → delete word backward (readline)
        if event.keyCode == 13 && event.modifierFlags.contains(.control) {
            deleteWordBackward(nil)
            return
        }
        // Ctrl+J → alternative submit (same as Enter, useful during IME composing)
        if event.keyCode == 38 && event.modifierFlags.contains(.control) {
            if hasMarkedText() {
                super.keyDown(with: event)
                if !hasMarkedText() {
                    if string.hasSuffix("\n") {
                        string = String(string.dropLast())
                    }
                    submitHandler?()
                }
                return
            }
            submitHandler?()
            return
        }
        // Ctrl+L → forward to terminal (Claude Code: clear conversation)
        if event.keyCode == 37 && event.modifierFlags.contains(.control) {
            sendKeyHandler?(event.keyCode, UInt32(GHOSTTY_MODS_CTRL.rawValue))
            return
        }
        // Ctrl+R → reverse history search
        if event.keyCode == 15 && event.modifierFlags.contains(.control) {
            historySearchHandler?()
            return
        }
        // Ctrl+Backspace → Ctrl+U (delete line) in terminal
        if event.keyCode == 51 && event.modifierFlags.contains(.control) {
            sendKeyHandler?(32, UInt32(GHOSTTY_MODS_CTRL.rawValue))
            return
        }
        // Shift+Tab → forward to terminal (Claude Code uses this for accepting suggestions)
        if event.keyCode == 48 && event.modifierFlags.contains(.shift) {
            sendKeyHandler?(event.keyCode, UInt32(GHOSTTY_MODS_SHIFT.rawValue))
            return
        }
        // Cmd+Escape → close IME box
        if event.keyCode == 53 && event.modifierFlags.contains(.command) {
            cancelHandler?()
            return
        }
        // Escape handling: double-ESC → Ctrl+C to terminal, single ESC → forward ESC to terminal
        if event.keyCode == 53 {
            let now = CACurrentMediaTime()
            if (now - lastEscapeTime) < doubleEscapeThreshold {
                // Double-ESC: send Ctrl+C (keycode 8 = 'c', with ctrl mod) to cancel running command
                sendKeyHandler?(8, UInt32(GHOSTTY_MODS_CTRL.rawValue))
                lastEscapeTime = 0  // reset to avoid triple-trigger
            } else {
                // Single ESC: forward to terminal
                sendKeyHandler?(event.keyCode, 0)
                lastEscapeTime = now
            }
            return
        }
        // Option+ArrowUp → forward plain Up arrow to terminal (e.g. Claude menu navigation)
        if event.keyCode == 126 && event.modifierFlags.contains(.option) && !hasMarkedText() {
            sendKeyHandler?(event.keyCode, 0)
            return
        }
        // Option+ArrowDown → forward plain Down arrow to terminal
        if event.keyCode == 125 && event.modifierFlags.contains(.option) && !hasMarkedText() {
            sendKeyHandler?(event.keyCode, 0)
            return
        }
        // Option+ArrowLeft → forward Alt+Left to terminal (word-level cursor movement)
        if event.keyCode == 123 && event.modifierFlags.contains(.option) && !hasMarkedText() {
            sendKeyHandler?(event.keyCode, UInt32(GHOSTTY_MODS_ALT.rawValue))
            return
        }
        // Option+ArrowRight → forward Alt+Right to terminal (word-level cursor movement)
        if event.keyCode == 124 && event.modifierFlags.contains(.option) && !hasMarkedText() {
            sendKeyHandler?(event.keyCode, UInt32(GHOSTTY_MODS_ALT.rawValue))
            return
        }
        // Option+Tab → forward Meta+Tab to terminal (e.g. Claude thinking toggle)
        if event.keyCode == 48 && event.modifierFlags.contains(.option) && !hasMarkedText() {
            sendKeyHandler?(event.keyCode, UInt32(GHOSTTY_MODS_ALT.rawValue))
            return
        }
        // Plain Tab → forward to terminal (e.g. shell completion, Claude tab accept)
        if event.keyCode == 48 && !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.command) && !hasMarkedText() {
            sendKeyHandler?(event.keyCode, 0)
            return
        }
        // ArrowUp → history (when cursor is on first line and not composing IME)
        if event.keyCode == 126 && !hasMarkedText() && isCursorOnFirstLine() {
            historyUpHandler?()
            return
        }
        // ArrowDown → history (when cursor is on last line and not composing IME)
        if event.keyCode == 125 && !hasMarkedText() && isCursorOnLastLine() {
            historyDownHandler?()
            return
        }
        super.keyDown(with: event)
    }

    override func deleteBackward(_ sender: Any?) {
        if string.isEmpty {
            // IME bar is empty → forward Backspace to terminal
            sendKeyHandler?(51, 0)
            return
        }
        super.deleteBackward(sender)
    }

    override func deleteForward(_ sender: Any?) {
        if string.isEmpty {
            // IME bar is empty → forward Delete (Fn+Backspace) to terminal
            sendKeyHandler?(117, 0)
            return
        }
        super.deleteForward(sender)
    }

    private func isCursorOnFirstLine() -> Bool {
        let loc = selectedRange().location
        let str = string as NSString
        let firstNewline = str.range(of: "\n").location
        return firstNewline == NSNotFound || loc <= firstNewline
    }

    private func isCursorOnLastLine() -> Bool {
        let loc = selectedRange().location
        let str = string as NSString
        let lastNewline = str.range(of: "\n", options: .backwards).location
        return lastNewline == NSNotFound || loc > lastNewline
    }

    // MARK: - Paste (image → inline thumbnail)

    /// Pasted image attachments and their /tmp file paths.
    var imageAttachments: [(attachment: NSTextAttachment, path: String)] = []

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if pb.string(forType: .string) != nil || pb.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text")) != nil {
            pasteAsPlainText(sender)
            return
        }
        if let path = GhosttyPasteboardHelper.saveClipboardImageToTempFile(from: pb),
           let image = NSImage(contentsOfFile: path) {
            let attachment = NSTextAttachment()
            let maxHeight: CGFloat = 48
            let scale = min(maxHeight / image.size.height, 1.0)
            let thumbSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let cell = NSTextAttachmentCell(imageCell: image)
            cell.image?.size = thumbSize
            attachment.attachmentCell = cell

            let attrStr = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
            attrStr.append(NSAttributedString(string: " ",
                attributes: [.font: font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)]))

            textStorage?.insert(attrStr, at: selectedRange().location)
            setSelectedRange(NSRange(location: selectedRange().location + attrStr.length, length: 0))
            imageAttachments.append((attachment: attachment, path: path))
            delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
            return
        }
        pasteAsPlainText(sender)
    }

    /// Returns text with image attachments replaced by their file paths.
    func submittableText() -> String {
        guard let storage = textStorage, !imageAttachments.isEmpty else { return string }
        var result = ""
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
            if let att = attrs[.attachment] as? NSTextAttachment,
               let entry = imageAttachments.first(where: { $0.attachment === att }) {
                result += entry.path
            } else {
                result += (storage.string as NSString).substring(with: range)
            }
        }
        return result
    }

    // MARK: - IME composition tracking

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        composingHandler?(hasMarkedText())
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        composingHandler?(false)
    }

    // MARK: - Rainbow keyword coloring

    private static let rainbowKeywords: [String] = [
        "ULTRATHINK", "MEGATHINK", "IMPORTANT", "CRITICAL", "RAINBOW",
    ]

    private static let rainbowColors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .cyan, .systemBlue, .systemPurple,
    ]

    private var isApplyingRainbow = false

    override func didChangeText() {
        super.didChangeText()
        guard !isApplyingRainbow, !hasMarkedText() else { return }
        isApplyingRainbow = true
        applyRainbowKeywords()
        isApplyingRainbow = false
    }

    /// Scans committed text for rainbow keywords and applies per-character gradient colors.
    /// Safe to call externally (e.g. after programmatic `string =` assignment).
    /// Skips any active IME composing (marked) range.
    func applyRainbowKeywords() {
        guard let storage = textStorage else { return }
        let len = storage.length
        guard len > 0 else { return }
        let markedRange = self.markedRange()
        let fullString = storage.string as NSString

        storage.beginEditing()

        // Reset foreground color to default outside the marked (composing) range
        if markedRange.location == NSNotFound || markedRange.length == 0 {
            storage.addAttribute(.foregroundColor, value: NSColor.textColor,
                                 range: NSRange(location: 0, length: len))
        } else {
            if markedRange.location > 0 {
                storage.addAttribute(.foregroundColor, value: NSColor.textColor,
                                     range: NSRange(location: 0, length: markedRange.location))
            }
            let afterLoc = markedRange.location + markedRange.length
            if afterLoc < len {
                storage.addAttribute(.foregroundColor, value: NSColor.textColor,
                                     range: NSRange(location: afterLoc, length: len - afterLoc))
            }
        }

        // Apply rainbow colors per character for each keyword match
        for keyword in IMETextView.rainbowKeywords {
            var searchRange = NSRange(location: 0, length: len)
            while searchRange.length > 0 {
                let found = fullString.range(of: keyword, options: .caseInsensitive, range: searchRange)
                guard found.location != NSNotFound else { break }
                let nextLoc = found.location + found.length
                searchRange = NSRange(location: nextLoc, length: len - nextLoc)

                // Skip if overlapping with active IME composing range
                if markedRange.location != NSNotFound && markedRange.length > 0,
                   NSIntersectionRange(found, markedRange).length > 0 { continue }

                for i in 0..<found.length {
                    let charRange = NSRange(location: found.location + i, length: 1)
                    let color = IMETextView.rainbowColors[i % IMETextView.rainbowColors.count]
                    storage.addAttribute(.foregroundColor, value: color, range: charRange)
                }
            }
        }

        storage.endEditing()
    }
}
