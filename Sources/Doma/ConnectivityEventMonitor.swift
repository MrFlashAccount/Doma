import AppKit
import Network

@MainActor
final class ConnectivityEventMonitor {
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "com.mrflashaccount.doma.network-path")
    private let onConnectivityChange: @MainActor () -> Void

    private var wakeObserver: NSObjectProtocol?
    private var hasObservedInitialPath = false
    private var pendingNotification: Task<Void, Never>?

    init(onConnectivityChange: @escaping @MainActor () -> Void) {
        self.onConnectivityChange = onConnectivityChange
    }

    deinit {
        pathMonitor.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        pendingNotification?.cancel()
    }

    func start() {
        guard wakeObserver == nil else { return }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleNotification(after: .seconds(1))
            }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func handlePathUpdate(_ path: NWPath) {
        guard hasObservedInitialPath else {
            hasObservedInitialPath = true
            return
        }
        guard path.status == .satisfied else {
            pendingNotification?.cancel()
            pendingNotification = nil
            return
        }
        scheduleNotification(after: .milliseconds(500))
    }

    private func scheduleNotification(after delay: Duration) {
        pendingNotification?.cancel()
        pendingNotification = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            pendingNotification = nil
            onConnectivityChange()
        }
    }
}
