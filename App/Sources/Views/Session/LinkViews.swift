import SwiftUI
import WaitingPawsCore

/// Top-bar indicator of the iPhone ↔ Mac link: on the Mac — which iPhones are connected,
/// on the iPhone — which computer the training runs on (menu: switch to another one, disconnect).
struct LinkPill: View {
    @Environment(AppModel.self) private var model
    /// iPhone: folds to the computer's icon where the top bar has no room for «Mac» (small iPhones).
    var foldsToIcon = false
    /// iPhone: the joined computer's card (`LinkedMacCard`) is open.
    @State private var showsCard = false

    var body: some View {
        #if os(macOS)
        let devices = model.syncHost.connectedDevices
        if let first = devices.first {
            if devices.count == 1 {
                Pill(text: first.name, systemImage: first.symbolName, tint: Theme.info)
                    .help(String(localized: "“\(first.name)” sees the camera and runs this training"))
            } else {
                // Several iPhones: which one runs the training and which only watch (lab `Design/link-ui-lab`, 4A).
                Button { showsCard = true } label: {
                    Pill(text: "\(first.kindTitle) × \(devices.count)", systemImage: first.symbolName, tint: Theme.info)
                }
                .buttonStyle(.plain)
                .help(String(localized: "iPhones in this training"))
                .popover(isPresented: $showsCard, arrowEdge: .bottom) {
                    MacLinkedPhones().environment(model)
                }
            }
        }
        #else
        let client = model.syncClient
        if let host = client.reconnecting {
            // The link dropped mid-training: the bubble under the pill says so (`LinkNoticeOverlay`); the card shows
            // how long, and gives up.
            Button { showsCard = true } label: {
                label("\(host.kindTitle)…", systemImage: "wifi.exclamationmark", tint: Theme.warning)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsCard, arrowEdge: .top) {
                LinkedMacCard(host: host, reconnecting: true) { showsCard = false }
                    .presentationCompactAdaptation(.popover)
            }
            .anchorPreference(key: LinkPillAnchorKey.self, value: .bounds) { $0 }
        } else {
            linkStatus(client)
        }
        #endif
    }

