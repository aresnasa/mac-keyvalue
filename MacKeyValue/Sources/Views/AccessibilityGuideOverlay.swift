import SwiftUI

// MARK: - AccessibilityGuideOverlay

/// A streamlined two-step overlay that guides the user through granting
/// **both** macOS permissions in a single flow:
///
/// 1. **辅助功能 (Accessibility)** → click "一键授权" → opens settings
/// 2. **输入监控 (Input Monitoring)** → click "下一步" → opens settings
/// 3. **重启应用** → applies both permissions
struct AccessibilityGuideOverlay: View {
    @EnvironmentObject var viewModel: AppViewModel

    /// 0 = initial, 1 = accessibility opened, 2 = input monitoring opened
    @State private var currentStep: Int = 0
    @State private var showSuccess: Bool = false
    @State private var isGranting: Bool = false
    @State private var pulseToggle: Bool = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            if showSuccess {
                successView
                    .transition(.scale.combined(with: .opacity))
            } else {
                mainCard
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showSuccess)
        .animation(.easeInOut(duration: 0.3), value: currentStep)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                pulseToggle = true
            }
        }
        .onChange(of: viewModel.isAccessibilityGranted) { granted in
            if granted {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    showSuccess = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { viewModel.showAccessibilityGuide = false }
                }
            }
        }
    }

    // MARK: - Main Card

    private var mainCard: some View {
        VStack(spacing: 16) {
            // ── Header ──
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.orange.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.orange)
                    }
                    Text("+")
                        .font(.headline)
                        .foregroundStyle(.tertiary)
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.12))
                            .frame(width: 40, height: 40)
                        Image(systemName: "keyboard.badge.eye")
                            .font(.system(size: 16))
                            .foregroundStyle(.blue)
                    }
                }
                .scaleEffect(pulseToggle ? 1.05 : 1.0)
                .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true), value: pulseToggle)

                Text("需要授权两项系统权限")
                    .font(.headline)
                Text("依次打开两个设置页面，开启开关后重启应用即可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // ── Step indicators ──
            HStack(spacing: 0) {
                stepIndicator(num: 1, title: "辅助功能", done: currentStep >= 1)
                stepConnector(done: currentStep >= 1)
                stepIndicator(num: 2, title: "输入监控", done: currentStep >= 2)
                stepConnector(done: currentStep >= 2)
                stepIndicator(num: 3, title: "重启", done: false, isFinal: true)
            }
            .padding(.vertical, 4)

            // ── Action area ──
            VStack(spacing: 10) {
                switch currentStep {
                case 0:
                    // Initial: open accessibility
                    actionButton(
                        icon: "hand.raised.fill",
                        color: .orange,
                        title: "① 打开「辅助功能」设置",
                        subtitle: "找到 MacKeyValue 并打开开关"
                    ) {
                        performStep1()
                    }

                case 1:
                    // Accessibility opened, now open input monitoring
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("辅助功能设置已打开")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    actionButton(
                        icon: "keyboard.badge.eye",
                        color: .blue,
                        title: "② 打开「输入监控」设置",
                        subtitle: "找到 MacKeyValue 并打开开关"
                    ) {
                        performStep2()
                    }

                default:
                    // Both opened, show restart
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("两个设置页面都已打开")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        relaunchApp()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("③ 重启应用使权限生效")
                                    .font(.callout.bold())
                                Text("两个开关都打开后点击这里")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.large)
                }

                // Re-open buttons (always available after step 1)
                if currentStep >= 1 {
                    HStack(spacing: 8) {
                        Button {
                            ClipboardService.shared.openAccessibilitySystemSettings()
                        } label: {
                            Label("辅助功能", systemImage: "hand.raised")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            ClipboardService.shared.openInputMonitoringSystemSettings()
                        } label: {
                            Label("输入监控", systemImage: "keyboard.badge.eye")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if currentStep < 2 {
                            Spacer()
                            Button {
                                relaunchApp()
                            } label: {
                                Label("重启", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(.green)
                            .controlSize(.small)
                        }
                    }
                }
            }

            // ── Dismiss ──
            Button {
                withAnimation { viewModel.showAccessibilityGuide = false }
            } label: {
                Text("稍后再说")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 400)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        }
    }

    // MARK: - Step Indicator

    private func stepIndicator(num: Int, title: String, done: Bool, isFinal: Bool = false) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.2))
                    .frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(num)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(done ? .white : .secondary)
                }
            }
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(done ? .primary : .tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func stepConnector(done: Bool) -> some View {
        Rectangle()
            .fill(done ? Color.green.opacity(0.5) : Color.secondary.opacity(0.15))
            .frame(height: 2)
            .frame(maxWidth: 30)
            .offset(y: -8)
    }

    // MARK: - Action Button

    private func actionButton(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.bold())
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(color)
        .controlSize(.large)
        .disabled(isGranting)
    }

    // MARK: - Actions

    private func performStep1() {
        isGranting = true
        ClipboardService.shared.autoGrantAccessibility { _ in
            isGranting = false
            withAnimation { currentStep = 1 }
        }
    }

    private func performStep2() {
        ClipboardService.shared.openInputMonitoringSystemSettings()
        withAnimation { currentStep = 2 }
    }

    // MARK: - Success

    private var successView: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
            }
            Text("权限已授予 ✅")
                .font(.title3.bold())
            Text("键盘模拟功能已可用！")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        }
    }

    // MARK: - Relaunch

    private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let execPath = Bundle.main.executablePath
            ?? ProcessInfo.processInfo.arguments.first ?? ""

        if bundlePath.hasSuffix(".app") {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", bundlePath]
            try? task.run()
        } else {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", "sleep 0.5 && \"\(execPath)\" &"]
            try? task.run()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct AccessibilityGuideOverlay_Previews: PreviewProvider {
    static var previews: some View {
        AccessibilityGuideOverlay()
            .environmentObject(AppViewModel())
            .frame(width: 600, height: 500)
    }
}
#endif
