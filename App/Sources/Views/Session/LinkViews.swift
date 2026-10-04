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
                Text("Связано с «\(name)»")
                Text("Камера, запись и лог — на Mac")
                Button("Отключиться от Mac", systemImage: "xmark.circle", role: .destructive) {
                    model.syncClient.disconnect()
                }
            } label: {
                Pill(text: "Mac", systemImage: "laptopcomputer", tint: Theme.info)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
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
                        Text(isWaiting ? "Подтвердите на Mac" : "Подключаемся к Mac")
                            .font(Theme.display(18, weight: .bold))
                        Text(isWaiting ? "На «\(name)» появился запрос — нажмите «Разрешить». Это нужно один раз."
                                       : "«\(name)»")
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                    IconButton(systemImage: "xmark") { client.disconnect() }
                }
            }
        case .connected(let name):
            if model.session == nil {
                GlassCard(padding: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "laptopcomputer.and.iphone")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.info)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Связано с «\(name)»")
                                .font(.system(.headline, design: .rounded))
                            Text("Тренировка запустится на Mac, там же запись и лог. Нажатия здесь и там — одни и те же.")
                                .font(.system(.footnote, design: .rounded))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
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
                        Text(mac.info.sessionRunning ? "На Mac идёт тренировка" : "Рядом Mac с камерой")
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
                BigButton(title: mac.info.sessionRunning ? "Подключиться к тренировке" : "Использовать камеру Mac",
                          systemImage: "link") {
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
#endif
