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

private enum ServiceListItem: Identifiable {
    enum ID: Hashable {
        case group(String)
        case service(String, Int)
    }

    case group(name: String, serviceCount: Int, isFirst: Bool)
    case service(RemoteService)

    var id: ID {
        switch self {
        case let .group(name, _, _):
            .group(name)
        case let .service(service):
            .service(service.group, service.port)
        }
    }
}

private struct HoverableServiceRow<Content: View>: View {
    @State private var isHovered = false
    private let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        content(isHovered)
            .onHover { isHovered = $0 }
    }
}

private final class BorderlessSearchFieldCell: NSSearchFieldCell {
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var textRect = super.searchTextRect(forBounds: rect)
        textRect.origin.x += 10
        textRect.size.width = max(0, textRect.size.width - 10)
        return textRect
    }
}

private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        let searchCell = BorderlessSearchFieldCell(textCell: "")
        searchCell.resetSearchButtonCell()
        searchCell.resetCancelButtonCell()
        searchField.cell = searchCell
        searchField.placeholderString = prompt
        searchField.delegate = context.coordinator
        searchField.sendsSearchStringImmediately = true
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.controlSize = .large
        searchField.font = .systemFont(ofSize: NSFont.systemFontSize)
        searchField.setAccessibilityLabel("Фильтр сервисов")
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCancel = onCancel

        if searchField.stringValue != text {
            searchField.stringValue = text
        }

        guard !context.coordinator.didRequestFocus else { return }
        context.coordinator.didRequestFocus = true
        DispatchQueue.main.async { [weak searchField] in
            guard let searchField else { return }
            searchField.window?.makeFirstResponder(searchField)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onCancel: () -> Void
        var didRequestFocus = false

        init(text: Binding<String>, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            text.wrappedValue = searchField.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            onCancel()
            return true
        }
    }
}

struct ContentView: View {
    @ObservedObject var manager: TunnelManager
    @ObservedObject var updates: UpdateController
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    @State private var query = ""
    @State private var selectedSegment: ServiceSegment = .active
    @State private var isSearchPresented = false
    @State private var isHostMenuHovered = false
    @State private var collapsedGroups = Set<String>()
    @State private var dismissedConnectionError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            connectionFailureBanner
            serviceBrowser
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
                headerDetail
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

            moreMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 15)
        .padding(.bottom, 11)
    }

    private var headerDetail: some View {
        HStack(spacing: 4) {
            Image(systemName: headerDetailSymbol)
                .font(.system(size: 9, weight: .semibold))
            Text(headerDetailText)
        }
        .font(.caption)
        .foregroundStyle(headerDetailColor)
        .lineLimit(1)
        .truncationMode(.tail)
        .help(headerDetailHelp)
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

    private var serviceBrowser: some View {
        serviceList
            .safeAreaInset(edge: .bottom, spacing: 0) {
                serviceNavigation
            }
    }

    private var serviceNavigation: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if isSearchPresented {
                    nativeSearchField
                } else {
                    serviceTabBar
                }
                searchButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .animation(.snappy(duration: 0.28), value: isSearchPresented)
    }

    private var serviceTabBar: some View {
        HStack(spacing: 2) {
            ForEach(ServiceSegment.allCases) { segment in
                let isSelected = selectedSegment == segment

                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        selectedSegment = segment
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: segment.symbol)
                            .font(.system(size: 13, weight: .semibold))

                        Text("\(segment.title) \(serviceCount(in: segment))")
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Color.accentColor)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(segment.title)
                .accessibilityValue("\(serviceCount(in: segment))")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectTransition(.materialize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Раздел сервисов")
    }

    private var nativeSearchField: some View {
        NativeSearchField(
            text: $query,
            prompt: "Имя, проект или порт",
            onCancel: closeSearch
        )
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectTransition(.materialize)
    }

    private var searchButton: some View {
        Button {
            if isSearchPresented {
                closeSearch()
            } else {
                withAnimation(.snappy(duration: 0.28)) {
                    isSearchPresented = true
                }
            }
        } label: {
            Image(systemName: isSearchPresented ? "xmark" : "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(isSearchPresented ? "Закрыть поиск" : "Поиск")
        .help(isSearchPresented ? "Закрыть поиск" : "Поиск сервисов")
    }

    private func closeSearch() {
        query = ""
        withAnimation(.snappy(duration: 0.28)) {
            isSearchPresented = false
        }
    }

    private var serviceList: some View {
        let groups = filteredGroups
        let items = serviceListItems(from: groups)

        return Group {
            if groups.isEmpty {
                ContentUnavailableView(
                    emptyStateTitle,
                    systemImage: isSearchPresented ? "magnifyingglass" : selectedSegment.symbol,
                    description: Text(emptyStateDescription)
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(items) { item in
                            switch item {
                            case let .group(name, serviceCount, isFirst):
                                serviceGroupHeader(
                                    name,
                                    serviceCount: serviceCount,
                                    topPadding: isFirst ? 0 : 12
                                )
                            case let .service(service):
                                serviceRow(service)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
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

    private var moreMenu: some View {
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
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Дополнительные действия")
    }

    private func serviceGroupHeader(
        _ group: String,
        serviceCount: Int,
        topPadding: CGFloat
    ) -> some View {
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

                Text(serviceCount.formatted())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, topPadding)
        .accessibilityLabel(shortGroup(group))
        .accessibilityValue(isGroupExpanded(group) ? "развернуто" : "свернуто")
    }

    private func serviceRow(_ service: RemoteService) -> some View {
        HoverableServiceRow { isHovered in
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

                serviceAccessory(service, isHovered: isHovered)
            }
            .padding(.horizontal, 7)
            .frame(height: 44)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : .clear)
            }
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
    private func serviceAccessory(_ service: RemoteService, isHovered: Bool) -> some View {
        if isSearchPresented {
            if service.isForwardingEnabled {
                activeServiceStatus(service, isHovered: isHovered)
                excludeServiceButton(service)
            } else {
                includeServiceButton(service)
            }
        } else {
            switch selectedSegment {
            case .active:
                activeServiceStatus(service, isHovered: isHovered)
                excludeServiceButton(service)
            case .available, .excluded:
                includeServiceButton(service)
            }
        }
    }

    @ViewBuilder
    private func activeServiceStatus(_ service: RemoteService, isHovered: Bool) -> some View {
        Group {
            if manager.changingForwardingPorts.contains(service.port) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 12, height: 12)
                    .help(service.isForwardingEnabled ? "Включаем проброс" : "Выключаем проброс")
            } else if service.hasConflict {
                conflictResolutionButton(service)
            } else if isHovered && service.isForwarded {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            } else {
                statusMark(service)
            }
        }
        .frame(width: 24, height: 24)
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
        let needle = isSearchPresented
            ? query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : ""
        return manager.groupedServices.compactMap { group, services in
            let filtered = services.filter { service in
                (isSearchPresented || serviceBelongsToSelectedSegment(service))
                    && (needle.isEmpty || serviceMatchesSearch(service, needle: needle))
            }
            return filtered.isEmpty ? nil : (group, filtered)
        }
    }

    private func serviceListItems(
        from groups: [(String, [RemoteService])]
    ) -> [ServiceListItem] {
        var items: [ServiceListItem] = []
        for (index, group) in groups.enumerated() {
            items.append(
                .group(
                    name: group.0,
                    serviceCount: group.1.count,
                    isFirst: index == groups.startIndex
                )
            )
            if isGroupExpanded(group.0) {
                items.append(contentsOf: group.1.map(ServiceListItem.service))
            }
        }
        return items
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
        !collapsedGroups.contains(group)
            || (isSearchPresented
                && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var headerDetailText: String {
        if let error = manager.lastError {
            return error
        }
        if let warning = manager.lastWarning {
            return warning
        }
        return lastSyncText
    }

    private var headerDetailSymbol: String {
        if manager.lastError != nil { return "exclamationmark.triangle.fill" }
        if manager.lastWarning != nil { return "exclamationmark.circle.fill" }
        return "arrow.clockwise"
    }

    private var headerDetailColor: Color {
        if manager.lastError != nil { return .red }
        if manager.lastWarning != nil { return .orange }
        return .secondary
    }

    private var headerDetailHelp: String {
        if manager.lastError != nil || manager.lastWarning != nil {
            return headerDetailText
        }
        guard manager.lastSync != nil else { return "Синхронизация ещё не выполнялась" }
        return "Последняя синхронизация: \(lastSyncText)"
    }

    private var emptyStateTitle: String {
        if manager.services.isEmpty, manager.state != .connected {
            return manager.state == .connecting ? "Подключаемся…" : "Сервисы недоступны"
        }
        if isSearchPresented, !query.isEmpty {
            return "Нет совпадений"
        }
        return selectedSegment.emptyTitle
    }

    private var emptyStateDescription: String {
        if manager.services.isEmpty, manager.state != .connected {
            return manager.state == .connecting
                ? "Сервисы появятся после подключения"
                : "Выбери SSH сервер и подключись"
        }
        if isSearchPresented, !query.isEmpty {
            return "Измени запрос или очисти поле поиска."
        }
        return selectedSegment.emptyDescription
    }

    private var lastSyncText: String {
        guard let lastSync = manager.lastSync else { return "—" }
        return lastSync.formatted(date: .omitted, time: .shortened)
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
    func domaGlassButtonStyle() -> some View {
        buttonStyle(.glass)
    }
}
