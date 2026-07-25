import AppKit
import SwiftUI

private enum ServiceSegment: String, CaseIterable, Identifiable {
    case active
    case available
    case excluded

    var id: Self { self }

    var title: String {
        switch self {
        case .active: "Активные"
        case .available: "Доступные"
        case .excluded: "Исключённые"
        }
    }

    var emptyTitle: String {
        switch self {
        case .active: "Нет активных сервисов"
        case .available: "Нет доступных сервисов"
        case .excluded: "Нет исключённых сервисов"
        }
    }

    var emptyDescription: String {
        switch self {
        case .active:
            "Включи сервис в «Доступных» или верни исключённый сервис в автоматический режим."
        case .available:
            "Все найденные сервисы уже активны или исключены."
        case .excluded:
            "Здесь появятся сервисы, для которых проброс выключен вручную."
        }
    }

    var symbol: String {
        switch self {
        case .active: "network"
        case .available: "plus.circle"
        case .excluded: "nosign"
        }
    }
}

struct ContentView: View {
    @ObservedObject var manager: TunnelManager
    @ObservedObject var updates: UpdateController
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    @State private var query = ""
    @State private var selectedSegment: ServiceSegment = .active
    @State private var hoveredPort: Int?
    @State private var isHostMenuHovered = false
    @State private var collapsedGroups = Set<String>()
    @State private var dismissedConnectionError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            overview
            connectionFailureBanner
            serviceControls
            serviceList
            footer
        }
        .frame(width: 400, height: 560)
        .onAppear {
            launchAtLogin.refresh()
            updates.checkForUpdatesSilentlyIfNeeded()
            presentPendingNativeErrors()
        }
        .onChange(of: manager.state) { _, state in
            if state == .connected {
                dismissedConnectionError = nil
            }
        }
        .onChange(of: manager.selectedHost) { _, _ in
            dismissedConnectionError = nil
        }
        .onChange(of: launchAtLogin.errorMessage) { _, error in
            guard let error else { return }
            DomaNativeDialog.showError(
                title: "Не удалось изменить автозапуск",
                message: error
            )
            launchAtLogin.clearError()
        }
        .onChange(of: manager.conflictResolutionError) { _, error in
            guard let error else { return }
            DomaNativeDialog.showError(
                title: "Не удалось освободить порт",
                message: error
            )
            manager.clearConflictResolutionError()
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.14))
                Image(systemName: manager.state.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                hostMenu
                Text(connectionSummary)
                    .font(.caption)
                    .foregroundStyle(connectionSummaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(connectionSummary)
            }

            Spacer(minLength: 12)

            actionButton(
                title: "Синхронизировать порты",
                symbol: "arrow.triangle.2.circlepath"
            ) {
                manager.syncNow()
            }

            actionButton(
                title: "Переподключиться",
                symbol: "bolt.horizontal.circle"
            ) {
                manager.reconnect()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 11)
    }

    private var hostMenu: some View {
        Menu {
            ForEach(manager.hosts) { host in
                Button {
                    manager.selectHost(host.alias)
                } label: {
                    if host.alias == manager.selectedHost {
                        Label(host.alias, systemImage: "checkmark")
                    } else {
                        Text(host.alias)
                    }
                }
            }

            Divider()

            Button {
                manager.reloadHosts()
            } label: {
                Label("Обновить список", systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 5) {
                Text(manager.selectedHost.isEmpty ? "SSH сервер" : manager.selectedHost)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.trailing, 6)
            .frame(height: 24)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHostMenuHovered ? Color.primary.opacity(0.07) : .clear)
            }
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovering in
            isHostMenuHovered = isHovering
        }
        .animation(.easeOut(duration: 0.12), value: isHostMenuHovered)
        .accessibilityLabel("SSH сервер: \(manager.selectedHost)")
    }

    private var overview: some View {
        HStack(spacing: 10) {
            metric(
                value: manager.activeCount,
                label: "проброшено",
                color: .green
            )

            metric(
                value: manager.services.count(where: { !$0.isForwardingEnabled }),
                label: "выключено",
                color: .gray
            )

            metric(
                value: manager.conflictCount,
                label: conflictMetricLabel,
                color: manager.conflictCount == 0 ? .gray : .orange
            )

            Spacer()

            Text("\(manager.remoteCount) на сервере")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .bottom) {
            separator
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var connectionFailureBanner: some View {
        if manager.state == .failed,
           let error = manager.lastError,
           dismissedConnectionError != error
        {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 16, height: 16)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Не удалось подключиться к \(manager.selectedHost)")
                            .font(.caption.weight(.semibold))
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .truncationMode(.tail)
                            .help(error)
                    }

                    Spacer(minLength: 4)

                    Button {
                        dismissedConnectionError = error
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Скрыть ошибку")
                    .accessibilityLabel("Скрыть ошибку подключения")
                }

                HStack(spacing: 8) {
                    Spacer()
                    if manager.hostKeyChanged {
                        Button("Проверить ключ…") {
                            confirmStaleHostKeyRemoval()
                        }
                    } else {
                        Button("Повторить") {
                            manager.reconnect()
                        }
                    }
                }
                .controlSize(.small)
            }
            .padding(11)
            .background(Color.red.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.red.opacity(0.16), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 16)
            .padding(.top, 11)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Фильтр по имени, проекту или порту", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Очистить фильтр")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help("Поиск в разделе «\(selectedSegment.title)»")
    }

    private var serviceControls: some View {
        VStack(spacing: 8) {
            Picker("Раздел сервисов", selection: $selectedSegment) {
                ForEach(ServiceSegment.allCases) { segment in
                    Text("\(segment.title) \(serviceCount(in: segment))")
                        .tag(segment)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .accessibilityLabel("Раздел сервисов")
            .accessibilityValue(selectedSegment.title)

            searchField
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var serviceList: some View {
        Group {
            if filteredGroups.isEmpty {
                ContentUnavailableView(
                    emptyStateTitle,
                    systemImage: query.isEmpty ? selectedSegment.symbol : "magnifyingglass",
                    description: Text(emptyStateDescription)
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(filteredGroups, id: \.0) { group, services in
                            serviceGroup(group, services: services)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("127.0.0.1")
                .font(.caption.monospaced())
            Text("·")
            Text(lastSyncText)
                .font(.caption)

            Spacer()

            Menu {
                Toggle("Запускать при входе", isOn: launchAtLoginBinding)

                if launchAtLogin.requiresApproval {
                    Button {
                        launchAtLogin.openLoginItemsSettings()
                    } label: {
                        Label("Разрешить автозапуск…", systemImage: "gear")
                    }
                }

                Divider()

                Button {
                    updates.performPrimaryAction()
                } label: {
                    if let version = updates.availableVersion {
                        Label("Обновить \(version)…", systemImage: "arrow.down.circle.fill")
                    } else if updates.isCheckingForUpdates {
                        Label("Проверяем обновления…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Text("Проверить обновления…")
                    }
                }
                .disabled(!updates.canCheckForUpdates || updates.isCheckingForUpdates)

                Divider()

                Button("Выйти из Doma", role: .destructive) {
                    manager.quit()
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "ellipsis")

                    if updates.availableVersion != nil {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                            .offset(x: 1, y: -1)
                    }
                }
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .controlSize(.small)
            .buttonBorderShape(.circle)
            .domaGlassButtonStyle()
            .fixedSize()
            .accessibilityLabel("Дополнительные действия")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .overlay(alignment: .top) {
            separator
                .allowsHitTesting(false)
        }
    }

    private func serviceGroup(_ group: String, services: [RemoteService]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    if collapsedGroups.contains(group) {
                        collapsedGroups.remove(group)
                    } else {
                        collapsedGroups.insert(group)
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isGroupExpanded(group) ? 90 : 0))

                    Text(shortGroup(group))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Text(services.count.formatted())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(shortGroup(group))
            .accessibilityValue(isGroupExpanded(group) ? "развернуто" : "свернуто")

            if isGroupExpanded(group) {
                ForEach(services) { service in
                    serviceRow(service)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func serviceRow(_ service: RemoteService) -> some View {
        HStack(spacing: 8) {
            Button {
                manager.openService(service)
            } label: {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(kindColor(service.kind).opacity(0.11))
                        Image(systemName: service.kind.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(kindColor(service.kind))
                    }
                    .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.name)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(serviceForwardingSummary(service))
                            .font(.system(size: 10.5))
                            .foregroundStyle(serviceForwardingSummaryColor(service))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 10)

                    Text(String(service.port))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(service.isForwarded)
            .focusable(service.isForwarded)
            .help(serviceHelp(service))
            .accessibilityLabel("\(service.name), порт \(service.port), \(serviceState(service))")
            .accessibilityHidden(!service.isForwarded)

            serviceAccessory(service)
        }
        .padding(.horizontal, 7)
        .frame(height: 44)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hoveredPort == service.port ? Color.primary.opacity(0.06) : .clear)
        }
        .onHover { isHovering in
            hoveredPort = isHovering ? service.port : nil
        }
        .contextMenu {
            Button {
                manager.setForwardingPreference(.automatic, for: service)
            } label: {
                Label(
                    automaticForwardingMenuTitle(service),
                    systemImage: service.forwardingPreference == .automatic
                        ? "checkmark"
                        : "arrow.uturn.backward"
                )
            }

            Divider()

            Button {
                manager.setForwardingPreference(.included, for: service)
            } label: {
                Label(
                    "Пробрасывать всегда",
                    systemImage: service.forwardingPreference == .included
                        ? "checkmark"
                        : "network"
                )
            }

            Button {
                manager.setForwardingPreference(.excluded, for: service)
            } label: {
                Label(
                    "Не пробрасывать",
                    systemImage: service.forwardingPreference == .excluded
                        ? "checkmark"
                        : "network.slash"
                )
            }
        }
        .accessibilityAction(named: "Автоматический режим") {
            manager.setForwardingPreference(.automatic, for: service)
        }
        .accessibilityAction(named: "Пробрасывать всегда") {
            manager.setForwardingPreference(.included, for: service)
        }
        .accessibilityAction(named: "Не пробрасывать") {
            manager.setForwardingPreference(.excluded, for: service)
        }
    }

    @ViewBuilder
    private func serviceAccessory(_ service: RemoteService) -> some View {
        switch selectedSegment {
        case .active:
            activeServiceStatus(service)
            excludeServiceButton(service)
        case .available, .excluded:
            includeServiceButton(service)
        }
    }

    @ViewBuilder
    private func activeServiceStatus(_ service: RemoteService) -> some View {
        if manager.changingForwardingPorts.contains(service.port) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 12, height: 12)
                .help(service.isForwardingEnabled ? "Включаем проброс" : "Выключаем проброс")
        } else if service.hasConflict {
            conflictResolutionButton(service)
        } else if hoveredPort == service.port && service.isForwarded {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
        } else {
            statusMark(service)
        }
    }

    private func excludeServiceButton(_ service: RemoteService) -> some View {
        Button {
            manager.setForwardingPreference(.excluded, for: service)
        } label: {
            Image(systemName: "network.slash")
                .font(.system(size: 10.5, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(manager.changingForwardingPorts.contains(service.port))
        .help("Исключить из проброса")
        .accessibilityLabel("Исключить \(service.name) из проброса")
    }

    @ViewBuilder
    private func includeServiceButton(_ service: RemoteService) -> some View {
        if manager.changingForwardingPorts.contains(service.port) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 24, height: 24)
                .help("Изменяем проброс")
        } else {
            Button {
                manager.setForwardingPreference(.included, for: service)
            } label: {
                Image(systemName: "network")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Пробрасывать порт \(service.port)")
            .accessibilityLabel("Включить проброс \(service.name), порт \(service.port)")
        }
    }

    @ViewBuilder
    private func conflictResolutionButton(_ service: RemoteService) -> some View {
        if manager.resolvingPorts.contains(service.port) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 12, height: 12)
                .help("Завершаем локальный процесс")
        } else if canResolveConflict(service) {
            Button {
                confirmConflictResolution(service)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(conflictResolutionHelp(service))
            .accessibilityLabel("Освободить порт \(service.port)")
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .frame(width: 12)
                .help(conflictResolutionHelp(service))
        }
    }

    @ViewBuilder
    private func statusMark(_ service: RemoteService) -> some View {
        if service.hasConflict {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .frame(width: 12)
        } else {
            Circle()
                .fill(service.isForwarded ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 6, height: 6)
                .frame(width: 12)
        }
    }

    private func metric(value: Int, label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(value.formatted())
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var conflictMetricLabel: String {
        let remainder100 = manager.conflictCount % 100
        if 11 ... 14 ~= remainder100 {
            return "конфликтов"
        }
        switch manager.conflictCount % 10 {
        case 1:
            return "конфликт"
        case 2 ... 4:
            return "конфликта"
        default:
            return "конфликтов"
        }
    }

    private func actionButton(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
        }
        .controlSize(.small)
        .buttonBorderShape(.circle)
        .domaGlassButtonStyle()
        .help(title)
        .accessibilityLabel(title)
    }

    private var filteredGroups: [(String, [RemoteService])] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return manager.groupedServices.compactMap { group, services in
            let filtered = services.filter { service in
                serviceBelongsToSelectedSegment(service)
                    && (needle.isEmpty || serviceMatchesSearch(service, needle: needle))
            }
            return filtered.isEmpty ? nil : (group, filtered)
        }
    }

    private func serviceCount(in segment: ServiceSegment) -> Int {
        manager.services.count(where: { serviceBelongs($0, to: segment) })
    }

    private func serviceBelongsToSelectedSegment(_ service: RemoteService) -> Bool {
        serviceBelongs(service, to: selectedSegment)
    }

    private func serviceBelongs(_ service: RemoteService, to segment: ServiceSegment) -> Bool {
        switch segment {
        case .active:
            service.isForwardingEnabled
        case .available:
            service.forwardingPreference == .automatic && !service.defaultForwardingEnabled
        case .excluded:
            service.forwardingPreference == .excluded
        }
    }

    private func serviceMatchesSearch(_ service: RemoteService, needle: String) -> Bool {
        service.name.lowercased().contains(needle)
            || service.group.lowercased().contains(needle)
            || service.details.lowercased().contains(needle)
            || String(service.port).contains(needle)
            || service.kind.title.lowercased().contains(needle)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

    private func isGroupExpanded(_ group: String) -> Bool {
        !collapsedGroups.contains(group) || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var connectionSummary: String {
        if let error = manager.lastError {
            return error
        }
        if let warning = manager.lastWarning {
            return warning
        }
        switch manager.state {
        case .connected:
            return "\(manager.activeCount) из \(manager.remoteCount) портов"
        case .connecting:
            return "Устанавливаем соединение"
        case .failed:
            return "Соединение недоступно"
        case .disconnected:
            return "Не подключено"
        }
    }

    private var connectionSummaryColor: Color {
        if manager.lastError != nil { return .red }
        if manager.lastWarning != nil { return .orange }
        return .secondary
    }

    private var emptyStateTitle: String {
        if manager.services.isEmpty, manager.state != .connected {
            return manager.state == .connecting ? "Подключаемся…" : "Сервисы недоступны"
        }
        return query.isEmpty ? selectedSegment.emptyTitle : "Нет совпадений"
    }

    private var emptyStateDescription: String {
        if manager.services.isEmpty, manager.state != .connected {
            return manager.state == .connecting
                ? "Сервисы появятся после подключения"
                : "Выбери SSH сервер и подключись"
        }
        if !query.isEmpty {
            return "В разделе «\(selectedSegment.title)» ничего не найдено. Измени запрос или выбери другой раздел."
        }
        return selectedSegment.emptyDescription
    }

    private var lastSyncText: String {
        guard let lastSync = manager.lastSync else { return "ещё не обновлялось" }
        return "обновлено " + lastSync.formatted(date: .omitted, time: .shortened)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 1)
    }

    private func shortGroup(_ group: String) -> String {
        guard group.hasPrefix("/home/") else { return group }
        let components = group.split(separator: "/")
        return "…/" + components.suffix(4).joined(separator: "/")
    }

    private func kindColor(_ kind: ServiceKind) -> Color {
        switch kind {
        case .docker: .blue
        case .hermes: .orange
        case .kubernetes: .teal
        case .minikube: .indigo
        case .vite: .yellow
        case .node: .green
        case .python: .cyan
        case .zrok: .purple
        case .process: .mint
        case .system: .gray
        }
    }

    private func serviceHelp(_ service: RemoteService) -> String {
        let action = service.isForwarded
            ? "Открыть http://127.0.0.1:\(service.port)/"
            : service.isForwardingEnabled
                ? "Порт выбран, но ещё не проброшен"
                : "Проброс выключен"
        return service.details.isEmpty ? action : "\(service.details)\n\(action)"
    }

    private func serviceForwardingSummary(_ service: RemoteService) -> String {
        if manager.changingForwardingPorts.contains(service.port) {
            return service.isForwardingEnabled ? "Включаем…" : "Выключаем…"
        }
        if service.hasConflict {
            return "Конфликт локального порта"
        }

        switch service.forwardingPreference {
        case .automatic:
            if !service.isForwardingEnabled {
                return "Авто · выключен"
            }
            return service.isForwarded ? "Авто · проброшен" : "Авто · ожидает проброса"
        case .included:
            return service.isForwarded ? "Включён вручную" : "Вручную · ожидает проброса"
        case .excluded:
            return "Выключен вручную"
        }
    }

    private func serviceForwardingSummaryColor(_ service: RemoteService) -> Color {
        if service.hasConflict {
            return .orange
        }
        if service.isForwarded {
            return .secondary
        }
        return Color.secondary.opacity(0.65)
    }

    private func automaticForwardingMenuTitle(_ service: RemoteService) -> String {
        "Автоматически — \(service.defaultForwardingEnabled ? "включать" : "не включать")"
    }

    private func canResolveConflict(_ service: RemoteService) -> Bool {
        !service.conflictOwners.isEmpty && service.conflictOwners.allSatisfy(\.canTerminate)
    }

    private func conflictResolutionHelp(_ service: RemoteService) -> String {
        guard !service.conflictOwners.isEmpty else {
            return "Не удалось определить локальный процесс"
        }
        if let blocked = service.conflictOwners.first(where: { !$0.canTerminate }) {
            return "Нельзя завершить \(blocked.name) (PID \(blocked.pid)): "
                + (blocked.terminationBlockReason ?? "операция недоступна")
        }
        return "Завершить \(conflictOwnerNames(service)) и освободить порт \(service.port)"
    }

    private func conflictConfirmation(_ service: RemoteService) -> String {
        "Doma отправит SIGTERM процессу \(conflictOwnerNames(service)). "
            + "Несохранённые данные этого приложения могут быть потеряны."
    }

    private func confirmConflictResolution(_ service: RemoteService) {
        guard DomaNativeDialog.confirmDestructive(
            title: "Освободить порт \(service.port)?",
            message: conflictConfirmation(service),
            actionTitle: "Завершить процесс"
        ) else { return }

        manager.resolveConflict(for: service)
    }

    private func confirmStaleHostKeyRemoval() {
        let message = "Doma сначала сохранит уникальные резервные копии всех затронутых "
            + "пользовательских known_hosts, затем удалит прежние записи только для этого адреса. "
            + "Для каждого файла сохраняются три последние успешные копии. При частичной ошибке "
            + "Doma атомарно заменит каждый восстанавливаемый файл и постарается восстановить весь "
            + "набор; общей атомарности между файлами нет. Незавершённая операция будет восстановлена "
            + "при следующем запуске. Новый ключ не будет принят автоматически даже при accept-new/no "
            + "в SSH config: SSH снова покажет fingerprint. Если смена неожиданна, сначала сверь его "
            + "с администратором."

        guard DomaNativeDialog.confirmDestructive(
            title: "Забыть старый ключ \(manager.selectedHost)?",
            message: message,
            actionTitle: "Удалить и переподключиться"
        ) else { return }

        manager.removeStaleHostKeyAndReconnect()
    }

    private func presentPendingNativeErrors() {
        if let error = launchAtLogin.errorMessage {
            DomaNativeDialog.showError(
                title: "Не удалось изменить автозапуск",
                message: error
            )
            launchAtLogin.clearError()
        }
        if let error = manager.conflictResolutionError {
            DomaNativeDialog.showError(
                title: "Не удалось освободить порт",
                message: error
            )
            manager.clearConflictResolutionError()
        }
    }

    private func conflictOwnerNames(_ service: RemoteService) -> String {
        service.conflictOwners
            .map { "\($0.name) (PID \($0.pid))" }
            .joined(separator: ", ")
    }

    private func serviceState(_ service: RemoteService) -> String {
        if manager.changingForwardingPorts.contains(service.port) {
            return service.isForwardingEnabled ? "включается" : "выключается"
        }
        if service.hasConflict { return "конфликт" }
        if !service.isForwardingEnabled { return "выключен" }
        return service.isForwarded ? "проброшен" : "ожидает проброса"
    }

    private var statusColor: Color {
        switch manager.state {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .gray
        }
    }
}

@MainActor
private enum DomaNativeDialog {
    static func confirmDestructive(
        title: String,
        message: String,
        actionTitle: String
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message

        let destructiveButton = alert.addButton(withTitle: actionTitle)
        destructiveButton.hasDestructiveAction = true
        destructiveButton.keyEquivalent = ""

        let cancelButton = alert.addButton(withTitle: "Отмена")
        cancelButton.keyEquivalent = "\u{1b}"

        return alert.runModal() == .alertFirstButtonReturn
    }

    static func showError(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private extension View {
    @ViewBuilder
    func domaGlassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
