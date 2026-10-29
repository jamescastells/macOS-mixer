//
//  LaunchAtLogin.swift
//  macOS-mixer
//

import Foundation
import ServiceManagement

enum LaunchAtLogin {
    private static let defaultAppliedKey = "launchAtLoginDefaultApplied"

    /// Treat "waiting for approval in System Settings" as on, since the user did ask for it.
    static var isEnabled: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: true
        default: false
        }
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Couldn't \(enabled ? "enable" : "disable") launch at login: \(error)")
        }
    }

    /// Launch at login is on by default: register once on first run, then leave the user's choice alone.
    static func applyDefaultIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: defaultAppliedKey) else { return }
        UserDefaults.standard.set(true, forKey: defaultAppliedKey)
        setEnabled(true)
    }
}