    #if os(iOS)
    /// «Mac», or only its icon when that is all that fits. `online`: Macs joined before that are on the network now
    /// — a green dot for the joined one, their number when there are more (lab `Design/link-ui-lab`, 3A).
    private func label(_ text: String, systemImage: String, tint: Color, online: Int = 0) -> some View {
        ViewThatFits(in: .horizontal) {
            Pill(text: text, systemImage: systemImage, tint: tint)
            if foldsToIcon {
                Pill(text: text, systemImage: systemImage, tint: tint, iconOnly: true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if online > 1 {
                Text(verbatim: "\(online)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 15, minHeight: 15)
                    .background(Theme.go, in: Capsule())
                    .offset(x: 4, y: -4)
            } else if online == 1 {
                Circle().fill(Theme.go).frame(width: 8, height: 8)
                    .overlay(Circle().stroke(.black, lineWidth: 1.5))
                    .offset(x: 1, y: 1)
            }
        }
        .accessibilityValue(online > 1 ? String(localized: "\(online) Macs online") : "")
    }

    static func reconnectingTitle(_ host: SyncDevice) -> String {
        String(localized: "No connection to the \(host.kindTitle) — reconnecting…")
    }

    @ViewBuilder
    private func linkStatus(_ client: SyncClient) -> some View {
        switch client.status {
        case .connected(let host):
            // The joined computer and the others joined before that are on the network now (the pill counts them).
            let online = 1 + client.compatibleHosts.filter { $0.id != host.id && client.isPaired($0.device) }.count
            Button { showsCard = true } label: {
                HStack(spacing: 6) {
                    // The top bar has no room for a name («MacBoo…»): the card names the host. Through the direct link
                    // (no home network) the icon says so.
                    label(host.kindTitle, systemImage: client.route == .direct ? "antenna.radiowaves.left.and.right" : host.symbolName,
                          tint: Theme.info, online: online)
                    // Another iPhone runs the training: this one only watches.
                    if client.isViewOnly {
                        ViewThatFits(in: .horizontal) {
                            Pill(text: String(localized: "View-only"), systemImage: "eye", tint: .white.opacity(0.7))
                            Pill(text: String(localized: "View-only"), systemImage: "eye", tint: .white.opacity(0.7), iconOnly: true)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsCard, arrowEdge: .top) {
                LinkedMacCard(host: host, reconnecting: false) { showsCard = false }
                    .presentationCompactAdaptation(.popover)
            }
            #if DEBUG
            // `--demo-link-card`: the card open at launch (UI checks without a tap).
            .task {
                guard CommandLine.arguments.contains("--demo-link-card") else { return }
                try? await Task.sleep(for: .seconds(2))
                showsCard = true
            }
            #endif
            .anchorPreference(key: LinkPillAnchorKey.self, value: .bounds) { $0 }
        case .connecting(let host), .waitingApproval(let host):
            label("\(host.kindTitle)…", systemImage: "hourglass", tint: Theme.info)
        case .idle, .failed:
            EmptyView()
        }
    }
    #endif
}

#if os(macOS)
/// The iPhones in this training, from the header's «iPhone × 2» (lab `Design/link-ui-lab`, 4A, with the owner's
/// change): every iPhone the same grey phone; the ones that only watch carry «Только просмотр» and can be made main.
struct MacLinkedPhones: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let host = model.syncHost
        VStack(alignment: .leading, spacing: 10) {
            Text("iPhones in This Training").font(.headline)
            ForEach(host.connectedDevices) { device in
                HStack(spacing: 10) {
                    Image(systemName: device.symbolName)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: device.name)
                        if let model = device.distinctModel { Text(verbatim: model).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 12)
                    if host.isViewOnly(device.id) {
                        Text("View-only")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        Button("Make Main") { host.makeController(device.id) }
                            .controlSize(.small)
                    }
                }
            }
            Text(host.controllerID == nil
                 ? String(localized: "Every iPhone here can mark the exits (one of them is from an older Waiting Paws).")
                 : String(localized: "One iPhone marks the exits; the others see the camera and the timer. A new iPhone joins view-only."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }
}
#endif

#if os(iOS)
/// The joined computer, opened from the «Mac» pill (lab `Design/link-ui-lab`, 2B + 3A): its name and how this iPhone is
/// linked to it, where the camera, the recording and the log are, the traffic over cellular, the other computers joined
/// before (online ones to switch to, when no training runs) and «Отключиться».
struct LinkedMacCard: View {
    @Environment(AppModel.self) private var model
    let host: SyncDevice
    let reconnecting: Bool
    var close: () -> Void

    var body: some View {
        let client = model.syncClient
        let direct = client.route == .direct && !reconnecting
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: host.symbolName)
                    .font(.title2)
                    .foregroundStyle(reconnecting ? Theme.warning : Theme.info)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: host.name)
                        .font(Theme.display(17, weight: .bold))
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(spacing: 6) {
                            Circle().fill(reconnecting ? Theme.warning : Theme.go).frame(width: 8, height: 8)
                            Text(verbatim: status(direct: direct, now: context.date))
                        }
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                    }
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                if let state = client.state, !state.cameraTitle.isEmpty {
                    GridRow {
                        Text("Camera").foregroundStyle(.white.opacity(0.55))
                        Text(verbatim: state.recordingSince == nil ? state.cameraTitle
                             : state.cameraTitle + " · " + String(localized: "recording|in progress"))
                    }
                }
                GridRow {
                    Text("Log and video").foregroundStyle(.white.opacity(0.55))
                    Text("saved on the \(host.kindTitle)")
                }
                if client.isViewOnly {
                    GridRow {
                        Text("This iPhone").foregroundStyle(.white.opacity(0.55))
                        Text("View-only: another iPhone marks the exits")
                    }
                }
                if direct, let status = model.p2p.status(host.id, .out) {
                    GridRow {
                        Text("Over cellular").foregroundStyle(.white.opacity(0.55))
                        Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64((status.bytesIn ?? 0) + (status.bytesOut ?? 0)),
                                                                 countStyle: .file))
                    }
                }
            }
            .font(.system(.footnote, design: .rounded))

            let others = client.pairedHosts.filter { $0.id != host.id }.sorted { $0.lastConnected > $1.lastConnected }
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Other Macs").font(.system(.caption, design: .rounded, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    ForEach(others) { paired in
                        let nearby = client.compatibleHosts.first { $0.id == paired.id }
                        Button {
                            if let nearby { client.connect(to: nearby); close() }
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(nearby == nil ? Color.white.opacity(0.25) : Theme.go).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: paired.name).lineLimit(1)
                                    Text(nearby == nil ? String(localized: "not on this network")
                                         : model.session == nil ? String(localized: "nearby — tap to switch")
                                         : String(localized: "nearby — after the training"))
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(nearby == nil || model.session != nil)
                    }
                }
                .font(.system(.subheadline, design: .rounded))
            }

            Button(role: .destructive) {
                close()
                client.disconnect()
            } label: {
                Text("Stop Syncing")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 300)
        .preferredColorScheme(.dark)
    }

    /// «На связи · по Wi‑Fi», «На связи · по сотовой, 48 мс», «Переподключаемся… 0:12».
    private func status(direct: Bool, now: Date) -> String {
        if reconnecting {
            let since = model.syncClient.reconnectingSince ?? now
            return String(localized: "Reconnecting… \(DurationText.clock(max(0, now.timeIntervalSince(since))))")
        }
        guard direct else { return String(localized: "Connected · Wi‑Fi") }
        if let rtt = model.p2p.status(host.id, .out)?.rtt, rtt > 0 {
            return String(localized: "Connected · cellular, \(P2PText.ms(rtt))")
        }
        return String(localized: "Connected · cellular")
    }
}

