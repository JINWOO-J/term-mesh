import AppKit

extension NSAlert {
    /// Present as sheet on the key/main window if available, otherwise fall back to runModal.
    /// For Type A alerts (OK-only), call without completion.
    /// For Type B/C alerts, use the completion handler to process the response.
    /// If the target window already has an attached sheet, this call is a no-op to prevent
    /// duplicate/stacked sheets (e.g. repeated Cmd+Q warnings).
    func presentAsSheet(for window: NSWindow? = nil, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        let targetWindow = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let targetWindow {
            guard targetWindow.attachedSheet == nil else { return }
            beginSheetModal(for: targetWindow) { response in
                completion?(response)
            }
        } else {
            let response = runModal()
            completion?(response)
        }
    }
}

extension NSOpenPanel {
    /// Present as sheet on the key/main window if available, otherwise fall back to runModal.
    func presentAsSheet(for window: NSWindow? = nil, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let targetWindow = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        if let targetWindow {
            beginSheetModal(for: targetWindow, completionHandler: completion)
        } else {
            let response = runModal()
            completion(response)
        }
    }
}
