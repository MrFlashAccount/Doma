import AppKit

@MainActor
final class DomaAppDelegate: NSObject, NSApplicationDelegate {
    weak var manager: TunnelManager?
    private var connectivityMonitor: ConnectivityEventMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let connectivityMonitor = ConnectivityEventMonitor { [weak self] in
            self?.manager?.syncNow()
        }
        self.connectivityMonitor = connectivityMonitor
        connectivityMonitor.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager else { return .terminateNow }

        manager.shutdown {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