/// Detail lines about a host for the choice lists: model, camera or training, whether this iPhone joined it before.
enum HostText {
    static func detail(_ host: SyncClient.DiscoveredHost, paired: Bool) -> String {
        var parts: [String] = []
        if let model = host.device.distinctModel { parts.append(model) }
        if host.info.sessionRunning {
            parts.append(host.info.currentExit.map { String(localized: "training, exit \($0)") }
                         ?? String(localized: "training in progress"))
        } else if !host.info.cameraTitle.isEmpty {
            parts.append(host.info.cameraReady ? String(localized: "camera “\(host.info.cameraTitle)”")
                                               : String(localized: "camera “\(host.info.cameraTitle)” offline"))
        }
        if !host.isCompatible {
            parts.append(String(localized: "another Waiting Paws version"))
        } else if paired {
            parts.append(String(localized: "connected before"))
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
            Button("Sync with “\(host.device.name)”", systemImage: host.device.symbolName) {
                client.connect(to: host)
            }
        } else if hosts.count > 1 {
            Menu("Sync With…", systemImage: "laptopcomputer.and.iphone") {
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
                        Text(isWaiting ? "Confirm on the \(host.kindTitle)" : "Syncing with \(host.kindTitle)")
                            .font(Theme.display(18, weight: .bold))
                        // Names both ends: on the computer the prompt shows this iPhone under the same name.
                        Text(isWaiting ? "“\(host.name)” is showing a request from “\(model.settings.linkName)” — click Allow. This is needed once for this iPhone."
                                       : "«\(host.name)»")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                    IconButton(systemImage: "xmark", label: String(localized: "Cancel|verb")) { client.disconnect() }
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
                        Text(host.info.sessionRunning ? "Training in progress on the \(kind)" : "\(kind) with Waiting Paws Nearby")
                            .font(Theme.display(20, weight: .bold))
                        Text(subtitle(host))
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                    IconButton(systemImage: "xmark", label: String(localized: "Hide")) { dismissed.insert(host.id) }
                }
                failure
                BigButton(title: String(localized: "Sync Training with \(kind)"),
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
            parts.append(host.info.cameraReady ? String(localized: "camera “\(host.info.cameraTitle)”")
                                               : String(localized: "camera “\(host.info.cameraTitle)” offline"))
        }
        if host.info.sessionRunning, let exit = host.info.currentExit { parts.append(String(localized: "exit \(exit)")) }
        #if !WP_NO_XIAOMI // a build without Xiaomi (`NoXiaomiText`) doesn't speak of it
        if !host.info.sessionRunning { parts.append(String(localized: "already signed in to Xiaomi on the \(host.device.kindTitle)")) }
        #endif
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
                    Text("Sync With…")
                        .font(Theme.display(18, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    IconButton(systemImage: "xmark", label: String(localized: "Hide")) { dismissed.formUnion(hosts.map(\.id)) }
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
                    Text("TODAY")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.5))
                    Label("also on \(model.linkedHostKind)", systemImage: "laptopcomputer.and.iphone")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(Theme.info)
                    Spacer()
                    IconButton(systemImage: "xmark") { model.sharePlanWithMac(nil) }
                        .accessibilityLabel("Remove Schedule")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.title)
                        .font(Theme.display(22, weight: .bold))
                        .lineLimit(2)
                    Text(summary)
                        .font(.system(.subheadline, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
                BigButton(title: String(localized: "Start Training"), systemImage: "play.fill") {
                    var final = plan
                    final.renumber()
                    model.startSession(with: final)
                }
                HStack(spacing: 8) {
                    BigButton(title: String(localized: "Edit"), systemImage: "slider.horizontal.3", style: .secondary, height: 44, action: onEdit)
                    BigButton(title: String(localized: "Paste Another"), systemImage: "doc.on.clipboard", style: .secondary, height: 44, action: onPaste)
                }
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if !plan.trainers.isEmpty { parts.append(plan.trainers) }
        parts.append(pluralText(plan.exits.count, en: ("exit", "exits"), ru: ("вых.", "вых.", "вых.")))
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
/// after a recording there. Fades after a few seconds, a tap closes it at once. Without the pill (not linked:
/// «Запись продолжена», a Mac's training gone from the screen) it is a banner under the top bar. While the link is
/// being restored, «Нет связи…» stays under the pill.
struct LinkNoticeOverlay: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(LinkPillAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    if let notice = model.linkNotice ?? reconnectingNotice {
                        if let anchor {
                            let pill = proxy[anchor]
                            // Right edge under the pill's, but always on screen.
                            let width = min(290, proxy.size.width - 24)
                            let left = max(12, min(pill.maxX, proxy.size.width - 12) - width)
                            bubble(notice, arrowX: pill.midX - left, width: width, x: left, y: pill.maxY + 6)
                        } else {
                            let width = min(340, proxy.size.width - 24)
                            bubble(notice, arrowX: nil, width: width, x: (proxy.size.width - width) / 2, y: 50)
                        }
                    }
                }
                .animation(.smooth(duration: 0.3), value: model.linkNotice)
                .animation(.smooth(duration: 0.3), value: model.syncClient.reconnecting)
            }
            .task(id: model.linkNotice?.id) {
                guard model.linkNotice != nil else { return }
                // A newer notice cancels this wait: it must not clear that one.
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                model.linkNotice = nil
            }
    }

    /// While the link is being restored (when no other notice is up): why the training's buttons are off.
    private var reconnectingNotice: LinkNotice? {
        model.syncClient.reconnecting.map { host in
            LinkNotice(title: LinkPill.reconnectingTitle(host),
                       detail: String(localized: "The training continues on “\(host.name)”. The buttons will work again once the connection is back."),
                       systemImage: "wifi.exclamationmark", isWarning: true)
        }
    }

    private func bubble(_ notice: LinkNotice, arrowX: CGFloat?, width: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        LinkNoticeBubble(notice: notice, arrowX: arrowX)
            .frame(width: width)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(x: x, y: y)
            .onTapGesture { model.linkNotice = nil }
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            // The «Нет связи» one has no notice id: it keeps its place while it stays.
            .id(model.linkNotice?.id)
    }
}

private struct LinkNoticeBubble: View {
    let notice: LinkNotice
    /// Where the arrow points, from the bubble's leading edge; nil: a banner without one.
    let arrowX: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let arrowX {
                Triangle()
                    .fill(Theme.panel)
                    .frame(width: 16, height: 8)
                    .offset(x: arrowX - 8)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(notice.isWarning ? Theme.warning : Theme.info)
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
