import AppKit
import Darwin
import Foundation

private let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
private let promptKind = ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"]

NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.activate(ignoringOtherApps: true)

let alert = NSAlert()
alert.alertStyle = .informational
alert.messageText = title(for: prompt, promptKind: promptKind)
alert.informativeText = prompt.isEmpty ? "SSH запрашивает подтверждение для подключения." : prompt
alert.addButton(withTitle: promptKind == "confirm" ? "Разрешить" : "Продолжить")
alert.addButton(withTitle: "Отмена")

var secretField: NSSecureTextField?
if promptKind != "confirm" {
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.placeholderString = placeholder(for: prompt)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    secretField = field
}

guard alert.runModal() == .alertFirstButtonReturn else {
    exit(EXIT_FAILURE)
}

if let secret = secretField?.stringValue {
    FileHandle.standardOutput.write(Data((secret + "\n").utf8))
}
exit(EXIT_SUCCESS)

private func title(for prompt: String, promptKind: String?) -> String {
    if promptKind == "confirm" {
        return "Подтвердить SSH-подключение"
    }

    let normalized = prompt.lowercased()
    if normalized.contains("passphrase") {
        return "Пароль SSH-ключа"
    }
    if normalized.contains("verification code")
        || normalized.contains("one-time password")
        || normalized.contains("otp")
    {
        return "Код подтверждения SSH"
    }
    return "Пароль SSH"
}

private func placeholder(for prompt: String) -> String {
    let normalized = prompt.lowercased()
    if normalized.contains("verification code")
        || normalized.contains("one-time password")
        || normalized.contains("otp")
    {
        return "Код подтверждения"
    }
    return "Пароль"
}
