#if os(macOS)
import SwiftUI
import WaitingPawsCore

/// «Свой сервер go2rtc…»: address, login and password of a go2rtc on the network, checked before switching to it.
struct SetupServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Check: Equatable {
        case idle, checking, ok(String), failed(String)
    }

    @State private var urlText = ""
    @State private var username = ""
    @State private var password = ""
    @State private var check: Check = .idle

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SetupIconTile(symbol: "server.rack", color: Color(red: 0.36, green: 0.42, blue: 0.52), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Own go2rtc Server").font(.headline)
                    Text("go2rtc on a computer or NAS on your network instead of the built-in one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Form {
                Section {
                    TextField("Address", text: $urlText, prompt: Text("http://192.168.1.10:1984"))
                        .plainInput()
                    TextField("Username", text: $username, prompt: Text("Optional"))
                        .plainInput()
                    SecureField("Password", text: $password, prompt: Text("Optional"))
                    HStack(spacing: 8) {
                        result
                        Spacer(minLength: 8)
                        Button("Check Connection") { Task { await runCheck() } }
                            .disabled(check == .checking || Go2RTCServer.parse(urlText) == nil)
                    }
                } footer: {
                    #if WP_NO_XIAOMI
                    Text(NoXiaomiText.serverPassword)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    #else
                    Text("Requires version 1.9.11 or later with the xiaomi module. The server password is stored in the keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    #endif
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .onChange(of: urlText) { check = .idle }
            .onChange(of: username) { check = .idle }
            .onChange(of: password) { check = .idle }

            HStack(spacing: 10) {
                if model.settings.connectionMode == .external, EmbeddedGo2RTC.isAvailable {
                    Button("Switch Back to Built-in") {
                        model.settings.connectionMode = .embedded
                        model.startEmbeddedIfNeeded()
                        dismiss()
                    }
                    .help("go2rtc inside the app, without a separate server")
                }
                Spacer()
                Button("Cancel|verb") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { Task { await connect() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(check == .checking || Go2RTCServer.parse(urlText) == nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            urlText = model.settings.serverURLString
            username = model.settings.serverUsername
            password = model.settings.serverPassword
            #if DEBUG
            if SetupDemo.isOn, urlText.isEmpty {
                urlText = "http://\(SetupDemo.serverHost)"
                check = .ok(SetupDemo.go2rtcVersion)
            }
            #endif
        }
    }

    @ViewBuilder
    private var result: some View {
        switch check {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
            Text("Checking…").foregroundStyle(.secondary)
        case .ok(let version):
            Label(version.isEmpty ? "Server is responding" : "go2rtc \(version) is responding", systemImage: "checkmark.circle.fill")
                .foregroundStyle(MacPalette.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(MacPalette.red)
                .lineLimit(2)
                .help(message)
        }
    }

    private var server: Go2RTCServer? {
        Go2RTCServer.parse(urlText).map { Go2RTCServer(baseURL: $0, username: username, password: password) }
    }

    private func runCheck() async {
        guard let server else { return }
        check = .checking
        do {
            check = .ok(try await Go2RTCClient(server: server).version())
        } catch {
            check = .failed(error.localizedDescription)
        }
    }

    /// Checks (unless just checked), saves and switches the app to this server.
    private func connect() async {
        if case .ok = check {} else { await runCheck() }
        guard case .ok = check else { return }
        guard !AppModel.isUIPreview else { return dismiss() }
        model.settings.serverURLString = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        model.settings.serverUsername = username
        model.settings.serverPassword = password
        model.settings.connectionMode = .external
        model.connectionModeChanged()
        print("[setup] own go2rtc server \(urlText)")
        dismiss()
    }
}
#endif
