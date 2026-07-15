import AppKit

@MainActor
final class DomaAppDelegate: NSObject, NSApplicationDelegate {
    weak var manager: TunnelManager?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager else { return .terminateNow }

        manager.shutdown {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
