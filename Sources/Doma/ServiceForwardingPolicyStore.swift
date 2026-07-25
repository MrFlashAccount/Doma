import Foundation

struct ServiceForwardingPolicyStore {
    private static let defaultsKey = "serviceForwardingPreferences.v1"

    private let defaults: UserDefaults

    static var standard: ServiceForwardingPolicyStore {
        ServiceForwardingPolicyStore(defaults: .standard)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func preferences(for host: String) -> [String: ServiceForwardingPreference] {
        allPreferences()[host] ?? [:]
    }

    func preference(
        for forwardingKey: String,
        host: String
    ) -> ServiceForwardingPreference {
        preferences(for: host)[forwardingKey] ?? .automatic
    }

    func set(
        _ preference: ServiceForwardingPreference,
        for forwardingKey: String,
        host: String
    ) {
        guard !host.isEmpty, !forwardingKey.isEmpty else { return }

        var all = allPreferences()
        var hostPreferences = all[host] ?? [:]
        if preference == .automatic {
            hostPreferences.removeValue(forKey: forwardingKey)
        } else {
            hostPreferences[forwardingKey] = preference
        }

        if hostPreferences.isEmpty {
            all.removeValue(forKey: host)
        } else {
            all[host] = hostPreferences
        }

        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private func allPreferences() -> [String: [String: ServiceForwardingPreference]] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let preferences = try? JSONDecoder().decode(
                [String: [String: ServiceForwardingPreference]].self,
                from: data
              )
        else {
            return [:]
        }
        return preferences
    }
}
