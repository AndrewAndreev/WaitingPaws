import SwiftUI
import WaitingPawsCore

/// What the direct link's status says in words, the same on the iPhone and the Mac (an experiment, `P2PLinks`).
@MainActor
enum P2PText {
    enum Tone { case idle, progress, good, bad, warning }

    static func title(_ kind: P2PLinkKind) -> String {
        switch kind {
        case .lan: return String(localized: "At home (Wi‑Fi)")
        case .out: return String(localized: "Outside (cellular)")
        }
    }

    /// One line: what the link does now.
    static func state(_ status: P2PLinkStatus?, unavailable: String?, needsServer: Bool,
                      now: Date = Date()) -> (text: String, tone: Tone) {
        if let unavailable, status == nil { return (unavailable, .warning) }
        guard let status else { return (String(localized: "Not checked"), .idle) }
        switch status.outcome(now: now) {
        case .checking:
            return (String(localized: "Checking…"), .progress)
        case .direct(let stale):
            if stale, let silence = status.silence(now: now) {
                return needsServer ? (String(localized: "Needs a server to come back"), .bad)
                                   : (String(localized: "No answer for \(Int(silence)) s"), .warning)
            }
            return (String(localized: "Works directly"), .good)
        case .failed:
            return (String(localized: "Didn’t work"), .bad)
        case .lost:
            return needsServer ? (String(localized: "Needs a server to come back"), .bad) : (String(localized: "Lost"), .warning)
        }
    }

