import SwiftUI

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject var viewModel: AppViewModel

    /// Dynamic minimum size based on UI mode.
    private var minWidth: CGFloat {
        viewModel.uiMode == .compact ? 380 : 800
    }
    private var minHeight: CGFloat {
        viewModel.uiMode == .compact ? 300 : 500
    }

    var body: some View {
        ZStack {
            Group {
                switch viewModel.appState {
                case .locked:
                    LockScreenView()
                case .onboarding:
                    OnboardingView()
                case .dataRecovery(let reason):
                    DataRecoveryView(reason: reason)
                case .unlocked:
                    switch viewModel.uiMode {
                    case .compact:
                        CompactView()
                    case .full:
                        MainView()
                    }
                }
            }

            // ── Accessibility Permission Guide Overlay ──
            if viewModel.showAccessibilityGuide {
                AccessibilityGuideOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .frame(minWidth: minWidth, minHeight: minHeight)
        .overlay(alignment: .bottom) {
            if viewModel.isStatusMessageVisible {
                StatusMessageBar(message: viewModel.statusMessage)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.25), value: viewModel.isStatusMessageVisible)
                    .padding(.bottom, 8)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: viewModel.showAccessibilityGuide)
        .animation(.easeInOut(duration: 0.3), value: viewModel.uiMode)
        .sheet(item: $viewModel.activeSheet) { sheet in
            sheetContent(for: sheet)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAccessibilityGuide)) { _ in
            // Defer to the next run-loop iteration to avoid
            // "Publishing changes from within view updates" warning.
            DispatchQueue.main.async {
                if !viewModel.isAccessibilityGranted {
                    viewModel.showAccessibilityGuide = true
                }
            }
        }
    }

    // MARK: - Sheet Dispatcher (shared by Compact + Full modes)

    @ViewBuilder
    func sheetContent(for sheet: ActiveSheet) -> some View {
        switch sheet {
        case .addEntry:
            EntryEditorSheet(mode: .add).environmentObject(viewModel)
        case .editEntry(let id):
            EntryEditorSheet(mode: .edit(id)).environmentObject(viewModel)
        case .entryDetail(let id):
            if let entry = viewModel.storageService.getEntry(byId: id) {
                EntryDetailSheet(entry: entry).environmentObject(viewModel)
            }
        case .clipboardHistory:
            ClipboardHistorySheet().environmentObject(viewModel)
        case .settings:
            SettingsSheet().environmentObject(viewModel)
        case .gistSync:
            GistSyncSheet().environmentObject(viewModel)
        case .hotkeySettings:
            HotkeySettingsSheet().environmentObject(viewModel)
        case .quickSearch:
            QuickSearchSheet().environmentObject(viewModel)
        case .about:
            AboutSheet()
        case .checkUpdate:
            AboutSheet()
        case .importData:
            ImportSheet().environmentObject(viewModel)
        case .exportData:
            ExportSheet().environmentObject(viewModel)
        }
    }
}

// MARK: - MainView

