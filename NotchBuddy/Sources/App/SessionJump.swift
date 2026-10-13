import AppKit
import ApplicationServices

// MARK: - Jump to a session's terminal
//
// Shared by the "Open terminal" button, the ⌃⌥T shortcut, a click on the
// Claude Code pill and "Open Visual Studio Code". Sessions from
// VS Code or Cursor run in the editor's integrated terminal:
// • editor running → bring back the window of the session's project (found by
//   its title through the Accessibility API, on any Space, un-minimized and
//   raised: macOS slides to its Space); without Accessibility, reopen the
//   editor like a Dock click;
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
        let windows = allWindows(of: app.processIdentifier)
        guard !windows.isEmpty else { return false }

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
                let focused = focusWindow(window, pid: app.processIdentifier)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                if !focused { app.activate() }
                return true
            }
            folder.deleteLastPathComponent()
        }
        return false
        #endif
    }

    #if !APPSTORE
    /// The app's windows on every Space. kAXWindowsAttribute only lists the
    /// current Space (plus minimized windows), so windows on other Spaces are
    /// found the way window switchers such as AltTab do: AX elements rebuilt
    /// from a remote token (pid + element id), through a private HIServices
    /// call looked up at run time. Without it, only the listed windows.
    private static func allWindows(of pid: pid_t) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success,
           let listed = value as? [AXUIElement] {
            windows = listed
        }
        guard let createWithToken = createWithRemoteToken else { return windows }

        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(0x636f_636f)) { Data($0) })
        for elementId in UInt64(0)..<1000 {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementId) { Data($0) })
            guard let element = createWithToken(token as CFData)?.takeRetainedValue() else { continue }
            var subrole: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
                  subrole as? String == kAXStandardWindowSubrole as String,
                  !windows.contains(where: { CFEqual($0, element) }) else { continue }
            windows.append(element)
        }
        return windows
    }

    /// Makes this exact window the frontmost one, so macOS slides to its Space
    /// (activating the app only goes to the Space of its last active window).
    /// Private SkyLight calls looked up at run time, as AltTab does; false when
    /// they're missing.
    private static func focusWindow(_ window: AXUIElement, pid: pid_t) -> Bool {
        guard let getWindow = axGetWindow, let setFront = setFrontProcess, let postEvent = postEventRecord,
              let getProcess = getProcessForPID else { return false }
        var windowId: CGWindowID = 0
        guard getWindow(window, &windowId) == .success, windowId != 0 else { return false }
        var psn = ProcessSerialNumber()
        guard getProcess(pid, &psn) == noErr else { return false }
        guard setFront(&psn, windowId, 0x200) == 0 else { return false }   // kCPSUserGenerated

        // Key-window event records (0xf8 bytes), sent twice as AltTab does.
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowId) { for (i, byte) in $0.enumerated() { bytes[0x3c + i] = byte } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = postEvent(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEvent(&psn, &bytes)
        return true
    }

    private typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer?, as type: T.Type) -> T? {
        guard let pointer = dlsym(handle ?? UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    private static let axGetWindow = symbol("_AXUIElementGetWindow", in: nil, as: AXGetWindow.self)
    private static let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", in: skyLight, as: SetFrontProcess.self)
    private static let postEventRecord = symbol("SLPSPostEventRecordTo", in: skyLight, as: PostEventRecord.self)
    private static let getProcessForPID = symbol("GetProcessForPID", in: nil, as: GetProcessForPID.self)

    private typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static let createWithRemoteToken = symbol("_AXUIElementCreateWithRemoteToken", in: nil, as: CreateWithRemoteToken.self)
    #endif
}
