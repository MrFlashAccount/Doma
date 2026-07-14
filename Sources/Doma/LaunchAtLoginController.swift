import AppKit
import Combine
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
        case .requiresApproval:
            isEnabled = false
            requiresApproval = true
        case .notRegistered, .notFound:
            isEnabled = false
            requiresApproval = false
        @unknown default:
            isEnabled = false
            requiresApproval = false
        }
    }

    func setEnabled(_ shouldEnable: Bool) {
        do {
            if shouldEnable {
                try enable()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        refresh()
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func clearError() {
        errorMessage = nil
    }

    private func enable() throws {
        switch SMAppService.mainApp.status {
        case .enabled:
            break
        case .requiresApproval:
            openLoginItemsSettings()
        case .notRegistered, .notFound:
            try SMAppService.mainApp.register()
        @unknown default:
            try SMAppService.mainApp.register()
        }
    }
}
