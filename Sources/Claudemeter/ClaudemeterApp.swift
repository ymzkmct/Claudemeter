import AppKit
import SwiftUI

@main
@MainActor
struct ClaudemeterApp: App {
    private let store: UsageStore

    init() {
        // Menu-bar-only app even when launched outside a bundle (e.g. `swift run`).
        NSApplication.shared.setActivationPolicy(.accessory)
        let store = UsageStore()
        self.store = store
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    let store: UsageStore

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: store.showsWarning ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
            Text(store.menuBarTitle)
                .monospacedDigit()
        }
    }
}
