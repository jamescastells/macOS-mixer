//
//  macOS_mixerApp.swift
//  macOS-mixer
//
//  Created by James on 28/10/26.
//

import SwiftUI

@main
struct macOS_mixerApp: App {
    @State private var model = MixerModel()

    init() {
        StatusItemContextMenu.install()
    }

    var body: some Scene {
        MenuBarExtra("macOS-mixer", systemImage: "slider.vertical.3") {
            ContentView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
