import AppKit
import SwiftUI

@main
@MainActor
struct DomaApp: App {
    @StateObject private var manager: TunnelManager
    @StateObject private var updates: UpdateController

    #if DEBUG
    private let previewWindow: NSWindow?
    #endif

    init() {
        let manager = TunnelManager()
        let isPreview = CommandLine.arguments.contains("--preview-window")
            || CommandLine.arguments.contains("--preview-menubar-icon")
        let updates = UpdateController(startingUpdater: !isPreview)
        _manager = StateObject(wrappedValue: manager)
        _updates = StateObject(wrappedValue: updates)

        #if DEBUG
        if CommandLine.arguments.contains("--preview-window")
            || CommandLine.arguments.contains("--preview-menubar-icon")
        {
            let isMenuBarPreview = CommandLine.arguments.contains("--preview-menubar-icon")
            let content: AnyView = isMenuBarPreview
                ? AnyView(MenuBarIconPreview())
                : AnyView(ContentView(manager: manager, updates: updates))
            let size = isMenuBarPreview
                ? NSSize(width: 240, height: 112)
                : NSSize(width: 400, height: 560)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = isMenuBarPreview ? "Doma — Menu Bar Icon" : "Doma — Preview"
            window.contentView = NSHostingView(rootView: content)
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
            ContentView(manager: manager, updates: updates)
        } label: {
            Image(nsImage: MenuBarIcon.image(for: manager.state))
                .renderingMode(.template)
                .accessibilityLabel("Doma: \(manager.state.title)")
                .help("Doma: \(manager.state.title)")
        }
        .menuBarExtraStyle(.window)
    }
}
