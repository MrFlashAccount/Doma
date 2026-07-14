import AppKit
import SwiftUI

@main
@MainActor
struct DomaApp: App {
    @StateObject private var manager: TunnelManager

    #if DEBUG
    private let previewWindow: NSWindow?
    #endif

    init() {
        let manager = TunnelManager()
        _manager = StateObject(wrappedValue: manager)

        #if DEBUG
        if CommandLine.arguments.contains("--preview-window") {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Doma — Preview"
            window.contentView = NSHostingView(rootView: ContentView(manager: manager))
            previewWindow = window

            DispatchQueue.main.async {
                NSApplication.shared.setActivationPolicy(.regular)
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        } else {
            previewWindow = nil
        }
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(manager: manager)
        } label: {
            Image(systemName: manager.state.symbol)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
    }
}
