import AppKit
import Foundation
import WebKit
import Bonsplit

extension TerminalController {
    func v2BrowserEnsureTelemetryHooks(surfaceId: UUID, browserPanel: BrowserPanel) {
        let script = """
        (() => {
          if (window.__termMeshHooksInstalled) return true;
          window.__termMeshHooksInstalled = true;

          window.__termMeshConsoleLog = window.__termMeshConsoleLog || [];
          const __pushConsole = (level, args) => {
            try {
              const text = Array.from(args || []).map((x) => {
                if (typeof x === 'string') return x;
                try { return JSON.stringify(x); } catch (_) { return String(x); }
              }).join(' ');
              window.__termMeshConsoleLog.push({ level, text, timestamp_ms: Date.now() });
              if (window.__termMeshConsoleLog.length > 512) {
                window.__termMeshConsoleLog.splice(0, window.__termMeshConsoleLog.length - 512);
              }
            } catch (_) {}
          };

          const methods = ['log', 'info', 'warn', 'error', 'debug'];
          for (const m of methods) {
            const orig = (window.console && window.console[m]) ? window.console[m].bind(window.console) : null;
            window.console[m] = function(...args) {
              __pushConsole(m, args);
              if (orig) return orig(...args);
            };
          }

          window.__termMeshErrorLog = window.__termMeshErrorLog || [];
          window.addEventListener('error', (ev) => {
            try {
              const message = String((ev && ev.message) || '');
              const source = String((ev && ev.filename) || '');
              const line = Number((ev && ev.lineno) || 0);
              const col = Number((ev && ev.colno) || 0);
              window.__termMeshErrorLog.push({ message, source, line, column: col, timestamp_ms: Date.now() });
              if (window.__termMeshErrorLog.length > 512) {
                window.__termMeshErrorLog.splice(0, window.__termMeshErrorLog.length - 512);
              }
            } catch (_) {}
          });
          window.addEventListener('unhandledrejection', (ev) => {
            try {
              const reason = ev && ev.reason;
              const message = typeof reason === 'string' ? reason : (reason && reason.message ? String(reason.message) : String(reason));
              window.__termMeshErrorLog.push({ message, source: 'unhandledrejection', line: 0, column: 0, timestamp_ms: Date.now() });
              if (window.__termMeshErrorLog.length > 512) {
                window.__termMeshErrorLog.splice(0, window.__termMeshErrorLog.length - 512);
              }
            } catch (_) {}
          });

          window.__termMeshDialogQueue = window.__termMeshDialogQueue || [];
          window.__termMeshDialogDefaults = window.__termMeshDialogDefaults || { confirm: false, prompt: null };
          const __pushDialog = (type, message, defaultText) => {
            window.__termMeshDialogQueue.push({
              type,
              message: String(message || ''),
              default_text: defaultText == null ? null : String(defaultText),
              timestamp_ms: Date.now()
            });
            if (window.__termMeshDialogQueue.length > 128) {
              window.__termMeshDialogQueue.splice(0, window.__termMeshDialogQueue.length - 128);
            }
          };

          window.alert = function(message) {
            __pushDialog('alert', message, null);
          };
          window.confirm = function(message) {
            __pushDialog('confirm', message, null);
            return !!window.__termMeshDialogDefaults.confirm;
          };
          window.prompt = function(message, defaultValue) {
            __pushDialog('prompt', message, defaultValue == null ? null : defaultValue);
            const v = window.__termMeshDialogDefaults.prompt;
            if (v === null || v === undefined) {
              return defaultValue == null ? '' : String(defaultValue);
            }
            return String(v);
          };

          return true;
        })()
        """

        _ = v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0)
    }

    func v2BrowserDialogRespond(params: [String: Any], accept: Bool) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            let text = v2String(params, "text") ?? v2String(params, "prompt_text")
            let acceptLiteral = accept ? "true" : "false"
            let textLiteral = text.map(v2JSONLiteral) ?? "null"
            let script = """
            (() => {
              const q = window.__termMeshDialogQueue || [];
              if (!q.length) return { ok: false, error: 'not_found' };
              const entry = q.shift();
              if (entry.type === 'confirm') {
                window.__termMeshDialogDefaults = window.__termMeshDialogDefaults || { confirm: false, prompt: null };
                window.__termMeshDialogDefaults.confirm = \(acceptLiteral);
              }
              if (entry.type === 'prompt') {
                window.__termMeshDialogDefaults = window.__termMeshDialogDefaults || { confirm: false, prompt: null };
                if (\(acceptLiteral)) {
                  window.__termMeshDialogDefaults.prompt = \(textLiteral);
                } else {
                  window.__termMeshDialogDefaults.prompt = null;
                }
              }
              return { ok: true, dialog: entry, remaining: q.length };
            })()
            """

            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    let pending = v2BrowserPendingDialogs(surfaceId: surfaceId)
                    return .err(code: "not_found", message: "No pending dialog", data: ["pending": pending])
                }

                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "accepted": accept,
                    "dialog": v2NormalizeJSValue(dict["dialog"]),
                    "remaining": v2OrNull(dict["remaining"])
                ])
            }
        }
    }

    func v2BrowserDownloadWait(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, _ in
            let timeoutMs = max(1, v2Int(params, "timeout_ms") ?? v2Int(params, "timeout") ?? 10_000)
            let timeout = Double(timeoutMs) / 1000.0
            let path = v2String(params, "path")

            if let path {
                let deadline = Date().addingTimeInterval(timeout)
                let fm = FileManager.default
                while Date() < deadline {
                    if fm.fileExists(atPath: path),
                       let attrs = try? fm.attributesOfItem(atPath: path),
                       let size = attrs[.size] as? NSNumber,
                       size.intValue > 0 {
                        return .ok([
                            "workspace_id": ws.id.uuidString,
                            "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                            "surface_id": surfaceId.uuidString,
                            "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                            "path": path,
                            "downloaded": true
                        ])
                    }
                    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                }
                return .err(code: "timeout", message: "Timed out waiting for download file", data: ["path": path, "timeout_ms": timeoutMs])
            }

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let entries = v2BrowserDownloadEventsBySurface[surfaceId] ?? []
                if let first = entries.first {
                    var remaining = entries
                    remaining.removeFirst()
                    v2BrowserDownloadEventsBySurface[surfaceId] = remaining
                    return .ok([
                        "workspace_id": ws.id.uuidString,
                        "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                        "surface_id": surfaceId.uuidString,
                        "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                        "download": first
                    ])
                }
                _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            return .err(code: "timeout", message: "No download event observed", data: ["timeout_ms": timeoutMs])
        }
    }

    func v2BrowserCookieDict(_ cookie: HTTPCookie) -> [String: Any] {
        var out: [String: Any] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.isSecure,
            "session_only": cookie.isSessionOnly
        ]
        if let expiresDate = cookie.expiresDate {
            out["expires"] = Int(expiresDate.timeIntervalSince1970)
        } else {
            out["expires"] = NSNull()
        }
        return out
    }

    func v2BrowserCookieStoreAll(_ store: WKHTTPCookieStore, timeout: TimeInterval = 3.0) -> [HTTPCookie]? {
        var done = false
        var cookies: [HTTPCookie] = []
        store.getAllCookies { items in
            cookies = items
            done = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return done ? cookies : nil
    }

    func v2BrowserCookieStoreSet(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        var done = false
        store.setCookie(cookie) {
            done = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return done
    }

    func v2BrowserCookieStoreDelete(_ store: WKHTTPCookieStore, cookie: HTTPCookie, timeout: TimeInterval = 3.0) -> Bool {
        var done = false
        store.delete(cookie) {
            done = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done && Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return done
    }

    func v2BrowserCookieFromObject(_ raw: [String: Any], fallbackURL: URL?) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [:]
        if let name = raw["name"] as? String {
            props[.name] = name
        }
        if let value = raw["value"] as? String {
            props[.value] = value
        }

        if let urlStr = raw["url"] as? String, let url = URL(string: urlStr) {
            props[.originURL] = url
        } else if let fallbackURL {
            props[.originURL] = fallbackURL
        }

        if let domain = raw["domain"] as? String {
            props[.domain] = domain
        } else if let host = fallbackURL?.host {
            props[.domain] = host
        }

        if let path = raw["path"] as? String {
            props[.path] = path
        } else {
            props[.path] = "/"
        }

        if let secure = raw["secure"] as? Bool, secure {
            props[.secure] = "TRUE"
        }
        if let expires = raw["expires"] as? TimeInterval {
            props[.expires] = Date(timeIntervalSince1970: expires)
        } else if let expiresInt = raw["expires"] as? Int {
            props[.expires] = Date(timeIntervalSince1970: TimeInterval(expiresInt))
        }

        return HTTPCookie(properties: props)
    }

    func v2BrowserCookiesGet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            guard var cookies = v2BrowserCookieStoreAll(store) else {
                return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
            }

            if let name = v2String(params, "name") {
                cookies = cookies.filter { $0.name == name }
            }
            if let domain = v2String(params, "domain") {
                cookies = cookies.filter { $0.domain.contains(domain) }
            }
            if let path = v2String(params, "path") {
                cookies = cookies.filter { $0.path == path }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "cookies": cookies.map(v2BrowserCookieDict)
            ])
        }
    }

    func v2BrowserCookiesSet(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            let fallbackURL = browserPanel.currentURL

            var cookieObjects: [[String: Any]] = []
            if let rows = params["cookies"] as? [[String: Any]] {
                cookieObjects = rows
            } else {
                var single: [String: Any] = [:]
                if let name = v2String(params, "name") { single["name"] = name }
                if let value = v2String(params, "value") { single["value"] = value }
                if let url = v2String(params, "url") { single["url"] = url }
                if let domain = v2String(params, "domain") { single["domain"] = domain }
                if let path = v2String(params, "path") { single["path"] = path }
                if let secure = v2Bool(params, "secure") { single["secure"] = secure }
                if let expires = v2Int(params, "expires") { single["expires"] = expires }
                if !single.isEmpty {
                    cookieObjects = [single]
                }
            }

            guard !cookieObjects.isEmpty else {
                return .err(code: "invalid_params", message: "Missing cookies payload", data: nil)
            }

            var setCount = 0
            for raw in cookieObjects {
                guard let cookie = v2BrowserCookieFromObject(raw, fallbackURL: fallbackURL) else {
                    return .err(code: "invalid_params", message: "Invalid cookie payload", data: ["cookie": raw])
                }
                if v2BrowserCookieStoreSet(store, cookie: cookie) {
                    setCount += 1
                } else {
                    return .err(code: "timeout", message: "Timed out setting cookie", data: ["name": cookie.name])
                }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "set": setCount
            ])
        }
    }

    func v2BrowserCookiesClear(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let store = browserPanel.webView.configuration.websiteDataStore.httpCookieStore
            guard let cookies = v2BrowserCookieStoreAll(store) else {
                return .err(code: "timeout", message: "Timed out reading cookies", data: nil)
            }

            let name = v2String(params, "name")
            let domain = v2String(params, "domain")
            let clearAll = params["all"] == nil && name == nil && domain == nil
            let targets = cookies.filter { cookie in
                if clearAll { return true }
                if let name, cookie.name != name { return false }
                if let domain, !cookie.domain.contains(domain) { return false }
                return true
            }

            var removed = 0
            for cookie in targets {
                if v2BrowserCookieStoreDelete(store, cookie: cookie) {
                    removed += 1
                }
            }

            return .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                "cleared": removed
            ])
        }
    }

    func v2BrowserStorageType(_ params: [String: Any]) -> String {
        let type = (v2String(params, "storage") ?? v2String(params, "type") ?? "local").lowercased()
        return (type == "session") ? "session" : "local"
    }

    func v2BrowserStorageGet(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        let key = v2String(params, "key")
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let keyLiteral = key.map(v2JSONLiteral) ?? "null"
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const key = \(keyLiteral);
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              if (key == null) {
                const out = {};
                for (let i = 0; i < st.length; i++) {
                  const k = st.key(i);
                  out[k] = st.getItem(k);
                }
                return { ok: true, value: out };
              }
              return { ok: true, value: st.getItem(String(key)) };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "key": v2OrNull(key),
                    "value": v2NormalizeJSValue(dict["value"])
                ])
            }
        }
    }

    func v2BrowserStorageSet(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        guard let key = v2String(params, "key") else {
            return .err(code: "invalid_params", message: "Missing key", data: nil)
        }
        guard let value = params["value"] else {
            return .err(code: "invalid_params", message: "Missing value", data: nil)
        }

        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let keyLiteral = v2JSONLiteral(key)
            let valueLiteral = v2JSONLiteral(v2NormalizeJSValue(value))
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const key = String(\(keyLiteral));
              const value = \(valueLiteral);
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              st.setItem(key, value == null ? '' : String(value));
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "key": key
                ])
            }
        }
    }

    func v2BrowserStorageClear(params: [String: Any]) -> V2CallResult {
        let storageType = v2BrowserStorageType(params)
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            let typeLiteral = v2JSONLiteral(storageType)
            let script = """
            (() => {
              const type = String(\(typeLiteral));
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              st.clear();
              return { ok: true };
            })()
            """
            switch v2RunBrowserJavaScript(browserPanel.webView, surfaceId: surfaceId, script: script) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                guard let dict = value as? [String: Any],
                      let ok = dict["ok"] as? Bool,
                      ok else {
                    return .err(code: "invalid_state", message: "Storage unavailable", data: ["type": storageType])
                }
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "type": storageType,
                    "cleared": true
                ])
            }
        }
    }

    func v2BrowserTabList(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var payload: [String: Any]?
        let completed = v2MainExec(timeout: 2) {
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else { return }
            let browserPanels = self.orderedPanels(in: ws).compactMap { panel -> BrowserPanel? in
                panel as? BrowserPanel
            }
            let tabs: [[String: Any]] = browserPanels.enumerated().map { index, panel in
                [
                    "id": panel.id.uuidString,
                    "ref": self.v2Ref(kind: .surface, uuid: panel.id),
                    "index": index,
                    "title": ws.panelTitle(panelId: panel.id) ?? panel.displayTitle,
                    "url": panel.currentURL?.absoluteString ?? "",
                    "focused": panel.id == ws.focusedPanelId,
                    "pane_id": self.v2OrNull(ws.paneId(forPanelId: panel.id)?.id.uuidString),
                    "pane_ref": self.v2Ref(kind: .pane, uuid: ws.paneId(forPanelId: panel.id)?.id)
                ]
            }
            payload = [
                "workspace_id": ws.id.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": self.v2OrNull(ws.focusedPanelId?.uuidString),
                "surface_ref": self.v2Ref(kind: .surface, uuid: ws.focusedPanelId),
                "tabs": tabs
            ]
        }
        if !completed { return .err(code: "timeout", message: "Main thread busy", data: nil) }

        guard let payload else {
            return .err(code: "not_found", message: "Workspace not found", data: nil)
        }
        return .ok(payload)
    }

    func v2BrowserTabNew(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        let url = v2String(params, "url").flatMap(URL.init(string:))
        var result: V2CallResult = .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
        let completed = v2MainExec(timeout: 2) {
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }
            let paneUUID = self.v2UUID(params, "pane_id")
                ?? self.v2UUID(params, "target_pane_id")
                ?? (self.v2UUID(params, "surface_id").flatMap { ws.paneId(forPanelId: $0)?.id })
                ?? ws.paneId(forPanelId: ws.focusedPanelId ?? UUID())?.id
                ?? ws.bonsplitController.focusedPaneId?.id
            guard let paneUUID,
                  let pane = ws.bonsplitController.allPaneIds.first(where: { $0.id == paneUUID }) else {
                result = .err(code: "not_found", message: "Target pane not found", data: nil)
                return
            }

            guard let panel = ws.newBrowserSurface(inPane: pane, url: url, focus: self.v2FocusAllowed()) else {
                result = .err(code: "internal_error", message: "Failed to create browser tab", data: nil)
                return
            }
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: ws.id),
                "pane_id": pane.id.uuidString,
                "pane_ref": self.v2Ref(kind: .pane, uuid: pane.id),
                "surface_id": panel.id.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: panel.id),
                "url": panel.currentURL?.absoluteString ?? ""
            ])
        }
        if !completed { return .err(code: "timeout", message: "Main thread busy", data: nil) }
        return result
    }

    func v2BrowserTabSwitch(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Browser tab not found", data: nil)
        let completed = v2MainExec(timeout: 2) {
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let browserIds = self.orderedPanels(in: ws).compactMap { panel -> UUID? in
                (panel as? BrowserPanel)?.id
            }

            let targetId: UUID? = {
                if let explicit = self.v2UUID(params, "target_surface_id") ?? self.v2UUID(params, "tab_id") {
                    return explicit
                }
                if let idx = self.v2Int(params, "index"), idx >= 0, idx < browserIds.count {
                    return browserIds[idx]
                }
                return self.v2UUID(params, "surface_id")
            }()

            guard let targetId, browserIds.contains(targetId) else {
                result = .err(code: "not_found", message: "Browser tab not found", data: nil)
                return
            }

            ws.focusPanel(targetId)
            result = .ok([
                "workspace_id": ws.id.uuidString,
                "workspace_ref": self.v2Ref(kind: .workspace, uuid: ws.id),
                "surface_id": targetId.uuidString,
                "surface_ref": self.v2Ref(kind: .surface, uuid: targetId)
            ])
        }
        if !completed { return .err(code: "timeout", message: "Main thread busy", data: nil) }
        return result
    }

    func v2BrowserTabClose(params: [String: Any]) -> V2CallResult {
        guard let tabManager = v2ResolveTabManager(params: params) else {
            return .err(code: "unavailable", message: "TabManager not available", data: nil)
        }

        var result: V2CallResult = .err(code: "not_found", message: "Browser tab not found", data: nil)
        let completed = v2MainExec(timeout: 2) {
            guard let ws = self.v2ResolveWorkspace(params: params, tabManager: tabManager) else {
                result = .err(code: "not_found", message: "Workspace not found", data: nil)
                return
            }

            let browserIds = self.orderedPanels(in: ws).compactMap { panel -> UUID? in
                (panel as? BrowserPanel)?.id
            }
            guard !browserIds.isEmpty else {
                result = .err(code: "not_found", message: "No browser tabs", data: nil)
                return
            }

            let targetId: UUID? = {
                if let explicit = self.v2UUID(params, "target_surface_id") ?? self.v2UUID(params, "tab_id") {
                    return explicit
                }
                if let idx = self.v2Int(params, "index"), idx >= 0, idx < browserIds.count {
                    return browserIds[idx]
                }
                if let sid = self.v2UUID(params, "surface_id") {
                    return sid
                }
                return ws.focusedPanelId
            }()

            guard let targetId, browserIds.contains(targetId) else {
                result = .err(code: "not_found", message: "Browser tab not found", data: nil)
                return
            }

            if ws.panels.count <= 1 {
                result = .err(code: "invalid_state", message: "Cannot close the last surface", data: nil)
                return
            }

            let ok = ws.closePanel(targetId, force: true)
            result = ok
                ? .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": self.v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": targetId.uuidString,
                    "surface_ref": self.v2Ref(kind: .surface, uuid: targetId)
                ])
                : .err(code: "internal_error", message: "Failed to close browser tab", data: ["surface_id": targetId.uuidString])
        }
        if !completed { return .err(code: "timeout", message: "Main thread busy", data: nil) }
        return result
    }

    func v2BrowserConsoleList(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            let clear = v2Bool(params, "clear") ?? false
            let clearLiteral = clear ? "true" : "false"
            let script = """
            (() => {
              const items = Array.isArray(window.__termMeshConsoleLog) ? window.__termMeshConsoleLog.slice() : [];
              if (\(clearLiteral)) {
                window.__termMeshConsoleLog = [];
              }
              return { ok: true, items };
            })()
            """
            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "entries": items.map(v2NormalizeJSValue),
                    "count": items.count
                ])
            }
        }
    }

    func v2BrowserConsoleClear(params: [String: Any]) -> V2CallResult {
        var withClear = params
        withClear["clear"] = true
        return v2BrowserConsoleList(params: withClear)
    }

    func v2BrowserErrorsList(params: [String: Any]) -> V2CallResult {
        return v2BrowserWithPanel(params: params) { _, ws, surfaceId, browserPanel in
            v2BrowserEnsureTelemetryHooks(surfaceId: surfaceId, browserPanel: browserPanel)
            let clear = v2Bool(params, "clear") ?? false
            let clearLiteral = clear ? "true" : "false"
            let script = """
            (() => {
              const items = Array.isArray(window.__termMeshErrorLog) ? window.__termMeshErrorLog.slice() : [];
              if (\(clearLiteral)) {
                window.__termMeshErrorLog = [];
              }
              return { ok: true, items };
            })()
            """
            switch v2RunJavaScript(browserPanel.webView, script: script, timeout: 5.0) {
            case .failure(let message):
                return .err(code: "js_error", message: message, data: nil)
            case .success(let value):
                let dict = value as? [String: Any]
                let items = (dict?["items"] as? [Any]) ?? []
                return .ok([
                    "workspace_id": ws.id.uuidString,
                    "workspace_ref": v2Ref(kind: .workspace, uuid: ws.id),
                    "surface_id": surfaceId.uuidString,
                    "surface_ref": v2Ref(kind: .surface, uuid: surfaceId),
                    "errors": items.map(v2NormalizeJSValue),
                    "count": items.count
                ])
            }
        }
    }

}