struct MainView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } content: {
            EntryListView()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 400)
        } detail: {
            if let entryId = viewModel.selectedEntryId,
                let entry = viewModel.storageService.getEntry(byId: entryId)
            {
                EntryDetailView(entry: entry)
            } else {
                EmptyDetailView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarItems
            }
        }
        .searchable(
            text: $viewModel.filterState.searchQuery,
            placement: .sidebar,
            prompt: "搜索条目… (正则: /pattern/)"
        )
    }

    @ViewBuilder
    private var toolbarItems: some View {
        Button {
            viewModel.prepareNewEntry()
        } label: {
            Label("新建条目", systemImage: "plus")
        }
        .keyboardShortcut("n", modifiers: .command)
        .help("新建条目 (⌘N)")

        Button {
            viewModel.isPrivacyMode.toggle()
        } label: {
            Label(
                viewModel.isPrivacyMode ? "关闭隐私模式" : "开启隐私模式",
                systemImage: viewModel.isPrivacyMode ? "eye.slash.fill" : "eye"
            )
        }
        .help(viewModel.isPrivacyMode ? "关闭隐私模式" : "开启隐私模式")

        Button {
            Task { await viewModel.performGistSync() }
        } label: {
            Label(
                "同步",
                systemImage: viewModel.isSyncing
                    ? "arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath")
        }
        .disabled(viewModel.isSyncing)
        .help("同步到 GitHub Gist")

        Menu {
            Button("设置...") {
                viewModel.activeSheet = .settings
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("快捷键设置...") {
                viewModel.activeSheet = .hotkeySettings
            }

            Button("Gist 同步设置...") {
                viewModel.activeSheet = .gistSync
            }

            Divider()

            Button {
                viewModel.activeSheet = .importData
            } label: {
                Label("导入数据...", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Button {
                viewModel.activeSheet = .exportData
            } label: {
                Label("导出数据...", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Divider()

            Button("关于 MacKeyValue") {
                viewModel.activeSheet = .about
            }

            // Show "有新版本" when update is available
            if UpdateService.shared.state.isAvailable {
                Button {
                    viewModel.activeSheet = .about
                } label: {
                    Label(
                        "有新版本 \(UpdateService.shared.state.availableVersion ?? "")  ↑",
                        systemImage: "arrow.up.circle.fill"
                    )
                }
            }

            Divider()

            Button {
                viewModel.toggleUIMode()
            } label: {
                Label("切换到精简模式", systemImage: "rectangle.compress.vertical")
            }
        } label: {
            // Badge the ellipsis icon when an update is waiting
            ZStack(alignment: .topTrailing) {
                Image(systemName: "ellipsis.circle")
                if UpdateService.shared.state.isAvailable {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                        .offset(x: 4, y: -4)
                }
            }
        }
    }
}

// MARK: - SidebarView

struct SidebarView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        List {
            Section("分类") {
                // All entries
                sidebarRow(
                    title: "全部",
                    icon: "tray.full.fill",
                    count: viewModel.entries.count,
                    isSelected: viewModel.filterState.selectedCategory == nil
                        && !viewModel.filterState.showFavoritesOnly
                ) {
                    viewModel.filterState.selectedCategory = nil
                    viewModel.filterState.showFavoritesOnly = false
                    viewModel.filterState.showPrivateOnly = false
                }

                // Favorites
                sidebarRow(
                    title: "收藏",
                    icon: "star.fill",
                    count: viewModel.favoriteEntries.count,
                    isSelected: viewModel.filterState.showFavoritesOnly,
                    tintColor: .yellow
                ) {
                    viewModel.filterState.showFavoritesOnly = true
                    viewModel.filterState.selectedCategory = nil
                    viewModel.filterState.showPrivateOnly = false
                }

                // Each category
                ForEach(KeyValueEntry.Category.allCases) { category in
                    let count = viewModel.entries.filter { $0.category == category }.count
                    sidebarRow(
                        title: category.displayName,
                        icon: category.iconName,
                        count: count,
                        isSelected: viewModel.filterState.selectedCategory == category
                    ) {
                        viewModel.filterState.selectedCategory = category
                        viewModel.filterState.showFavoritesOnly = false
                        viewModel.filterState.showPrivateOnly = false
                    }
                }
            }

            Section("隐私") {
                sidebarRow(
                    title: "私密条目",
                    icon: "lock.shield.fill",
                    count: viewModel.entries.filter { $0.isPrivate }.count,
                    isSelected: viewModel.filterState.showPrivateOnly,
                    tintColor: Color(red: 0.80, green: 0.65, blue: 0.20)
                ) {
                    viewModel.filterState.showPrivateOnly = true
                    viewModel.filterState.showFavoritesOnly = false
                    viewModel.filterState.selectedCategory = nil
                }
            }

            Section("工具") {
                Button {
                    viewModel.activeSheet = .clipboardHistory
                } label: {
                    Label("剪贴板历史", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.plain)

                HStack {
                    Circle()
                        .fill(viewModel.isPrivacyMode ? Color.red : Color.green)
                        .frame(width: 8, height: 8)
                    Text(viewModel.isPrivacyMode ? "隐私模式 · 开启" : "隐私模式 · 关闭")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("统计") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("共 \(viewModel.totalEntryCount) 条记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("存储: \(viewModel.storageSizeFormatted)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func sidebarRow(
        title: String,
        icon: String,
        count: Int,
        isSelected: Bool,
        tintColor: Color = .accentColor,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                    .foregroundStyle(isSelected ? tintColor : .primary)
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.secondary.opacity(0.15))
                    )
            }
            // Without contentShape the hit-test only covers drawn pixels
            // (Label + badge). The Spacer() is transparent so clicks in
            // the middle of the row fall through. Rectangle() makes the
            // entire row area respond to taps.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? tintColor.opacity(0.1) : .clear)
                .padding(.horizontal, -4)
        )
    }
}

// MARK: - EntryListView

struct EntryListView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Sort control
            HStack {
                Text("\(viewModel.filteredEntries.count) 条记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("排序", selection: $viewModel.filterState.sortOrder) {
                    ForEach(EntrySortOrder.allCases) { order in
                        Text(order.displayName).tag(order)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 140)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            if viewModel.filteredEntries.isEmpty {
                emptyListView
            } else {
                List(viewModel.filteredEntries, selection: $viewModel.selectedEntryId) { entry in
                    EntryRowView(entry: entry)
                        .tag(entry.id)
                        .contextMenu {
                            entryContextMenu(for: entry)
                        }
                }
                .listStyle(.inset)
            }
        }
    }

    @ViewBuilder
    private var emptyListView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: viewModel.filterState.isActive ? "magnifyingglass" : "tray")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)

            if viewModel.filterState.isActive {
                Text("没有匹配的条目")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("尝试调整搜索条件或筛选器")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Button("清除筛选") {
                    viewModel.filterState.reset()
                }
                .buttonStyle(.bordered)
            } else {
                Text("还没有任何条目")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("点击 + 按钮创建你的第一个条目")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                Button("新建条目") {
                    viewModel.prepareNewEntry()
                }
                .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func entryContextMenu(for entry: KeyValueEntry) -> some View {
        Button("复制值") {
            viewModel.copyEntryValue(id: entry.id)
        }

        Button("粘贴到目标窗口") {
            viewModel.pasteEntryValue(id: entry.id)
        }

        Button("模拟键入到目标窗口 (PVE/KVM)") {
            viewModel.typeEntryValue(id: entry.id)
        }

        Divider()

        Button("编辑...") {
            viewModel.prepareEditEntry(entry)
        }

        Button(entry.isFavorite ? "取消收藏" : "收藏") {
            viewModel.toggleFavorite(id: entry.id)
        }

        Button(entry.isPrivate ? "取消私密" : "设为私密") {
            viewModel.togglePrivate(id: entry.id)
        }

        Divider()

        Button("删除", role: .destructive) {
            viewModel.deleteEntry(id: entry.id)
        }
    }
}

// MARK: - EntryRowView

struct EntryRowView: View {
    let entry: KeyValueEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: entry.category.iconName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(entry.title)
                    .font(.headline)
                    .lineLimit(1)

                if entry.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }

                if entry.isPrivate {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(Color(red: 0.80, green: 0.65, blue: 0.20))
                }

                Spacer()
            }

            HStack(spacing: 4) {
                Text(entry.key)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if entry.usageCount > 0 {
                    Text("×\(entry.usageCount)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if !entry.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(entry.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.1))
                            )
                            .foregroundStyle(.secondary)
                    }
                    if entry.tags.count > 3 {
                        Text("+\(entry.tags.count - 3)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Text(entry.updatedAt.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - EntryDetailView

struct EntryDetailView: View {
    @EnvironmentObject var viewModel: AppViewModel
    let entry: KeyValueEntry

    @State private var isValueRevealed = false
    @State private var decryptedValue: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // ── Header ──
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: entry.category.iconName)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(0.1))
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(entry.title)
                                    .font(.title2.bold())
                                    .lineLimit(1)

                                if entry.isFavorite {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(.yellow)
                                }

                                if entry.isPrivate {
                                    Label("私密", systemImage: "lock.fill")
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule().fill(
                                                Color(red: 0.80, green: 0.65, blue: 0.20).opacity(
                                                    0.15))
                                        )
                                        .foregroundStyle(Color(red: 0.80, green: 0.65, blue: 0.20))
                                }
                            }
                            Text(entry.category.displayName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)
                    }

                    // Action buttons — icon-only for compact layout
                    HStack(spacing: 6) {
                        Button {
                            viewModel.copyEntryValue(id: entry.id)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                        .help("复制值 (⇧⌘C)")

                        Button {
                            viewModel.pasteEntryValue(id: entry.id)
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("v", modifiers: [.command, .shift])
                        .help("粘贴到目标窗口 (⇧⌘V)")

                        Button {
                            viewModel.typeEntryValue(id: entry.id)
                        } label: {
                            Image(systemName: "keyboard")
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("t", modifiers: [.command, .shift])
                        .help("模拟键入到目标窗口 (⇧⌘T)")

                        Spacer(minLength: 0)

                        Button {
                            viewModel.prepareEditEntry(entry)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("编辑条目")
                    }
                }

                Divider()

                // ── Key ──
                DetailField(label: "键名", value: entry.key, icon: "key")

                // ── Value ──
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("值", systemImage: "lock.rectangle")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            if isValueRevealed {
                                isValueRevealed = false
                                decryptedValue = nil
                            } else {
                                Task {
                                    if let v = await viewModel.decryptedValueWithAuth(for: entry) {
                                        decryptedValue = v
                                        isValueRevealed = true
                                    }
                                }
                            }
                        } label: {
                            Label(
                                isValueRevealed ? "隐藏" : "显示",
                                systemImage: isValueRevealed ? "eye.slash" : "eye"
                            )
                            .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }

                    Group {
                        if isValueRevealed, let value = decryptedValue {
                            Text(value)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        } else {
                            Text("••••••••••••")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2))
                    )
                }

                // ── Hotkey Binding ──
                VStack(alignment: .leading, spacing: 6) {
                    Label("快捷键", systemImage: "command")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        if let binding = viewModel.hotkeyService.bindings.first(where: {
                            $0.entryId == entry.id && $0.actionType == .typePassword
                        }) {
                            HStack(spacing: 4) {
                                Text(binding.keyCombo.description)
                                    .font(.system(.callout, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.secondary.opacity(0.1))
                                    )
                                Text("→ 键入密码")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("未绑定")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                        }

                        Spacer()

                        Button {
                            viewModel.activeSheet = .hotkeySettings
                        } label: {
                            Label("设置快捷键", systemImage: "gear")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2))
                    )
                }

                // ── Tags ──
                if !entry.tags.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("标签", systemImage: "tag")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(entry.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.1)))
                            }
                        }
                    }
                }

                // ── Notes ──
                if !entry.notes.isEmpty {
                    DetailField(label: "备注", value: entry.notes, icon: "note.text")
                }

                Divider()

                // ── Metadata ──
                VStack(alignment: .leading, spacing: 8) {
                    Label("元信息", systemImage: "info.circle")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                        ], spacing: 8
                    ) {
                        MetadataItem(label: "创建时间", value: entry.createdAt.formatted(.dateTime))
                        MetadataItem(label: "更新时间", value: entry.updatedAt.formatted(.dateTime))
                        MetadataItem(label: "使用次数", value: "\(entry.usageCount)")
                        MetadataItem(
                            label: "上次使用",
                            value: entry.lastUsedAt?.formatted(.relative(presentation: .named))
                                ?? "从未使用"
                        )
                    }
                }

                Spacer()

                // ── Delete ──
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        viewModel.deleteEntry(id: entry.id)
                    } label: {
                        Label("删除此条目", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .padding(.top, 20)
            }
            .padding(24)
        }
        .onChange(of: entry.id) { _ in
            isValueRevealed = false
            decryptedValue = nil
        }
    }
}

