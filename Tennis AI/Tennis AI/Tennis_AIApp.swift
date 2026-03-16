//
//  Tennis_AIApp.swift
//  Tennis AI
//
//  Created by Kaijun Lin on 2026/3/11.
//

import SwiftUI

@main
struct Tennis_AIApp: App {
    @StateObject private var themeStore: ThemeStore

    init() {
        let defaults = UserDefaults.standard
        if ProcessInfo.processInfo.arguments.contains("UI_TESTS_RESET_THEME") {
            ThemeStore.resetPersistedSelection(defaults: defaults)
        }
        _themeStore = StateObject(wrappedValue: ThemeStore(defaults: defaults))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(themeStore)
        }
    }
}
