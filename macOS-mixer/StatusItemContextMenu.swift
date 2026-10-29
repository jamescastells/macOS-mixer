//
//  StatusItemContextMenu.swift
//  macOS-mixer
//

import AppKit

/// `MenuBarExtra` has no right-click menu, so this watches for right-clicks on the status item
/// (which lives in a status-bar window owned by this app) and shows a menu with Launch at startup and Quit.
enum StatusItemContextMenu {
    private static var monitor: Any?

    private final class Actions: NSObject {
        @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
            LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled)
        }
    }
    private static let actions = Actions()

    static func install() {
        guard monitor == nil else { return }
        LaunchAtLogin.applyDefaultIfNeeded()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            guard let window = event.window,
                  window.className.contains("StatusBar"),
                  let view = window.contentView else { return event }

            let menu = NSMenu()
            let launchItem = menu.addItem(
                withTitle: "Launch at startup",
                action: #selector(Actions.toggleLaunchAtLogin(_:)),
                keyEquivalent: "")
            launchItem.target = actions
            launchItem.state = LaunchAtLogin.isEnabled ? .on : .off
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return nil   // don't let the click also toggle the panel
        }
    }
}
