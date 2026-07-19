import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: TunnelManager
    @ObservedObject var updates: UpdateController
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    @State private var query = ""
    @State private var hoveredPort: Int?
    @State private var isHostMenuHovered = false
    @State private var collapsedGroups = Set<String>()
    @State private var conflictResolutionRequest: RemoteService?
    @State private var connectionErrorMessage: String?
    @State private var staleHostKeyRemovalRequested = false

    var body: some View {
        VStack(spacing: 0) {
            header
            overview
            searchField
            serviceList
            footer
        }
        .frame(width: 400, height: 560)
        .onAppear {
            launchAtLogin.refresh()
            updates.checkForUpdatesSilentlyIfNeeded()
            if manager.state == .failed, let error = manager.lastError {
                connectionErrorMessage = error
            }
        }
        .onChange(of: manager.lastError) { _, error in
            guard manager.state == .failed, let error else { return }
            connectionErrorMessage = error
        }
        .alert(
            "Не удалось подключиться к \(manager.selectedHost)",
            isPresented: connectionErrorBinding
        ) {
            if manager.hostKeyChanged {
                Button("Забыть старый ключ…") {
                    connectionErrorMessage = nil
                    staleHostKeyRemovalRequested = true
                }
            } else {
                Button("Повторить") {
                    connectionErrorMessage = nil
                    manager.reconnect()
                }
            }
            Button("Закрыть", role: .cancel) {
                connectionErrorMessage = nil
            }
        } message: {
            Text(connectionErrorMessage ?? "Неизвестная ошибка SSH")
        }
        .alert(
            "Забыть старый ключ \(manager.selectedHost)?",
            isPresented: $staleHostKeyRemovalRequested
        ) {
            Button("Удалить и переподключиться", role: .destructive) {
                manager.removeStaleHostKeyAndReconnect()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Doma сначала сохранит уникальные резервные копии всех затронутых пользовательских known_hosts, затем удалит прежние записи только для этого адреса. Для каждого файла сохраняются три последние успешные копии. При частичной ошибке Doma атомарно заменит каждый восстанавливаемый файл и постарается восстановить весь набор; общей атомарности между файлами нет. Незавершённая операция будет восстановлена при следующем запуске. Новый ключ не будет принят автоматически даже при accept-new/no в SSH config: SSH снова покажет fingerprint. Если смена неожиданна, сначала сверь его с администратором.")
        }
        .alert(
            "Не удалось изменить автозапуск",
            isPresented: launchAtLoginErrorBinding
        ) {
            Button("OK", role: .cancel) {
                launchAtLogin.clearError()
            }
        } message: {
            Text(launchAtLogin.errorMessage ?? "Неизвестная ошибка")
        }
        .alert(item: $conflictResolutionRequest) { service in
            Alert(
                title: Text("Освободить порт \(service.port)?"),
                message: Text(conflictConfirmation(service)),
                primaryButton: .destructive(Text("Завершить процесс")) {
                    manager.resolveConflict(for: service)
                },
                secondaryButton: .cancel()
            )
        }
        .alert(
            "Не удалось освободить порт",
            isPresented: conflictResolutionErrorBinding
        ) {
            Button("OK", role: .cancel) {
                manager.clearConflictResolutionError()
            }
        } message: {
            Text(manager.conflictResolutionError ?? "Неизвестная ошибка")
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
        HStack(spacing: 14) {
            metric(
                value: manager.activeCount,
                label: "проброшено",
                color: .green
            )

            metric(
                value: manager.conflictCount,
                label: "конфликтов",
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
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var serviceList: some View {
        Group {
            if filteredGroups.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Сервисы не найдены" : "Ничего не найдено",
                    systemImage: query.isEmpty ? "network" : "magnifyingglass",
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

                    Text(service.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 10)

                    Text(String(service.port))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .disabled(!service.isForwarded)
            .help(serviceHelp(service))
            .accessibilityLabel("\(service.name), порт \(service.port), \(serviceState(service))")

            if hoveredPort == service.port && service.isForwarded {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            } else if service.hasConflict {
                conflictResolutionButton(service)
            } else {
                statusMark(service)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: 38)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hoveredPort == service.port ? Color.primary.opacity(0.06) : .clear)
        }
        .onHover { isHovering in
            hoveredPort = isHovering ? service.port : nil
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
                conflictResolutionRequest = service
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
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
        guard !needle.isEmpty else { return manager.groupedServices }

        return manager.groupedServices.compactMap { group, services in
            let filtered = services.filter { service in
                service.name.lowercased().contains(needle)
                    || service.group.lowercased().contains(needle)
                    || service.details.lowercased().contains(needle)
                    || String(service.port).contains(needle)
                    || service.kind.title.lowercased().contains(needle)
            }
            return filtered.isEmpty ? nil : (group, filtered)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) }
        )
    }

    private var launchAtLoginErrorBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    launchAtLogin.clearError()
                }
            }
        )
    }

    private var conflictResolutionErrorBinding: Binding<Bool> {
        Binding(
            get: { manager.conflictResolutionError != nil },
            set: { isPresented in
                if !isPresented {
                    manager.clearConflictResolutionError()
                }
            }
        )
    }

    private var connectionErrorBinding: Binding<Bool> {
        Binding(
            get: { connectionErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    connectionErrorMessage = nil
                }
            }
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

    private var emptyStateDescription: String {
        if !query.isEmpty {
            return "Попробуй изменить запрос"
        }
        return manager.state == .connected
            ? "На сервере нет поддерживаемых TCP-сервисов"
            : "Выбери SSH сервер и подключись"
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
            : "Порт не проброшен"
        return service.details.isEmpty ? action : "\(service.details)\n\(action)"
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

    private func conflictOwnerNames(_ service: RemoteService) -> String {
        service.conflictOwners
            .map { "\($0.name) (PID \($0.pid))" }
            .joined(separator: ", ")
    }

    private func serviceState(_ service: RemoteService) -> String {
        if service.hasConflict { return "конфликт" }
        return service.isForwarded ? "проброшен" : "не проброшен"
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
