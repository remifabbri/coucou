import AppKit
import ApplicationServices

// MARK: - Jump to a session's terminal
//
// Shared by the "Open terminal" button, the ⌃⌥T shortcut, a click on the
// Claude Code pill and "Open Visual Studio Code". Sessions from
// VS Code or Cursor run in the editor's integrated terminal:
// • editor running → bring back the window of the session's project (found by
//   its title through the Accessibility API, un-minimized and raised, which also
//   switches Space); without Accessibility, reopen the editor like a Dock click;
// • editor closed → launch it on the session's folder.
// Never opens the folder in a running editor: that creates a new window when
// the project was opened from a parent folder or a workspace.

@MainActor
enum SessionJump {
    private static var askedForAccessibility = false

    private static let terminalBundleIds = ["com.apple.Terminal", "com.googlecode.iterm2",
                                            "net.kovidgoyal.kitty", "com.mitchellh.ghostty"]

    private static func editorBundleIds(for pillId: String) -> [String] {
        switch pillId {
        case "integration_claude": return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium.codium"]
        case "agent_cursor":       return ["com.todesktop.230313mzl4w4u92"]
        default:                   return []
        }
    }

    static func open(_ task: AgentTask?) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let cwd = task?.sessionCwd.flatMap { $0.isEmpty ? nil : $0 }

        if let task {
            let editors = editorBundleIds(for: task.id)
            let running = editors.lazy.compactMap { id in
                NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }
            }.first
            if let running {
                if let cwd, raiseWindow(of: running, matching: cwd) { return }
                // Windows on another Space aren't listed: bring the editor forward
                // (macOS switches to a Space with its windows), then look again.
                if let appURL = running.bundleURL {
                    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
                }
                if let cwd {
                    Task {
                        try? await Task.sleep(for: .milliseconds(500))
                        _ = raiseWindow(of: running, matching: cwd)
                    }
                }
                return
            }
            if let appURL = editors.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
                if let cwd {
                    NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: appURL,
                                            configuration: configuration, completionHandler: nil)
                } else {
                    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
                }
                return
            }
        }

        let terminalURL = terminalBundleIds.lazy.compactMap { id in
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }?.bundleURL
        }.first ?? URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: terminalURL, configuration: configuration, completionHandler: nil)
    }

    /// Raises the editor window whose title names the session's folder, or the
    /// closest parent folder (the project may be opened one level up). Needs the
    /// Accessibility permission; returns false without it or when nothing matches.
    private static func raiseWindow(of app: NSRunningApplication, matching cwd: String) -> Bool {
        #if APPSTORE
        return false
        #else
        guard AXIsProcessTrusted() else {
            // Shows macOS's prompt pointing to Settings → Accessibility (once per launch).
            if !askedForAccessibility {
                askedForAccessibility = true
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            return false
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return false }

        // Title segments, e.g. "main.swift — coucou — Visual Studio Code" → ["main.swift", "coucou", …]
        let titled: [(AXUIElement, Set<String>)] = windows.map { window in
            var title: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
            // Split on the spaced separators only: "casier-judiciaire.html" stays whole.
            var segments = [(title as? String) ?? ""]
            for separator in [" — ", " – ", " - "] {
                segments = segments.flatMap { $0.components(separatedBy: separator) }
            }
            segments = segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return (window, Set(segments))
        }

        // Deepest folder first, stopping before the home folder.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var folder = URL(fileURLWithPath: cwd).standardizedFileURL
        while folder.path.count > home.count {
            let name = folder.lastPathComponent
            if let (window, _) = titled.first(where: { $0.1.contains(name) }) {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                app.activate()
                return true
            }
            folder.deleteLastPathComponent()
        }
        return false
        #endif
    }
}
