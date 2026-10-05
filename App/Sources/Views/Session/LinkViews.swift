import SwiftUI
import WaitingPawsCore

/// Top-bar indicator of the iPhone ↔ Mac link: on the Mac — which iPhones are connected,
/// on the iPhone — which computer the training runs on (menu: switch to another one, disconnect).
struct LinkPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        #if os(macOS)
        let devices = model.syncHost.connectedDevices
        if let first = devices.first {
            Pill(text: devices.count == 1 ? first.name : "\(first.kindTitle) × \(devices.count)",
                 systemImage: first.symbolName, tint: Theme.info)
                .help(devices.count == 1 ? String(localized: "«\(first.name)» видит камеру и ведёт эту тренировку")
                                         : String(localized: "Камеру видят и ведут тренировку: \(devices.map(\.name).joined(separator: ", "))"))
        }
        #else
        let client = model.syncClient
        switch client.status {
        case .connected(let host):
            Menu {
                Section {
                    Text("Тренировка синхронизирована с «\(host.name)»")
                    if let hostModel = host.distinctModel { Text(hostModel) }
                    Text("Камера, запись и лог — на \(host.kindTitle)")
                }
                let others = client.compatibleHosts.filter { $0.id != host.id }
                if model.session == nil, !others.isEmpty {
                    Section("Переключиться на") {
                        ForEach(others) { other in
                            Button { client.connect(to: other) } label: {
                                Text(other.device.name)
                                Text(HostText.detail(other, paired: client.isPaired(other.device)))
                                Image(systemName: other.device.symbolName)
                            }
                        }
                    }
                }
                Button("Отключить синхронизацию", systemImage: "xmark.circle", role: .destructive) {
                    client.disconnect()
                }
            } label: {
                // The top bar has no room for a name («MacBoo…»): the tooltip after joining and this menu name the host.
                Pill(text: host.kindTitle, systemImage: host.symbolName, tint: Theme.info)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .anchorPreference(key: LinkPillAnchorKey.self, value: .bounds) { $0 }
        case .connecting(let host), .waitingApproval(let host):
            Pill(text: "\(host.kindTitle)…", systemImage: "hourglass", tint: Theme.info)
        case .idle, .failed:
            EmptyView()
        }
        #endif
    }

}

#if os(iOS)
/// Detail lines about a host for the choice lists: model, camera or training, whether this iPhone joined it before.
enum HostText {
    static func detail(_ host: SyncClient.DiscoveredHost, paired: Bool) -> String {
        var parts: [String] = []
        if let model = host.device.distinctModel { parts.append(model) }
        if host.info.sessionRunning {
            parts.append(host.info.currentExit.map { String(localized: "идёт тренировка, выход \($0)") }
                         ?? String(localized: "тренировка идёт"))
        } else if !host.info.cameraTitle.isEmpty {
            parts.append(host.info.cameraReady ? String(localized: "камера «\(host.info.cameraTitle)»")
                                               : String(localized: "камера «\(host.info.cameraTitle)» не в сети"))
        }
        if !host.isCompatible {
            parts.append(String(localized: "другая версия Waiting Paws"))
        } else if paired {
            parts.append(String(localized: "уже подключались"))
        }
        return parts.joined(separator: " · ")
    }
}

/// «Синхронизировать с …» in a menu: one computer around — one item, several — a submenu to pick from.
struct HostChoiceMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let client = model.syncClient
        let hosts = client.compatibleHosts
        if hosts.count == 1, let host = hosts.first {
            Button("Синхронизировать с «\(host.device.name)»", systemImage: host.device.symbolName) {
                client.connect(to: host)
            }
        } else if hosts.count > 1 {
            Menu("Синхронизировать с…", systemImage: "laptopcomputer.and.iphone") {
                ForEach(hosts) { host in
                    Button { client.connect(to: host) } label: {
                        Text(host.device.name)
                        Text(HostText.detail(host, paired: client.isPaired(host.device)))
                        Image(systemName: host.device.symbolName)
                    }
                }
            }
        }
    }
}

/// "Mac рядом": offers to join a computer that runs Waiting Paws on the same network — its camera is already
/// signed in, and if a training runs there, the iPhone joins it as a remote with the same camera. With several
/// around (two Macs at home, later a PC), the card lists them to pick from.
struct MacLinkCard: View {
    @Environment(AppModel.self) private var model
    /// Hosts closed with ✕ (until the next launch).
    @State private var dismissed: Set<String> = []

