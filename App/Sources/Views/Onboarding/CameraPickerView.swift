import SwiftUI
import WaitingPawsCore

/// Pick a camera. Mi Home cameras are listed by name; the selected one is ticked,
/// cameras already registered in go2rtc show an empty circle, new ones a plus.
struct CameraPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var accountID: String?
    var region: XiaomiRegion
    var onDone: (String) -> Void

    @State private var cameras: [Go2RTCSource] = []
    @State private var streams: [Go2RTCStream] = []
    @State private var loading = true
    @State private var camerasError: String?
    @State private var adding: String?

    var body: some View {
        Group {
            if loading {
                ProgressView("Ищем камеры…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if cameras.isEmpty && otherStreams.isEmpty {
                ContentUnavailableView {
                    Label(camerasError == nil ? "Камер не найдено" : "Не удалось получить камеры", systemImage: "video.slash")
                } description: {
                    Text(camerasError ?? "В аккаунте Mi Home нет камер, а в go2rtc нет потоков.")
                } actions: {
                    Button("Обновить") { Task { await loadAll() } }
                }
            } else {
                list
            }
        }
        .navigationTitle("Камера")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if model.settings.isConfigured {
                    Button("Закрыть") { dismiss() }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await loadAll() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(loading)
            }
        }
        .task { await loadAll() }
    }

    private var list: some View {
        List {
            if !cameras.isEmpty {
                Section("Mi Home") {
                    ForEach(cameras) { camera in
                        let existing = stream(for: camera)
                        row(title: camera.name,
                            icon: "video.fill",
                            state: existing.map { $0.name == model.settings.streamName ? .selected : .available } ?? .new,
                            busy: adding == camera.id) {
                            if let existing {
                                select(name: existing.name, title: camera.name)
                            } else {
                                Task { await add(camera) }
                            }
                        }
                    }
                }
            }
            if let camerasError, !cameras.isEmpty {
                Section { Label(camerasError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.warning) }
            }
            if !otherStreams.isEmpty {
                Section(cameras.isEmpty ? "Потоки go2rtc" : "Другие потоки") {
                    ForEach(otherStreams) { stream in
                        row(title: stream.name,
                            icon: "antenna.radiowaves.left.and.right",
                            state: stream.name == model.settings.streamName ? .selected : .available,
                            busy: false) {
                            select(name: stream.name, title: stream.name)
                        }
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
    }

    private enum RowState { case selected, available, new }

    private func row(title: String, icon: String, state: RowState, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(state == .selected ? Theme.accent : .secondary)
                    .frame(width: 22)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    switch state {
                    case .selected: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    case .available: Image(systemName: "circle").foregroundStyle(.secondary)
                    case .new: Image(systemName: "plus.circle").foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(adding != nil)
    }

    // MARK: - Data

    /// go2rtc stream whose source is this Mi Home camera (same device id).
    private func stream(for camera: Go2RTCSource) -> Go2RTCStream? {
        guard let did = Self.deviceID(in: camera.url) else {
            return streams.first { $0.sources.contains(camera.url) }
        }
        return streams.first { $0.sources.contains { Self.deviceID(in: $0) == did } }
    }

    private var otherStreams: [Go2RTCStream] {
        let cameraIDs = Set(cameras.compactMap { Self.deviceID(in: $0.url) })
        return streams.filter { stream in
            !stream.sources.contains { source in
                if let did = Self.deviceID(in: source) { return cameraIDs.contains(did) }
                return false
            }
        }
    }

    private static func deviceID(in source: String) -> String? {
        guard source.hasPrefix("xiaomi://"),
              let components = URLComponents(string: source) else { return nil }
        return components.queryItems?.first { $0.name == "did" }?.value
    }

    private func loadAll() async {
        loading = true
        camerasError = nil
        await model.waitForServer()
        guard let client = model.client else { loading = false; return }
        async let loadedStreams = (try? client.streams()) ?? []
        async let loadedCameras: [Go2RTCSource] = {
            guard let accountID else { return [] }
            do {
                return try await client.xiaomiCameras(accountID: accountID, region: region)
            } catch {
                await MainActor.run { camerasError = error.localizedDescription }
                return []
            }
        }()
        let (s, c) = await (loadedStreams, loadedCameras)
        streams = s
        cameras = c
        loading = false
    }

    private func add(_ camera: Go2RTCSource) async {
        guard let client = model.client else { return }
        adding = camera.id
        defer { adding = nil }
        let name = Go2RTCClient.streamName(for: camera.name)
        do {
            try await client.addStream(name: name, source: camera.url)
            streams.append(Go2RTCStream(name: name, sources: [camera.url]))
            select(name: name, title: camera.name)
        } catch {
            model.errorMessage = "Не удалось добавить поток: \(error.localizedDescription)"
        }
    }

    private func select(name: String, title: String) {
        model.settings.streamName = name
        model.settings.cameraTitle = title
        onDone(name)
    }
}
