import SwiftUI
import WaitingPawsCore

/// Top-bar indicator of the iPhone ↔ Mac link: on the Mac — which iPhones are connected,
/// on the iPhone — which Mac the training runs on (menu: disconnect).
struct LinkPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        #if os(macOS)
        if !model.syncHost.connectedDevices.isEmpty {
            Pill(text: model.syncHost.connectedDevices.count == 1 ? model.syncHost.connectedDevices[0] : "iPhone × \(model.syncHost.connectedDevices.count)",
                 systemImage: "iphone", tint: Theme.info)
                .help("iPhone видит камеру и ведёт эту тренировку")
        }
        #else
        switch model.syncClient.status {
        case .connected(let name):
            Menu {
                Text("Тренировка синхронизирована с «\(name)»")
                Text("Камера, запись и лог — на Mac")
                Button("Отключить синхронизацию", systemImage: "xmark.circle", role: .destructive) {
                    model.syncClient.disconnect()
                }
            } label: {
                Pill(text: "Mac", systemImage: "laptopcomputer", tint: Theme.info)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .anchorPreference(key: LinkPillAnchorKey.self, value: .bounds) { $0 }
        case .connecting, .waitingApproval:
            Pill(text: "Mac…", systemImage: "hourglass", tint: Theme.info)
        case .idle, .failed:
            EmptyView()
        }
        #endif
    }
}

#if os(iOS)
/// "Mac рядом": offers to join a Mac that runs Waiting Paws on the same network — its camera is already
/// signed in, and if a training runs there, the iPhone joins it as a remote with the same camera.
struct MacLinkCard: View {
    @Environment(AppModel.self) private var model
    @State private var dismissed: String?

    var body: some View {
        let client = model.syncClient
        switch client.status {
        case .connecting(let name), .waitingApproval(let name):
            GlassCard(padding: 18) {
                HStack(spacing: 14) {
                    ProgressView().tint(Theme.info)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isWaiting ? "Подтвердите на Mac" : "Синхронизируем с Mac")
                            .font(Theme.display(18, weight: .bold))
                        Text(isWaiting ? "На «\(name)» появился запрос — нажмите «Разрешить». Это нужно один раз для этого iPhone."
                                       : "«\(name)»")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                    IconButton(systemImage: "xmark") { client.disconnect() }
                }
            }
        case .connected:
            // Said once by the tooltip under the «Mac» pill (`LinkNoticeOverlay`), not by a card that stays.
            EmptyView()
        case .idle, .failed:
            if model.session == nil, let mac = client.bestMac, dismissed != mac.info.name {
                offer(mac)
            }
        }
    }

    private var isWaiting: Bool {
        if case .waitingApproval = model.syncClient.status { return true }
        return false
    }

    private func offer(_ mac: SyncClient.DiscoveredMac) -> some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.info)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(mac.info.sessionRunning ? "На Mac идёт тренировка" : "Рядом Mac с Waiting Paws")
                            .font(Theme.display(20, weight: .bold))
                        Text(subtitle(mac))
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                    IconButton(systemImage: "xmark") { dismissed = mac.info.name }
                }
                if case .failed(let message) = model.syncClient.status {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(Theme.warning)
                }
                BigButton(title: "Синхронизировать тренировку с Mac",
                          systemImage: "arrow.triangle.2.circlepath") {
                    model.syncClient.connect(to: mac)
                }
            }
        }
    }

    private func subtitle(_ mac: SyncClient.DiscoveredMac) -> String {
        var parts = ["«\(mac.info.name)»"]
        if !mac.info.cameraTitle.isEmpty { parts.append("камера «\(mac.info.cameraTitle)»" + (mac.info.cameraReady ? "" : " не в сети")) }
        if mac.info.sessionRunning, let exit = mac.info.currentExit { parts.append("выход \(exit)") }
        if !mac.info.sessionRunning { parts.append("вход в Xiaomi уже выполнен на Mac") }
        return parts.joined(separator: " · ")
    }
}

/// Where the «Mac» pill is, for the tooltip under it.
struct LinkPillAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

/// A short tooltip under the «Mac» pill: «Синхронизировано с …» after joining, «Видео сохранено на Mac»
/// after a recording there. Fades after a few seconds, a tap closes it at once.
struct LinkNoticeOverlay: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(LinkPillAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    if let anchor, let notice = model.linkNotice {
                        let pill = proxy[anchor]
                        // Right edge under the pill's, but always on screen.
                        let width = min(290, proxy.size.width - 24)
                        let left = max(12, min(pill.maxX, proxy.size.width - 12) - width)
                        LinkNoticeBubble(notice: notice, arrowX: pill.midX - left)
                            .frame(width: width)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .offset(x: left, y: pill.maxY + 6)
                            .onTapGesture { model.linkNotice = nil }
                            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
                            .id(notice.id)
                    }
                }
                .animation(.smooth(duration: 0.3), value: model.linkNotice)
            }
            .task(id: model.linkNotice?.id) {
                guard model.linkNotice != nil else { return }
                // A newer notice cancels this wait: it must not clear that one.
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                model.linkNotice = nil
            }
    }
}

private struct LinkNoticeBubble: View {
    let notice: LinkNotice
    /// Where the arrow points, from the bubble's leading edge.
    let arrowX: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Triangle()
                .fill(Theme.panel)
                .frame(width: 16, height: 8)
                .offset(x: arrowX - 8)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.info)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    Text(notice.detail)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
#endif