// MARK: - EmptyDetailView

struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.circle")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("选择一个条目查看详情")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("或使用快捷键快速搜索")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Detail Helpers

struct DetailField: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: icon)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                )
        }
    }
}

struct MetadataItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.05))
        )
    }
}

// MARK: - FlowLayout

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(subviews: subviews, containerWidth: proposal.width ?? .infinity)
        return result.size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let result = layout(subviews: subviews, containerWidth: bounds.width)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(subviews[index].sizeThatFits(.unspecified))
            )
        }
    }

    private struct LayoutResult {
        var positions: [CGPoint]
        var size: CGSize
    }

    private func layout(subviews: Subviews, containerWidth: CGFloat) -> LayoutResult {
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > containerWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxWidth = max(maxWidth, currentX - spacing)
        }

        return LayoutResult(
            positions: positions,
            size: CGSize(width: maxWidth, height: currentY + lineHeight)
        )
    }
}

// MARK: - StatusMessageBar

struct StatusMessageBar: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.regularMaterial)
            )
            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }
}

// MARK: - LockScreenView

struct LockScreenView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color(red: 0.80, green: 0.65, blue: 0.20))
            Text("MacKeyValue")
                .font(.largeTitle.bold())
            Text("正在验证...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - DataRecoveryView

/// Shown when the app detects that the Keychain master key is missing while
/// encrypted data files still exist on disk (e.g. after reinstall, Keychain
/// wipe, or TCC reset).  This view gives the user explicit control:
///   • Export raw backup files (for manual inspection)
///   • Reset to a clean state (WARNING: irreversible data loss)
///   • Retry (in case the Keychain was temporarily unavailable)
struct DataRecoveryView: View {
    let reason: DataRecoveryReason

    @EnvironmentObject var viewModel: AppViewModel
    @State private var showResetConfirm = false
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.lock.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)

                Text("数据安全警告")
                    .font(.largeTitle.bold())

                Text(reasonMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }
            .padding(.vertical, 32)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .background(.orange.opacity(0.08))

            Divider()

            // ── Detail Info ──────────────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    infoCard(
                        icon: "info.circle",
                        color: .blue,
                        title: "为什么会这样？",
                        body: "加密主密钥存储在 macOS Keychain 中。当 Keychain 被清除、App 重装或系统切换账户时，密钥可能丢失。磁盘上的加密数据文件仍然完整，但没有对应的密钥无法解密。"
                    )

                    infoCard(
                        icon: "folder.badge.questionmark",
                        color: .purple,
                        title: "数据文件位置",
                        body: viewModel.storageService.storageDirectory.path
                    )

                    if case .storageCorrupted(let file) = reason {
                        infoCard(
                            icon: "doc.badge.exclamationmark",
                            color: .red,
                            title: "损坏的文件",
                            body: file
                        )
                    }

                    infoCard(
                        icon: "lightbulb",
                        color: .yellow,
                        title: "建议操作顺序",
                        body: "1. 点击「在 Finder 中查看」确认备份文件完好\n2. 如果可以恢复 Keychain，点击「重试」\n3. 确实无法恢复时，才选择「重置并重新开始」（数据将被清除）"
                    )
                }
                .padding(24)
            }

            Divider()

            // ── Action Buttons ──────────────────────────────────────────
            HStack(spacing: 12) {
                // Open backup folder
                Button {
                    NSWorkspace.shared.open(viewModel.storageService.storageDirectory)
                } label: {
                    Label("在 Finder 中查看", systemImage: "folder")
                }
                .help("打开数据目录，查看加密文件和备份文件")

                Spacer()

                // Retry (re-run bootstrap)
                Button {
                    isRetrying = true
                    Task {
                        await viewModel.bootstrap()
                        isRetrying = false
                    }
                } label: {
                    if isRetrying {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(width: 16, height: 16)
                    } else {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                }
                .help("如果 Keychain 已恢复，点此重试")

                // Danger: reset
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("重置并重新开始", systemImage: "trash")
                }
                .help("删除所有加密数据并生成新密钥（不可恢复）")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 560, minHeight: 460)
        .confirmationDialog(
            "确定要重置并删除所有数据吗？",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("删除并重新开始", role: .destructive) {
                viewModel.performDataReset()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会永久删除 \(viewModel.storageService.storageDirectory.path) 中的所有条目以及备份。\n\n拟删除的文件已在 Finder 中显示——请先手动备份。")
        }
    }

    private var reasonMessage: String {
        switch reason {
        case .masterKeyLost:
            return "加密主密钥丢失，但磁盘上存在已加密数据。\n为防止数据不可恢复，应用已暫停服务。请选择下方操作。"
        case .storageCorrupted(let file):
            return "数据文件损坏无法被读取。\n已尝试自动从备份源恢复：「\(file)」"
        case .bootstrapFailed(let message):
            return "应用启动失败：「\(message)」"
        }
    }

    @ViewBuilder
    private func infoCard(icon: String, color: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - OnboardingView

struct OnboardingView: View {
    @EnvironmentObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "key.viewfinder")
                .font(.system(size: 72))
                .foregroundStyle(.tint)

            Text("欢迎使用 MacKeyValue")
                .font(.largeTitle.bold())

            Text("安全存储你的密码、代码片段和常用文本。\n支持快捷键输入、剪贴板管理和 GitHub Gist 同步。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(
                    icon: "lock.shield.fill", title: "AES-256 加密", description: "所有密码使用行业标准加密算法保护")
                FeatureRow(icon: "keyboard", title: "模拟键盘输入", description: "绕过粘贴限制，直接模拟键盘输入密码")
                FeatureRow(
                    icon: "doc.on.clipboard.fill", title: "智能剪贴板", description: "自动记录剪贴板历史，支持隐私模式")
                FeatureRow(
                    icon: "arrow.triangle.2.circlepath", title: "Gist 同步",
                    description: "将常用条目同步到 GitHub Gist")
            }
            .frame(maxWidth: 400)

            Button("开始使用") {
                viewModel.completeOnboarding()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Sheet Stubs (minimal implementations)

struct EntryEditorSheet: View {
    enum Mode: Equatable {
        case add
        case edit(UUID)
    }

    let mode: Mode
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(mode == .add ? "新建条目" : "编辑条目")
                .font(.title2.bold())

            Form {
                TextField("标题", text: $viewModel.editingTitle)
                TextField("键名", text: $viewModel.editingKey)

                if viewModel.editingCategory == .password {
                    SecureField("值", text: $viewModel.editingValue)
                } else {
                    TextEditor(text: $viewModel.editingValue)
                        .frame(minHeight: 80)
                }

                Picker("分类", selection: $viewModel.editingCategory) {
                    ForEach(KeyValueEntry.Category.allCases) { category in
                        Label(category.displayName, systemImage: category.iconName)
                            .tag(category)
                    }
                }

                TextField("标签（逗号分隔）", text: $viewModel.editingTags)
                TextEditor(text: $viewModel.editingNotes)
                    .frame(minHeight: 40)

                Toggle("收藏", isOn: $viewModel.editingIsFavorite)
                Toggle("私密", isOn: $viewModel.editingIsPrivate)
            }
            .formStyle(.grouped)

            HStack {
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(mode == .add ? "创建" : "保存") {
                    switch mode {
                    case .add:
                        viewModel.saveNewEntry()
                    case .edit(let id):
                        viewModel.updateEntry(id: id)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.editingTitle.isEmpty || viewModel.editingKey.isEmpty)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 500, minHeight: 500)
    }
}

struct EntryDetailSheet: View {
    let entry: KeyValueEntry
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack {
            EntryDetailView(entry: entry)
                .environmentObject(viewModel)
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

struct ClipboardHistorySheet: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""

    var filteredItems: [ClipboardHistoryItem] {
        if searchText.isEmpty {
            return viewModel.clipboardHistory
        }
        return viewModel.clipboardHistory.filter {
            $0.content.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("剪贴板历史")
                    .font(.title2.bold())
                Spacer()
                Button("清除历史") {
                    viewModel.clearClipboardHistory()
                }
                .buttonStyle(.bordered)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding()

            TextField("搜索...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            if filteredItems.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 36))
                        .foregroundStyle(.quaternary)
                    Text("暂无剪贴板历史")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(filteredItems) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 4) {
                                    if item.isPinned {
                                        Image(systemName: "pin.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                    Text(item.contentType.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if let source = item.sourceApplication {
                                        Text("· \(source)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Text(item.content)
                                    .lineLimit(3)
                                    .font(.caption)
                                Text(item.capturedAt.formatted(.relative(presentation: .named)))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer()

                            HStack(spacing: 4) {
                                Button {
                                    viewModel.toggleClipboardItemPin(id: item.id)
                                } label: {
                                    Image(systemName: item.isPinned ? "pin.slash" : "pin")
                                }
                                .buttonStyle(.borderless)

                                Button {
                                    viewModel.pasteFromHistory(item)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)

                                Button {
                                    viewModel.deleteClipboardHistoryItem(id: item.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

struct SettingsSheet: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss
    @State private var launchAtLogin = LaunchAtLoginHelper.isEnabled

    var body: some View {
        VStack(spacing: 16) {
            Text("设置")
                .font(.title2.bold())

            Form {
                Section("通用") {
                    Toggle("开机自动启动", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in
                            LaunchAtLoginHelper.setEnabled(newValue)
                        }
                    Toggle("启动时开始监控剪贴板", isOn: .constant(true))
                    Toggle("隐私模式", isOn: $viewModel.isPrivacyMode)
                }

                Section("存储") {
                    LabeledContent("存储位置") {
                        Text(viewModel.storageService.storageDirectory.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("存储大小") {
                        Text(viewModel.storageSizeFormatted)
                    }
                    LabeledContent("条目数量") {
                        Text("\(viewModel.totalEntryCount)")
                    }
                }

                Section("安全") {
                    LabeledContent("加密算法") {
                        Text("AES-256-GCM")
                    }
                    LabeledContent("主密钥") {
                        Text(viewModel.encryptionService.hasMasterKey ? "已设置" : "未设置")
                            .foregroundStyle(
                                viewModel.encryptionService.hasMasterKey ? .green : .red)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 450, minHeight: 420)
    }
}

struct GistSyncSheet: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss
    @State private var tokenInput = ""
    @State private var isValidating = false

    var body: some View {
        VStack(spacing: 16) {
            Text("GitHub Gist 同步")
                .font(.title2.bold())

            Form {
                Section("GitHub Token") {
                    SecureField("Personal Access Token", text: $tokenInput)
                    HStack {
                        Button("保存 Token") {
                            viewModel.saveGistToken(tokenInput)
                            tokenInput = ""
                        }
                        .disabled(tokenInput.isEmpty)

                        Button("验证 Token") {
                            isValidating = true
                            Task {
                                _ = await viewModel.validateGistToken()
                                isValidating = false
                            }
                        }
                        .disabled(isValidating || !viewModel.gistSyncService.hasToken)

                        if isValidating {
                            ProgressView()
                                .scaleEffect(0.7)
                        }
                    }

                    LabeledContent("Token 状态") {
                        Text(viewModel.gistSyncService.hasToken ? "已配置" : "未配置")
                            .foregroundStyle(viewModel.gistSyncService.hasToken ? .green : .red)
                    }
                }

                Section("同步配置") {
                    Toggle(
                        "仅同步收藏条目",
                        isOn: Binding(
                            get: { viewModel.gistSyncService.configuration.syncOnlyFavorites },
                            set: { viewModel.gistSyncService.configuration.syncOnlyFavorites = $0 }
                        ))
                    Toggle(
                        "排除私密条目",
                        isOn: Binding(
                            get: { viewModel.gistSyncService.configuration.syncOnlyNonPrivate },
                            set: { viewModel.gistSyncService.configuration.syncOnlyNonPrivate = $0 }
                        ))
                    Toggle(
                        "公开 Gist",
                        isOn: Binding(
                            get: { viewModel.gistSyncService.configuration.isPublic },
                            set: { viewModel.gistSyncService.configuration.isPublic = $0 }
                        ))
                }

                Section("同步操作") {
                    HStack {
                        Button("完整同步") {
                            Task { await viewModel.performGistSync() }
                        }
                        .disabled(viewModel.isSyncing || !viewModel.gistSyncService.hasToken)

                        Button("仅上传") {
                            Task { await viewModel.pushToGist() }
                        }
                        .disabled(viewModel.isSyncing || !viewModel.gistSyncService.hasToken)

                        Button("仅下载") {
                            Task { await viewModel.pullFromGist() }
                        }
                        .disabled(viewModel.isSyncing || !viewModel.gistSyncService.hasToken)
                    }

                    if let lastSync = viewModel.gistSyncService.configuration.lastFullSyncAt {
                        LabeledContent("上次同步") {
                            Text(lastSync.formatted(.relative(presentation: .named)))
                        }
                    }

                    if let result = viewModel.gistSyncService.lastSyncResult {
                        LabeledContent("上次结果") {
                            Text(result.summary)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 500, minHeight: 450)
    }
}

struct HotkeySettingsSheet: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("快捷键设置")
                .font(.title2.bold())

            // ── Accessibility Permission Status Banner ────────────────
            accessibilityBanner

            if viewModel.hotkeyService.bindings.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "keyboard")
                        .font(.system(size: 36))
                        .foregroundStyle(.quaternary)
                    Text("暂无已注册的快捷键")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(viewModel.hotkeyService.bindings) { binding in
                        HStack(spacing: 10) {
                            // Action icon
                            Image(systemName: binding.actionType.icon)
                                .font(.system(size: 15))
                                .foregroundStyle(iconColor(for: binding.actionType))
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(binding.name)
                                    .font(.headline)
                                Text(binding.actionType.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(binding.keyCombo.description)
                                .font(.system(.body, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.secondary.opacity(0.1))
                                )

                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { binding.isEnabled },
                                    set: { newValue in
                                        try? viewModel.hotkeyService.setBindingEnabled(
                                            id: binding.id, enabled: newValue)
                                    }
                                )
                            )
                            .labelsHidden()

                            Button(role: .destructive) {
                                try? viewModel.hotkeyService.removeBinding(id: binding.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Helpers

    private func iconColor(for type: HotkeyBinding.ActionType) -> Color {
        switch type {
        case .copyPassword: return .blue
        case .typePassword: return .purple
        case .showPopover: return .accentColor
        case .togglePrivacyMode: return .orange
        case .showClipboardHistory: return .teal
        case .quickSearch: return .indigo
        case .captureScreenshot: return .green
        case .ocrScreenshot: return .mint
        case .custom: return .secondary
        }
    }

    // MARK: - Accessibility Permission Banner

    @ViewBuilder
    private var accessibilityBanner: some View {
        if viewModel.isAccessibilityGranted {
            // ✅ Permission granted
            HStack(spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                Text("辅助功能权限已授予")
                    .font(.subheadline.bold())
                    .foregroundStyle(.green)
                Spacer()
                Text("键盘模拟功能可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.green.opacity(0.25), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
        } else {
            // ❌ Permission NOT granted — compact banner with guide button
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text("需要辅助功能权限")
                        .font(.subheadline.bold())
                    Text("模拟键盘输入功能需要系统授权")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    viewModel.showAccessibilityGuide = true
                    ClipboardService.shared.startAccessibilityPolling(timeoutSeconds: 300)
                } label: {
                    Label("查看授权指引", systemImage: "questionmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    viewModel.refreshAccessibilityPermission()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                    )
            )
            .padding(.horizontal)
        }
    }
}

struct QuickSearchSheet: View {
    @EnvironmentObject var viewModel: AppViewModel
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""

    var results: [KeyValueEntry] {
        if searchText.isEmpty {
            return viewModel.favoriteEntries
        }
        return viewModel.storageService.searchEntries(query: searchText)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("快速搜索...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.title3)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if results.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text(searchText.isEmpty ? "输入关键词开始搜索" : "未找到匹配的条目")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List {
                    ForEach(results) { entry in
                        Button {
                            viewModel.copyEntryValue(id: entry.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: entry.category.iconName)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.headline)
                                    Text(entry.key)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if entry.isFavorite {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(.yellow)
                                        .font(.caption)
                                }

                                Text("复制")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .frame(width: 500, height: 350)
    }
}

struct AboutSheet: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var updater = UpdateService.shared
    @State private var showDonate = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── App Info ──
            VStack(spacing: 14) {
                Spacer().frame(height: 8)

                // App Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.white)
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                        .frame(width: 72, height: 72)

                    // K🔒V symbol
                    HStack(spacing: 2) {
                        Text("K")
                            .font(.system(size: 22, weight: .bold, design: .serif))
                            .foregroundStyle(Color(red: 0.20, green: 0.24, blue: 0.35))
                        Image(systemName: "lock.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(red: 0.80, green: 0.65, blue: 0.20))
                        Text("V")
                            .font(.system(size: 22, weight: .bold, design: .serif))
                            .foregroundStyle(Color(red: 0.20, green: 0.24, blue: 0.35))
                    }
                }

                Text("KeyValue")
                    .font(.title.bold())

                Text("版本 \(appVersion) (\(buildNumber))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("安全的密码和键值对管理工具")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                // Feature pills
                HStack(spacing: 8) {
                    featurePill("加密存储", icon: "lock.shield")
                    featurePill("快捷键入", icon: "keyboard")
                    featurePill("Gist 同步", icon: "icloud")
                }

                Text("© 2024-2025 KeyValue Contributors · MIT License")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Divider()
                .padding(.vertical, 12)

            // ── Donate & Links ──
            if showDonate {
                donateView
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                linksView
            }

            Spacer().frame(height: 12)

            // ── Close ──
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        .frame(width: 480, height: showDonate ? 500 : 540)
        .animation(.easeInOut(duration: 0.3), value: showDonate)
    }

    // MARK: - Feature Pill

    private func featurePill(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule().fill(.quaternary.opacity(0.5))
            }
    }

    // MARK: - Links View

    // MARK: - Update Section

    @ViewBuilder
    private var updateSection: some View {
        VStack(spacing: 8) {
            // ── Install method + current version row ──
            HStack(spacing: 6) {
                Image(systemName: updater.installMethod.icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(updater.installMethod.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("当前 v\(appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = updater.lastChecked {
                    Text("· 上次检查 \(last, style: .relative)前")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // ── Status row ──
            switch updater.state {
            case .idle, .upToDate:
                HStack {
                    if updater.state == .upToDate {
                        Label("已是最新版本", systemImage: "checkmark.seal.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Button {
                        Task { await updater.checkForUpdates(force: true) }
                    } label: {
                        Label("检查更新", systemImage: "arrow.clockwise")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在检查更新…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

            case .available(let version, _):
                VStack(spacing: 6) {
                    HStack {
                        Label("发现新版本 v\(version)", systemImage: "arrow.up.circle.fill")
                            .font(.callout.bold())
                            .foregroundStyle(.orange)
                        Spacer()
                        Button {
                            Task { await updater.checkForUpdates(force: true) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    }
                    Button {
                        Task { await updater.performUpdate() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(
                                {
                                    if case .homebrew = updater.installMethod {
                                        return "通过 Homebrew 更新"
                                    }
                                    if case .sourceTree = updater.installMethod {
                                        return "通过 Git 更新"
                                    }
                                    return "下载并安装更新"
                                }()
                            )
                            .bold()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.regular)
                }

            case .downloading(let version, let progress):
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    HStack {
                        Text("正在下载 v\(version)…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            updater.cancelDownload()
                        } label: {
                            Label("取消", systemImage: "xmark.circle")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }

            case .installing(let version):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在安装 v\(version)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

            case .updating:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(
                        {
                            if case .homebrew = updater.installMethod {
                                return "正在运行 brew update && brew upgrade…"
                            }
                            return "正在运行 git pull…"
                        }()
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Spacer()
                }

            case .success(let version):
                HStack(spacing: 8) {
                    Label(
                        version == "latest"
                            ? "代码已更新，请重新构建"
                            : "更新成功！正在重启…",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(.green)
                    Spacer()
                }

            case .failed(let msg):
                VStack(alignment: .leading, spacing: 6) {
                    Label("更新失败", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.bold())
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await updater.checkForUpdates(force: true) }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                            .font(.callout)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.07))
        )
    }

    private var linksView: some View {
        VStack(spacing: 12) {
            // ── Update Section ──
            updateSection

            Divider()

            // ── External Links ──
            HStack(spacing: 16) {
                linkButton(
                    "GitHub", icon: "chevron.left.forwardslash.chevron.right",
                    url: "https://github.com/aresnasa/mac-keyvalue")

                linkButton(
                    "反馈问题", icon: "exclamationmark.bubble",
                    url: "https://github.com/aresnasa/mac-keyvalue/issues")
            }

            Button {
                withAnimation { showDonate = true }
            } label: {
                HStack(spacing: 6) {
                    Text("☕")
                    Text("请作者喝杯咖啡")
                        .font(.callout.bold())
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .controlSize(.large)
        }
    }

    // MARK: - Donate View

    private var donateView: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                Text("☕")
                    .font(.title2)
                Text("请作者喝杯咖啡")
                    .font(.headline)
            }

            Text("如果 KeyValue 对你有帮助，\n欢迎扫码支持项目的持续开发 ❤️")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // ── Alipay QR code ────────────────────────────────────────
            donateQRCard(
                named: "donate_alipay",
                label: "支付宝",
                accentColor: Color(red: 0.02, green: 0.56, blue: 0.98)
            )

            Text("扫码即可赞赏，感谢支持！")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Button {
                withAnimation { showDonate = false }
            } label: {
                Text("返回")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - QR Code Placeholder

    /// Generates a visual placeholder for the donate QR code.
    /// Replace the `qrImage` logic below with an actual QR code image
    /// by adding a `donate_qr.png` to the Resources folder.
    /// Renders a single QR code card for the given resource name.
    /// - `named`: bare filename without extension, e.g. `"donate_wechat"`
    /// - `label`: human-readable label shown below the card
    /// - `accentColor`: border / label accent colour
    private func donateQRCard(named: String, label: String, accentColor: Color) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white)
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(accentColor.opacity(0.25), lineWidth: 1.5)
                    )
                    .frame(width: 150, height: 150)

                if let qrImage = loadQRImage(named: named) {
                    Image(nsImage: qrImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 130, height: 130)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 40))
                            .foregroundStyle(accentColor.opacity(0.35))
                        Text("待添加\n\(named).png")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
            }

            // Label pill
            HStack(spacing: 4) {
                Circle()
                    .fill(accentColor)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Attempts to load a QR code image from the app bundle by resource name.
    ///
    /// **Placement**: add the PNG files to `MacKeyValue/Resources/`:
    /// - `donate_wechat.png`  — WeChat Pay QR code
    /// - `donate_alipay.png`  — Alipay QR code
    ///
    /// The build script (build.sh) copies `Resources/` into the .app bundle,
    /// so placing the files there is sufficient for both dev and release builds.
    private func loadQRImage(named resourceName: String) -> NSImage? {
        // 1. Bundle resource (release / Xcode build)
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
            let img = NSImage(contentsOf: url)
        {
            return img
        }
        // 2. Dev-build search paths (swift run / bare executable)
        let candidates: [String] = [
            resourceName + ".png",
            "Resources/" + resourceName + ".png",
            "../Resources/" + resourceName + ".png",
            "MacKeyValue/Resources/" + resourceName + ".png",
        ]
        for path in candidates {
            if let img = NSImage(contentsOfFile: path) { return img }
        }
        return nil
    }

    // MARK: - Link Button

    private func linkButton(_ title: String, icon: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        } label: {
            Label(title, systemImage: icon)
                .font(.callout)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}