    /// "srflx ↔ prflx · 48 ms", or why it failed.
    static func detail(_ status: P2PLinkStatus?) -> String? {
        guard let status else { return nil }
        var parts: [String] = []
        if let pair = status.pairText, status.isAlive || status.everConnected { parts.append(pair) }
        if status.isAlive, let rtt = status.rtt, rtt > 0 {
            var text = ms(rtt)
            if let min = status.rttMin, min > 0, min < rtt * 0.8 { text += " (" + String(localized: "min \(ms(min))") + ")" }
            parts.append(text)
        }
        if status.restarts ?? 0 > 0 {
            parts.append(status.signalPath == "channel" ? String(localized: "rechecked over the link itself")
                                                        : String(localized: "rechecked"))
        }
        if status.carriesStreams {
            let megabytes = ((status.bytesIn ?? 0) + (status.bytesOut ?? 0)) / 1_000_000
            parts.append(String(localized: "the picture and sync go over it, \(megabytes.formatted(.number.precision(.fractionLength(1)))) MB"))
        }
        if case .failed = status.outcome(), let types = status.remoteTypes ?? status.localTypes {
            let srflx = (status.localTypes?["srflx"] ?? 0) + (types["srflx"] ?? 0)
            parts.append(srflx == 0 ? String(localized: "no public address from STUN")
                                    : String(localized: "the NATs let no packet through"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func ms(_ value: Double) -> String {
        String(localized: "\(Int(value.rounded())) ms")
    }

    /// How a NAT maps ports, and what that means for a direct link. `peer`: the other end's NAT — one that keeps its
    /// port lets a direct link through a NAT that changes it.
    static func nat(_ nat: P2PNATResult?, peer: P2PNATResult? = nil) -> String? {
        guard let nat else { return nil }
        switch nat.kind {
        case .independent: return String(localized: "keeps the port — good for a direct link")
        case .dependent where peer.map(keepsPort) == true:
            return String(localized: "changes the port for each address — fine while the other end keeps its port")
        case .dependent: return String(localized: "changes the port for each address — a direct link is unlikely")
        case .none: return String(localized: "no NAT, a public address")
        case .unknown: return String(localized: "couldn’t tell (one server answered)")
        case .blocked: return String(localized: "STUN servers didn’t answer")
        }
    }

    private static func keepsPort(_ nat: P2PNATResult) -> Bool { nat.kind == .independent || nat.kind == .none }

    static func natTone(_ nat: P2PNATResult?, peer: P2PNATResult? = nil) -> Tone {
        guard let kind = nat?.kind else { return .idle }
        switch kind {
        case .independent, .none: return .good
        case .dependent where peer.map(keepsPort) == true: return .warning
        case .dependent, .blocked: return .bad
        case .unknown: return .idle
        }
    }

    /// The home router: could it give the Mac a stable address for an iPhone away from home (no server)?
    static func router(_ router: P2PRouterResult?, checking: Bool, publicIP: String?) -> String {
        if checking { return String(localized: "Checking…") }
        guard let router else { return String(localized: "Not checked") }
        switch router.verdict(publicIP: publicIP) {
        case .unavailable:
            return String(localized: "can’t open a port (no NAT-PMP or UPnP answer)")
        case .mappable:
            return String(localized: "can open a port (\(router.method ?? "")) and has the public address")
        case .behindAnotherNAT:
            return String(localized: "can open a port (\(router.method ?? "")), but the provider has its own NAT on top")
        }
    }

    /// "After 95 s in the background: at home — lost, outside — kept".
    static func resume(_ resume: P2PLinks.Resume?) -> String? {
        guard let resume, let survived = resume.survived, !survived.isEmpty else { return nil }
        let parts = P2PLinkKind.allCases.compactMap { kind -> String? in
            guard let kept = survived[kind] else { return nil }
            let place = kind == .lan ? String(localized: "at home") : String(localized: "outside|away from home")
            return "\(place) — " + (kept ? String(localized: "kept") : String(localized: "lost"))
        }
        return String(localized: "After \(Int(resume.away.rounded())) s in the background: \(parts.joined(separator: ", "))")
    }

    /// Short, for a device row and the pill's tooltip: "home 4 ms · outside 48 ms".
    static func summary(_ links: P2PLinks, peer: String) -> String? {
        let parts = P2PLinkKind.allCases.compactMap { kind -> String? in
            guard let status = links.status(peer, kind) else { return nil }
            let place = kind == .lan ? String(localized: "home") : String(localized: "outside|away from home")
            switch status.outcome() {
            case .direct(stale: false): return "\(place) \(status.rtt.map(ms) ?? "")"
            case .direct(stale: true), .lost: return "\(place) —"
            case .failed: return "\(place) ✕"
            case .checking: return "\(place) …"
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#if os(iOS)
/// Settings → «Прямая связь (тест)» on the iPhone: the two links to the Mac, the NATs on both ends, what the background
/// did, and «Проверить ещё раз».
struct P2PSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let links = model.p2p
        if let peer = links.lastPeer {
            Section {
                ForEach(P2PLinkKind.allCases, id: \.self) { kind in
                    P2PLinkRow(kind: kind, status: links.status(peer, kind), unavailable: links.unavailableReason(peer, kind),
                               needsServer: links.needsServer(peer, kind))
                }
                let homeNAT = links.status(peer, .lan)?.peerNat ?? links.status(peer, .out)?.peerNat
                P2PNATRow(title: String(localized: "Home NAT"), nat: homeNAT)
                P2PNATRow(title: String(localized: "Carrier NAT"), nat: links.status(peer, .out)?.nat, peer: homeNAT)
                if let resume = P2PText.resume(links.lastResume) {
                    Text(resume).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Check Again") { links.recheck(peer, syncLinked: syncLinked(peer)) }
                    .disabled(P2PLinkKind.allCases.contains { links.status(peer, $0)?.outcome() == .checking })
            } header: {
                Text("Direct Link (Test)")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Waiting Paws checks whether this iPhone can reach the Mac directly, without any server: at home over Wi‑Fi, and over cellular — the way it goes away from home. At home everything goes as before; when the home network is gone, syncing and the picture switch to the cellular link by themselves.")
                    if links.status(peer, .out)?.isAlive == true {
                        Text("To try it, turn off Wi‑Fi: the picture should come back over cellular in a few seconds. It lasts while the app is open.")
                    }
                    if P2PLinkKind.allCases.contains(where: { links.needsServer(peer, $0) }) {
                        Text("Away from the home network, the link can’t be set up again: that needs a server (planned). Connect at home and check again.")
                    }
                }
            }
        }
    }

    private func syncLinked(_ peer: String) -> Bool {
        if case .connected(let host) = model.syncClient.status { return host.id == peer }
        return false
    }
}
#endif

/// One link: its place, its state (coloured) and the pair with the round trip; «Нет ответа N с» counts every second.
struct P2PLinkRow: View {
    let kind: P2PLinkKind
    let status: P2PLinkStatus?
    var unavailable: String?
    var needsServer = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = P2PText.state(status, unavailable: unavailable, needsServer: needsServer, now: context.date)
            LabeledContent {
                HStack(spacing: 6) {
                    if state.tone == .progress { ProgressView().controlSize(.small) }
                    Text(state.text).foregroundStyle(Self.color(state.tone))
                }
            } label: {
                Text(P2PText.title(kind))
                if let detail = P2PText.detail(status) { Text(detail) }
            }
        }
    }

    static func color(_ tone: P2PText.Tone) -> Color {
        #if os(macOS)
        // Settings follow the system's light or dark look: the system colours read on both.
        switch tone {
        case .idle, .progress: return .secondary
        case .good: return .green
        case .bad: return .red
        case .warning: return .orange
        }
        #else
        switch tone {
        case .idle, .progress: return .secondary
        case .good: return Theme.go
        case .bad: return Theme.danger
        case .warning: return Theme.warning
        }
        #endif
    }
}

/// How one side's NAT maps ports, coloured by what it means for a direct link.
struct P2PNATRow: View {
    let title: String
    let nat: P2PNATResult?
    /// The other end's NAT (see `P2PText.nat`).
    var peer: P2PNATResult?

    var body: some View {
        if let text = P2PText.nat(nat, peer: peer) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(P2PLinkRow.color(P2PText.natTone(nat, peer: peer)))
            }
        }
    }
}
