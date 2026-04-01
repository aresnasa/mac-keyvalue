import SwiftUI

// MARK: - CompactView

/// A slim, efficiency-first interface for quick copy / paste / type operations.
///
/// Designed as the default daily-driver UI:
/// - **Search bar** at the top for instant filtering
/// - **Flat list** of entries with one-tap action buttons
/// - **No sidebar, no detail pane** — every operation is at most one click away
/// - The user switches to `.full` mode only when they need to create or edit entries
struct CompactView: View {
    @EnvironmentObject var viewModel: AppViewModel

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // ── Search + Mode Toggle ──
            headerBar

            Divider()

            // ── Entry List ──
            if viewModel.compactFilteredEntries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(viewModel.compactFilteredEntries) { entry in
                            CompactEntryRow(entry: entry)
                                .environmentObject(viewModel)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            // ── Status Bar ──
            statusBar
        }
        .frame(minWidth: 380, minHeight: 300)
        .onAppear {
            // Auto-focus the search field for keyboard-driven workflow.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("搜索条目… (正则: /pattern/)", text: $viewModel.compactSearchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($isSearchFocused)

                if !viewModel.compactSearchText.isEmpty {
                    Button {
                        viewModel.compactSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.5))
            }

            // Add entry button
            Button {
                viewModel.prepareNewEntry()
                viewModel.uiMode = .full
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("新建条目（切换到管理模式）")

            // Mode toggle
            Button {
                viewModel.toggleUIMode()
            } label: {
                Image(systemName: "rectangle.expand.vertical")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("切换到管理模式")

            // Quick menu
            Menu {
                Button {
                    viewModel.activeSheet = .importData
                } label: {
                    Label("导入数据…", systemImage: "square.and.arrow.down")
                }
                Button {
                    viewModel.activeSheet = .exportData
                } label: {
                    Label("导出数据…", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button("设置…") { viewModel.activeSheet = .settings }
                Button("关于") { viewModel.activeSheet = .about }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("更多选项")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            if viewModel.entries.isEmpty {
                Image(systemName: "tray")
                    .font(.system(size: 36))
                    .foregroundStyle(.quaternary)
                Text("还没有条目")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("新建条目") {
                    viewModel.prepareNewEntry()
                    viewModel.uiMode = .full
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundStyle(.quaternary)
                Text("没有匹配的条目")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("尝试其他搜索词")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Text("\(viewModel.entries.count) 条记录")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            if viewModel.isPrivacyMode {
                Label("隐私", systemImage: "lock.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(Color(red: 0.80, green: 0.65, blue: 0.20))
            }

            if !viewModel.isAccessibilityGranted {
                Button {
                    viewModel.showAccessibilityGuide = true
                } label: {
                    Label("需要权限", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - CompactEntryRow

/// A single entry row in the compact list, with inline action buttons.
struct CompactEntryRow: View {
    @EnvironmentObject var viewModel: AppViewModel
    let entry: KeyValueEntry

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // Category icon
            Image(systemName: entry.category.iconName)
                .font(.caption)
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(iconColor.opacity(0.1))
                }

            // Title + key + hotkey badge
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(entry.title)
                        .font(.callout.bold())
                        .lineLimit(1)

                    if entry.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.yellow)
                    }
                    if entry.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color(red: 0.80, green: 0.65, blue: 0.20))
                    }
                }
                HStack(spacing: 6) {
                    Text(entry.key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    // Show bound hotkey if any
                    if let binding = viewModel.hotkeyService.bindings.first(where: {
                        $0.entryId == entry.id
                    }) {
                        Text(binding.keyCombo.description)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.orange.opacity(0.1))
                            )
                    }
                }
            }

            Spacer()

            // ── Action Buttons ── (visible on hover)
            if isHovered {
                actionButtons
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.accentColor.opacity(0.06) : Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            contextMenuItems
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 4) {
            // Copy
            ActionButton(icon: "doc.on.doc", label: "复制", color: .accentColor) {
                viewModel.copyEntryValue(id: entry.id)
            }

            // Paste (Cmd+V simulation)
            ActionButton(icon: "doc.on.clipboard", label: "粘贴", color: .green) {
                viewModel.pasteEntryValue(id: entry.id)
            }

            // Type (character-by-character)
            if entry.category == .password {
                ActionButton(icon: "keyboard", label: "键入", color: .orange) {
                    viewModel.typeEntryValue(id: entry.id)
                }
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("复制值") {
            viewModel.copyEntryValue(id: entry.id)
        }
        Button("粘贴到目标窗口") {
            viewModel.pasteEntryValue(id: entry.id)
        }
        Button("模拟键入到目标窗口") {
            viewModel.typeEntryValue(id: entry.id)
        }
        Divider()
        Button("编辑…") {
            viewModel.uiMode = .full
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                viewModel.prepareEditEntry(entry)
            }
        }
        Button(entry.isFavorite ? "取消收藏" : "收藏") {
            viewModel.toggleFavorite(id: entry.id)
        }
        Divider()
        Button("删除", role: .destructive) {
            viewModel.deleteEntry(id: entry.id)
        }
    }

    // MARK: - Helpers

    private var iconColor: Color {
        switch entry.category {
        case .password: return .red
        case .snippet: return .purple
        case .clipboard: return .blue
        case .command: return .green
        case .other: return .gray
        }
    }
}

// MARK: - ActionButton

/// A tiny icon-only button used in compact entry rows.
private struct ActionButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 26, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color.opacity(0.1))
                }
        }
        .buttonStyle(.plain)
        .help(label)
    }
}

// MARK: - Preview

#if DEBUG
struct CompactView_Previews: PreviewProvider {
    static var previews: some View {
        CompactView()
            .environmentObject(AppViewModel())
            .frame(width: 420, height: 500)
    }
}
#endif