    var body: some View {
        let client = model.syncClient
        switch client.status {
        case .connecting(let host), .waitingApproval(let host):
            GlassCard(padding: 18) {
                HStack(spacing: 14) {
                    ProgressView().tint(Theme.info)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isWaiting ? "Подтвердите на \(host.kindTitle)" : "Синхронизируем с \(host.kindTitle)")
                            .font(Theme.display(18, weight: .bold))
                        // Names both ends: on the computer the prompt shows this iPhone under the same name.
                        Text(isWaiting ? "На «\(host.name)» появился запрос от «\(model.settings.linkName)» — нажмите «Разрешить». Это нужно один раз для этого iPhone."
                                       : "«\(host.name)»")
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
            let offers = client.compatibleHosts.filter { !dismissed.contains($0.id) }
            if model.session == nil, let first = offers.first {
                if offers.count == 1 {
                    offer(first)
                } else {
                    choice(offers)
                }
            }
        }
    }

    private var isWaiting: Bool {
        if case .waitingApproval = model.syncClient.status { return true }
        return false
    }

    @ViewBuilder
    private var failure: some View {
        if case .failed(let message) = model.syncClient.status {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(.footnote, design: .rounded))
                .foregroundStyle(Theme.warning)
        }
    }

    private func offer(_ host: SyncClient.DiscoveredHost) -> some View {
        let kind = host.device.kindTitle
        return GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: host.device.symbolName)
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.info)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(host.info.sessionRunning ? "На \(kind) идёт тренировка" : "Рядом \(kind) с Waiting Paws")
                            .font(Theme.display(20, weight: .bold))
                        Text(subtitle(host))
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                    IconButton(systemImage: "xmark") { dismissed.insert(host.id) }
                }
                failure
                BigButton(title: String(localized: "Синхронизировать тренировку с \(kind)"),
                          systemImage: "arrow.triangle.2.circlepath") {
                    model.syncClient.connect(to: host)
                }
            }
        }
    }

    private func subtitle(_ host: SyncClient.DiscoveredHost) -> String {
        var parts = [String(localized: "«\(host.device.name)»")]
        if let model = host.device.distinctModel { parts.append(model) }
        if !host.info.cameraTitle.isEmpty {
            parts.append(host.info.cameraReady ? String(localized: "камера «\(host.info.cameraTitle)»")
                                               : String(localized: "камера «\(host.info.cameraTitle)» не в сети"))
        }
        if host.info.sessionRunning, let exit = host.info.currentExit { parts.append(String(localized: "выход \(exit)")) }
        if !host.info.sessionRunning { parts.append(String(localized: "вход в Xiaomi уже выполнен на \(host.device.kindTitle)")) }
        return parts.joined(separator: " · ")
    }

    /// Several computers nearby: which one to sync with (the likely one first). Compact — it shares the screen with
    /// the camera.
    private func choice(_ hosts: [SyncClient.DiscoveredHost]) -> some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.info)
                    Text("Синхронизировать с…")
                        .font(Theme.display(18, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    IconButton(systemImage: "xmark") { dismissed.formUnion(hosts.map(\.id)) }
                }
                failure
                VStack(spacing: 6) {
                    ForEach(hosts) { host in
                        HostChoiceRow(host: host, paired: model.syncClient.isPaired(host.device)) {
                            model.syncClient.connect(to: host)
                        }
                    }
                }
            }
        }
    }
}

/// One computer in the choice card: its kind's icon, name, and what is going on there.
private struct HostChoiceRow: View {
    let host: SyncClient.DiscoveredHost
    let paired: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: host.device.symbolName)
                    .font(.system(size: 22))
                    .foregroundStyle(host.info.sessionRunning ? Theme.info : .white.opacity(0.8))
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.device.name)
                        .font(.system(.headline, design: .rounded))
                        .lineLimit(1)
                    Text(HostText.detail(host, paired: paired))
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }
}

/// The schedule waiting on the linked Mac — pasted there or on this iPhone; start it from either side.
struct MacPendingPlanCard: View {
    @Environment(AppModel.self) private var model
    let plan: TrainingPlan
    var onEdit: () -> Void
    var onPaste: () -> Void

    var body: some View {
        GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("СЕГОДНЯ")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.5))
                    Label("и на \(model.linkedHostKind)", systemImage: "laptopcomputer.and.iphone")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.info)
                    Spacer()
                    IconButton(systemImage: "xmark") { model.sharePlanWithMac(nil) }
                        .accessibilityLabel("Убрать расписание")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.title)
                        .font(Theme.display(22, weight: .bold))
                        .lineLimit(2)
                    Text(summary)
                        .font(.system(.subheadline, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
                BigButton(title: String(localized: "Начать тренировку"), systemImage: "play.fill") {
                    var final = plan
                    final.renumber()
                    model.startSession(with: final)
                }
                HStack(spacing: 8) {
                    BigButton(title: String(localized: "Изменить"), systemImage: "slider.horizontal.3", style: .secondary, height: 44, action: onEdit)
                    BigButton(title: String(localized: "Другое"), systemImage: "doc.on.clipboard", style: .secondary, height: 44, action: onPaste)
                }
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if !plan.trainers.isEmpty { parts.append(plan.trainers) }
        parts.append(pluralText(plan.exits.count, ru: ("вых.", "вых.", "вых."), en: ("exit", "exits")))
        parts.append("≈ \(DurationText.short((plan.estimatedDuration / 60).rounded() * 60))")
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
