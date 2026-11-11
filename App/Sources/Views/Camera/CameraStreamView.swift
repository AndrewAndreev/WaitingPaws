import SwiftUI
import WebKit
import WaitingPawsCore

/// What the player is doing, for the overlay over the picture (from "state …" messages of the page).
enum PlayerPhase: Equatable {
    /// The page is loading, or the WebSocket and go2rtc are connecting to the camera.
    case connecting
    /// go2rtc has the camera (it sent the codecs); the first keyframe and the cushion are on their way.
    case waitingForPicture
    case playing
    /// The picture has not moved for 2 s while it should.
    case stalled
    /// go2rtc could not get the camera; video-rtc.js tries again by itself.
    case failed(String)
}

/// What the player is doing, and how old the picture on screen is: what the overlay over the picture says. Fed by
/// the page's "state …" messages; the caller may hold one to show it elsewhere (the iPhone shows it over the part of
/// the picture on screen, not zoomed with it).
@Observable
final class CameraStatus {
    private(set) var phase: PlayerPhase = .connecting
    /// When the picture on screen last moved, while it doesn't: the last frame stays on screen (through a reconnect
    /// too, see `keepFrame` in the page). Nil while it plays and before the first frame.
    private(set) var frozenSince: Date?
    /// A frame has been shown since the page loaded.
    private(set) var hasPicture = false

    init() {}

    func update(_ next: PlayerPhase) {
        switch next {
        case .playing:
            hasPicture = true
            frozenSince = nil
        case .stalled:
            // The page says so after 2 s without movement.
            if hasPicture, frozenSince == nil { frozenSince = Date().addingTimeInterval(-2) }
        default:
            if hasPicture, frozenSince == nil { frozenSince = Date() }
        }
        phase = next
    }

    /// A new page: nothing on screen yet.
    func restart() {
        phase = .connecting
        frozenSince = nil
        hasPicture = false
    }

    #if DEBUG
    /// `--demo-stream=…` over the demo picture (UI checks): its frame `age` seconds old.
    func demo(_ phase: PlayerPhase, age: TimeInterval?) {
        self.phase = phase
        hasPicture = age != nil
        frozenSince = age.map { Date().addingTimeInterval(-$0) }
    }
    #endif
}

/// Full-bleed live view of a go2rtc stream, with what is going on over it while there is no picture yet (or it
/// froze) instead of a black screen.
struct CameraStreamView: View {
    var server: Go2RTCServer
    var stream: String
    var mode: PlayerMode
    var audioEnabled: Bool
    var fill: Bool = false
    var reloadToken: Int = 0
    /// Off where the caller shows its own status (the Mac settings card).
    var showsStatus: Bool = true
    /// The caller's: it shows the state itself (`CameraStatusOverlay`), this view doesn't.
    var status: CameraStatus? = nil
    var onVideoSize: ((CGSize) -> Void)? = nil
    var onDelay: ((Double, Double?) -> Void)? = nil
    /// The Mac's training window: how far up the zoomed picture may run past the player's top, under the toolbar
    /// (`MacCameraArea`). 0: cut at the player's edges.
    var bleedTop: CGFloat = 0

    @State private var own = CameraStatus()
    /// Set inside `ZoomableView(contentZooms: true)`: the player zooms the picture itself (the Mac's `PlayerWebView`).
    @Environment(ZoomState.self) private var zoom: ZoomState?

    init(server: Go2RTCServer, stream: String, mode: PlayerMode, audioEnabled: Bool, fill: Bool = false,
         reloadToken: Int = 0, showsStatus: Bool = true, status: CameraStatus? = nil,
         onVideoSize: ((CGSize) -> Void)? = nil, onDelay: ((Double, Double?) -> Void)? = nil, bleedTop: CGFloat = 0) {
        self.server = server
        self.stream = stream
        self.mode = mode
        self.audioEnabled = audioEnabled
        self.fill = fill
        self.reloadToken = reloadToken
        self.showsStatus = showsStatus
        self.status = status
        self.onVideoSize = onVideoSize
        self.onDelay = onDelay
        self.bleedTop = bleedTop
    }

    var body: some View {
        let status = self.status ?? own
        // A new page starts black: no last frame to keep (`onPageStart`). Only then, not when the view appears: the
        // Mac's training window closed and opened again from the Dock keeps its player, whose page plays on and has
        // nothing new to say — reset there, the overlay stayed on «Подключаемся к камере…» over the moving picture.
        CameraWebView(server: server, stream: stream, mode: mode, audioEnabled: audioEnabled, fill: fill,
                      reloadToken: reloadToken, onVideoSize: onVideoSize, onDelay: onDelay,
                      onPhase: { status.update($0) }, onPageStart: { status.restart() },
                      zoomScale: zoom?.contentScale ?? 1, zoomOffset: zoom?.offset ?? .zero, bleedTop: bleedTop)
            .overlay {
                if showsStatus && self.status == nil { CameraStatusOverlay(status: own) }
            }
    }
}

/// Spinner and a line of text while the camera connects; over a picture that stopped, how long ago it did (the frame
/// itself stays, dimmed); the reason when go2rtc cannot reach the camera. Nothing while the picture moves.
struct CameraStatusOverlay: View {
    let status: CameraStatus
    /// Under «Нет кадра 18 с», what the recording does (off: the screen's REC says it already — the iPhone).
    var showsRecording = true
    /// Off where the picture runs past the area (`ZoomableView.overflows`): the caller darkens the frame itself, all of
    /// it, not only the part in the area.
    var dimsFrozenFrame = true
    /// Absent where the overlay stands outside the app's windows (previews): no recording line then.
    @Environment(AppModel.self) private var model: AppModel?
    /// Still connecting after 10 s.
    @State private var slow = false
    /// While the picture stands still and this device records: whether video still reaches the recording (its file
    /// grew in the last few seconds); nil until that is known.
    @State private var recordingWrites: Bool?
    /// How much a frame that stopped is darkened under «Нет кадра 12 с».
    static let frozenDim = 0.38

    var body: some View {
        let phase = status.phase
        Group {
            if phase == .playing {
                EmptyView()
            } else if let since = status.frozenSince {
                FrozenPicturePill(since: since, detail: frozenDetail(phase), recording: showsRecording ? recordingLine : nil)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // The last frame a little darker: it reads as old, not as a calm dog, and the dog stays clear on it.
                    .background(Color.black.opacity(dimsFrozenFrame ? Self.frozenDim : 0))
                    .transition(.opacity)
            } else {
                switch phase {
                case .playing, .stalled:
                    EmptyView()
                case .connecting, .waitingForPicture:
                    message(title: phase == .connecting ? String(localized: "Connecting to the camera…")
                                                        : String(localized: "Camera connected, waiting for the first frame…"),
                            detail: slow ? String(localized: "Taking longer than usual: the camera may be offline or busy with another app.") : nil,
                            icon: nil)
                case .failed(let reason):
                    message(title: String(localized: "The camera doesn’t respond"),
                            detail: String(localized: "\(reason). Trying again…"),
                            icon: "video.slash")
                }
            }
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.25), value: phase)
        .animation(.easeInOut(duration: 0.25), value: status.frozenSince == nil)
        .task(id: phase) {
            slow = false
            guard phase == .connecting else { return }
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { slow = true }
        }
        .task(id: status.frozenSince) { await watchRecording() }
    }

    // MARK: Recording

    /// What a recording does while the picture here stands still (GPT, round 8: «Нет кадра 18 с» under a red REC left
    /// open whether the video is still being saved). Only what is known: the recording of this device still gets
    /// video (the picture is stuck on the way to the screen, not at the camera), or it waits for the camera (nothing
    /// came for a while, or the camera's stream broke off: it goes on in a new part once the camera is back); a linked
    /// Mac only says that it records. Nothing without a recording.
    private enum RecordingNow {
        case writing, waiting, onHost(String)
    }

    private var recordingNow: RecordingNow? {
        guard let model, model.isRecordingNow else { return nil }
        #if DEBUG
        // `--demo-recording`: nothing is written; `--demo-rec=waiting|host` for the other lines (writing by default).
        if AppModel.demoRecordingSince != nil {
            let demo = CommandLine.arguments.first { $0.hasPrefix("--demo-rec=") }.map { String($0.dropFirst("--demo-rec=".count)) }
            switch demo ?? "" {
            case "waiting": return .waiting
            case "host": return .onHost(model.linkedHostKind)
            default: return .writing
            }
        }
        #endif
        if model.isLinkedToMac { return .onHost(model.linkedHostKind) }
        if model.recordingResuming { return .waiting }
        return recordingWrites.map { $0 ? .writing : .waiting }
    }

    private var recordingLine: FrozenPicturePill.RecordingLine? {
        switch recordingNow {
        case nil: return nil
        case .writing: return .init(text: String(localized: "Recording video"), isOn: true)
        case .waiting: return .init(text: String(localized: "Recording waits for the camera"), isOn: false)
        case .onHost(let host): return .init(text: String(localized: "\(host) keeps recording"), isOn: true)
        }
    }

    /// While the picture stands still: every second, whether the recording's file grew (a new part counts from its
    /// first bytes). Video comes in fragments a few seconds apart, so «waiting» only after 6 s without any.
    private func watchRecording() async {
        recordingWrites = nil
        guard status.frozenSince != nil, let model else { return }
        let window: TimeInterval = 6
        var recorder = ObjectIdentifier(model.recorder)
        var bytes = model.recorder.bytesWritten
        var grewAt: Date?
        let began = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let current = model.recorder
            let now = current.bytesWritten
            let same = ObjectIdentifier(current) == recorder
            if now > (same ? bytes : 0) { grewAt = Date() }
            recorder = ObjectIdentifier(current)
            bytes = now
            if let grewAt, Date().timeIntervalSince(grewAt) < window {
                recordingWrites = true
            } else if Date().timeIntervalSince(began) >= window {
                recordingWrites = false
            }
        }
    }

    /// Why the frame stands still, when the player knows more than that.
    private func frozenDetail(_ phase: PlayerPhase) -> String? {
        switch phase {
        case .connecting, .waitingForPicture: return String(localized: "Reconnecting…")
        case .failed(let reason):
            // A line of its own: «Нет ответа. Пробуем снова…».
            return String(localized: "\(reason.prefix(1).uppercased() + reason.dropFirst()). Trying again…")
        case .playing, .stalled: return nil
        }
    }

    private func message(title: String, detail: String?, icon: String?) -> some View {
        VStack(spacing: 10) {
            if let icon {
                Image(systemName: icon).font(.system(size: 30, weight: .light)).opacity(0.7)
            } else {
                ProgressView().tint(.white)
            }
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(.footnote, design: .rounded))
                    .opacity(0.6)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35))
        .transition(.opacity)
    }
}

/// «Нет кадра 12 с», «Нет кадра 1 мин» over the last frame: a calm dog and a stopped stream look the same, the age
/// tells them apart — said in words, not as a clock that could pass for a countdown (design council, round 6).
private struct FrozenPicturePill: View {
    /// «● Видео записывается» / «○ Запись ждёт камеру» under the age: the red dot of REC while video goes into the
    /// recording, an empty ring while it waits.
    struct RecordingLine: Equatable {
        var text: String
        var isOn: Bool
    }

    let since: Date
    var detail: String?
    var recording: RecordingLine?

    /// «18 с» for the first minute, then whole minutes: «1 мин», «1 ч 5 мин».
    static func age(_ seconds: TimeInterval) -> String {
        let whole = max(0, seconds.rounded(.down))
        return DurationText.short(whole < 60 ? whole : (whole / 60).rounded(.down) * 60)
    }

    private var isOneLine: Bool { detail == nil && recording == nil }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                VStack(alignment: .leading, spacing: 1) {
                    Text("No picture for \(Self.age(context.date.timeIntervalSince(since)))")
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                    if let detail {
                        Text(detail)
                            .font(.system(.caption, design: .rounded))
                            .opacity(0.7)
                    }
                    if let recording {
                        HStack(spacing: 4) {
                            Image(systemName: recording.isOn ? "circle.fill" : "circle")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(recording.isOn ? Theme.danger : .white.opacity(0.7))
                            Text(recording.text)
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .opacity(recording.isOn ? 0.9 : 0.7)
                        }
                        .transition(.opacity)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .padding(.leading, 12)
            .padding(.trailing, 14)
            .padding(.vertical, isOneLine ? 8 : 7)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: isOneLine ? 17 : 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: isOneLine ? 17 : 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .animation(.easeInOut(duration: 0.25), value: recording)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The go2rtc player itself: the server's own `video-rtc.js` (WebRTC with MSE/HLS fallbacks) in a WKWebView.
struct CameraWebView {
    var server: Go2RTCServer
    var stream: String
    var mode: PlayerMode
    var audioEnabled: Bool
    /// `true` crops to fill, `false` letterboxes the whole frame.
    var fill: Bool = false
    /// Bump to force a reconnect.
    var reloadToken: Int = 0
    /// Seconds the MSE player starts behind the live edge to ride out late chunks; it grows (up to 3.5 s) while data
    /// comes in bursts and shrinks back when the stream is even (see `jitter` and `onmse` in the page).
    static let jitterBuffer = 0.8

    private static var trace: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--player-trace")
        #else
        return false
        #endif
    }
    /// Called with the decoded video size whenever playback starts or the resolution changes.
    var onVideoSize: ((CGSize) -> Void)? = nil
    /// Called every second (MSE) with how far the picture trails the newest data and how late that data came, s
    /// (see `delay` and `network` in the page; the second is nil until known).
    var onDelay: ((Double, Double?) -> Void)? = nil
    /// Called when the player's phase changes ("state …" messages).
    var onPhase: ((PlayerPhase) -> Void)? = nil
    /// Called when a new page replaces the old one (WebKit committed the load): the first load, and every reload.
    var onPageStart: (() -> Void)? = nil
    /// The picture's zoom (`ZoomState`) on the Mac, applied by the web view's layer (`PlayerWebView`): scaled around
    /// the centre, then shifted by the offset. (The iPhone's picture zooms in SwiftUI.)
    var zoomScale: CGFloat = 1
    var zoomOffset: CGSize = .zero
    /// The Mac: how far up the zoomed picture may run past the view (`PlayerWebView.bleedTop`).
    var bleedTop: CGFloat = 0

    private var client: Go2RTCClient { Go2RTCClient(server: server) }

    /// `text` as a JavaScript string literal for the page: JSON-encoded, so a quote in a stream name or password (or a
    /// `</script>`) cannot break out of it.
    private static func jsString(_ text: String) -> String {
        (try? JSONEncoder().encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "''"
    }

    /// What requires reloading the page. Sound is not part of it: it only mutes the player (see `applyMute`).
    /// What the loaded page was made for; the credentials count too (a linked Mac sends new ones after «Забыть» or when it
    /// goes back to its built-in go2rtc), as a hash.
    private var key: String { "\(server.baseURL)|\(server.hashValue)|\(stream)|\(mode.rawValue)|\(fill)|\(reloadToken)" }

    private func html() -> String {
        let socket = Self.jsString(client.playerSocketURL(stream: stream).absoluteString)
        let muted = audioEnabled ? "false" : "true"
        #if os(macOS)
        // A box at the page's top-left that never follows the window: `PlayerWebView` fits and zooms it. In the picture's
        // own shape (`PlayerWebView.box(for:)`; 16:9 until the video says), set again when the video's size changes.
        let fit = "contain"
        let start = PlayerWebView.box(for: CGSize(width: 16, height: 9))
        let box = "position: absolute; left: 0; top: 0; width: \(Int(start.width))px; height: \(Int(start.height))px;"
        let shapesBox = "true", boxMost = Int(PlayerWebView.pictureBox)
        #else
        let fit = fill ? "cover" : "contain"
        // The whole frame letterboxed on black: no blurred copy of it in the margins (design council, round 14:
        // decoration with nothing to tell).
        let box = "display: block; position: relative; width: 100%; height: 100%;"
        let shapesBox = "false", boxMost = 0
        #endif
        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
          html, body { margin: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
          video-rtc { \(box) }
          video-rtc video { width: 100%; height: 100%; object-fit: \(fit); background: #000; }
          #still { position: absolute; left: 0; top: 0; width: 100%; height: 100%; object-fit: \(fit); pointer-events: none; }
        </style>
        </head><body>
        <script type="module">
          import { VideoRTC } from './video-rtc.js';
          // The app may already have toggled the sound while the page was loading.
          if (window.playerMuted === undefined) window.playerMuted = \(muted);
          // DEBUG `--player-trace`: the player's clock, speed and buffer every second in the app log.
          window.playerTrace = \(Self.trace);
          const report = (text) => { try { window.webkit.messageHandlers.log.postMessage(text); } catch (e) {} };
          // The phase for the app's overlay (`PlayerPhase`): connecting → waiting → playing ⇄ stalled, or error.
          let phase = '';
          const setPhase = (next) => { if (next !== phase) { phase = next; report('state ' + next); } };
          // A reconnect starts a new stream, and a new stream starts black: the last frame stays over it as a still until
          // the video plays again, so the app can say how old it is («Нет кадра 12 с») over the picture itself.
          let played = false;
          const keepFrame = (video) => {
            if (!video.videoWidth || document.getElementById('still')) return;
            try {
              const canvas = document.createElement('canvas');
              canvas.width = video.videoWidth;
              canvas.height = video.videoHeight;
              canvas.getContext('2d').drawImage(video, 0, 0);
              const still = document.createElement('img');
              still.id = 'still';
              still.src = canvas.toDataURL('image/jpeg', 0.85);
              video.parentElement.appendChild(still);
            } catch (e) { report('still ' + e); }
          };
          const dropFrame = () => { const still = document.getElementById('still'); if (still) still.remove(); };
          // Quick retries after a first try that failed (`Player.onclose`): the waits in turn, then upstream's rhythm.
          const quickWaits = [1000, 2000, 3000, 4000, 5000];
          let quickTries = 0;
          // How far behind live the MSE player plays (seconds): starts at \(Self.jitterBuffer), grows at once to cover a gap in
          // the data (a camera on weak Wi-Fi, lost packets resent) up to 3.5, and every 10 s eases towards the longest gap
          // of the last 30 s + 0.4. Behind a door the gaps stay around 0.8 s: the cushion then settles near 1.2 s, where
          // the old rule (shrink only after a half-minute with no gap over 0.4 of the cushion) kept it at 1.8 for good.
          const jitter = { target: \(Self.jitterBuffer), min: \(Self.jitterBuffer), max: 3.5, windowGapMs: 0, recent: [] };
          // What the player went through; a summary goes to the app log every 30 s when something happened.
          const stats = {
            stalls: 0, stalledMs: 0, stallStart: 0, jumps: 0, errors: 0, bytes: 0, lastData: 0, maxGapMs: 0, lag: 0,
            // A new stream: its init segment comes first and the video only from the next keyframe (up to a whole GOP,
            // ~3 s on the C302, later). That wait is not a hiccup and must not grow the cushion.
            restart() { this.lastData = 0; network.restart(); },
            chunk(size) {
              const now = performance.now();
              if (this.lastData) {
                const gap = now - this.lastData;
                this.maxGapMs = Math.max(this.maxGapMs, gap);
                jitter.windowGapMs = Math.max(jitter.windowGapMs, gap);
                // A gap longer than the cushion would have frozen the picture: make the cushion cover it.
                if (gap / 1000 > jitter.target * 0.8) jitter.target = Math.min(jitter.max, gap / 1000 + 0.4);
              }
              this.lastData = now;
              this.bytes += size;
            },
          };
          // How much later than the fastest of the last minute the newest video arrives (s). The video's timeline is the
          // camera's own frame times (go2rtc carries them over), so arrival minus media time only grows when something on
          // the way holds frames up: camera → go2rtc, and on an iPhone watching through a Mac also Mac → Wi-Fi → iPhone.
          // Not included: the camera's encoding and the base transit (~0.2–0.3 s), which no timestamp tells.
          const network = {
            buckets: [], lateness: -1,
            restart() { this.buckets = []; this.lateness = -1; },
            note(offset) {
              const now = performance.now();
              let last = this.buckets[this.buckets.length - 1];
              if (!last || now - last.start >= 10000) {
                last = { start: now, min: offset };
                this.buckets = this.buckets.filter(b => now - b.start < 50000).concat(last);
              }
              last.min = Math.min(last.min, offset);
              const late = offset - Math.min(...this.buckets.map(b => b.min));
              this.lateness = this.lateness < 0 ? late : this.lateness + (late - this.lateness) * 0.2;
            },
          };
          setInterval(() => {
            jitter.recent = jitter.recent.concat(jitter.windowGapMs).slice(-3);
            jitter.windowGapMs = 0;
            const goal = Math.max(jitter.min, Math.max(...jitter.recent) / 1000 + 0.4);
            if (jitter.target > goal) jitter.target = Math.max(goal, jitter.target - 0.3);
          }, 10000);
          setInterval(() => {
            if (stats.stallStart) { stats.stalledMs += performance.now() - stats.stallStart; stats.stallStart = performance.now(); }
            if (stats.stalls || stats.jumps || stats.errors || stats.maxGapMs > 1500 || stats.lag > 1.5) {
              report('stats 30s: stalls ' + stats.stalls + ', stalled ' + (stats.stalledMs / 1000).toFixed(1) + ' s, jumps ' + stats.jumps
                + ', errors ' + stats.errors + ', max data gap ' + Math.round(stats.maxGapMs) + ' ms, lag ' + stats.lag.toFixed(2)
                + ' s, cushion ' + jitter.target.toFixed(1) + ' s, ' + Math.round(stats.bytes * 8 / 30 / 1000) + ' kbit/s');
            }
            Object.assign(stats, { stalls: 0, stalledMs: 0, jumps: 0, errors: 0, bytes: 0, maxGapMs: 0 });
          }, 30000);

          class Player extends VideoRTC {
            oninit() {
              super.oninit();
              setPhase('connecting');
              this.video.muted = window.playerMuted;
              this.video.controls = false;
              this.video.style.objectFit = '\(fit)';
              let first = true;
              this.video.addEventListener('playing', () => {
                if (first) { first = false; report('playing ' + this.video.videoWidth + 'x' + this.video.videoHeight); }
                played = true;
                quickTries = 0;
                dropFrame();
                setPhase('playing');
              });
              // A stall is the picture not moving while it should (WebKit does not report 'waiting' for live MSE).
              // `delay`: how old the frame on screen is against the newest data — the time since that data came plus
              // what is still buffered ahead. It holds while buffered video plays and grows during a freeze. The camera →
              // here part comes from go2rtc (the camera's capture times); the app adds the two on the diagnostics panel.
              let lastTime = -1, still = 0, delay = -1, ticks = 0;
              setInterval(() => {
                const video = this.video;
                if (first || video.paused) { lastTime = -1; return; }
                const buffered = video.buffered;
                if (stats.lastData && buffered.length) {
                  const now = (performance.now() - stats.lastData) / 1000
                    + Math.max(0, buffered.end(buffered.length - 1) - video.currentTime);
                  delay = delay < 0 ? now : delay + (now - delay) * 0.3;
                }
                if (++ticks % 4 === 0 && delay >= 0) report('delay ' + delay.toFixed(2) + ' ' + network.lateness.toFixed(2));
                if (video.currentTime === lastTime) {
                  still++;
                  if (still === 2 && !stats.stallStart) { stats.stalls++; stats.stallStart = performance.now(); }
                  if (still === 8 && phase === 'playing') setPhase('stalled'); // 2 s: worth saying on screen
                } else {
                  if (phase === 'stalled') setPhase('playing');
                  still = 0;
                  if (stats.stallStart) { stats.stalledMs += performance.now() - stats.stallStart; stats.stallStart = 0; }
                }
                lastTime = video.currentTime;
              }, 250);
              // Back from the background: WebKit may have paused the picture; the data catches up on its own (the jump to
              // live in 'updateend' below) as long as the connection lived through it.
              document.addEventListener('visibilitychange', () => {
                if (!document.hidden && !first && this.video.paused) this.video.play().catch(() => {});
              });
              this.video.addEventListener('resize', () => {
                const width = this.video.videoWidth, height = this.video.videoHeight;
                // The Mac: the box in the picture's shape, in whole pixels, as `PlayerWebView.box(for:)` works it out.
                // A square one with `contain` left WebKit to round a 90.57-px-high picture (848×480) to 159×90.
                if (\(shapesBox) && width > 0 && height > 0) {
                  const gcd = (a, b) => b ? gcd(b, a % b) : a;
                  const w = Math.round(width), h = Math.round(height), g = gcd(w, h), long = Math.max(w, h) / g;
                  const most = \(boxMost);
                  let boxW, boxH;
                  if (long <= most) {
                    const times = Math.floor(most / long);
                    boxW = w / g * times; boxH = h / g * times;
                  } else if (w >= h) {
                    boxW = most; boxH = Math.max(1, Math.round(most * h / w));
                  } else {
                    boxW = Math.max(1, Math.round(most * w / h)); boxH = most;
                  }
                  this.style.width = boxW + 'px';
                  this.style.height = boxH + 'px';
                }
                report('size ' + width + 'x' + height);
              });
              this.video.addEventListener('error', () => report('video error ' + (this.video.error ? this.video.error.code : '?')));
            }
            onwebrtc() { report('mode webrtc'); return super.onwebrtc(); }
            // A (re)connection; and go2rtc's {"type":"error"} when it cannot get the camera (video-rtc.js retries).
            onconnect() {
              if (played) keepFrame(this.video);
              setPhase('connecting');
              return super.onconnect();
            }
            onopen() {
              const modes = super.onopen();
              this.onmessage['status'] = msg => { if (msg.type === 'error') setPhase('error ' + msg.value); };
              // Upstream answers an error of the first mode by asking for MJPEG on the same socket and never tries
              // again. A camera that does not answer the first try (it still holds the session of an app just quit:
              // "read udp … i/o timeout") then left the player on MJPEG for good, and the built-in go2rtc cannot make
              // JPEG out of H.265 ("codecs not matched … => video:JPEG"): «Камера не отвечает» until a relaunch.
              // MJPEG only where the stream is there and MSE cannot play it; otherwise a new connection, as upstream
              // does for a broken MSE stream (`onclose` reconnects within RECONNECT_TIMEOUT).
              if (this.onmessage['mjpeg'] && modes.length) {
                this.onmessage['mjpeg'] = msg => {
                  if (msg.type !== 'error' || msg.value.indexOf(modes[0]) !== 0) return;
                  if (msg.value.includes('codecs not matched')) {
                    this.onmjpeg();
                  } else {
                    report('reconnect after: ' + msg.value);
                    this.retrySoon = true;
                    if (this.ws) this.ws.close();
                  }
                };
              }
              return modes;
            }
            // Upstream reconnects RECONNECT_TIMEOUT (15 s) after the last try began. A camera that turns the session down
            // (it still holds another one: an app killed without quitting, another device) does so within a second and
            // holds the old session up to ~15 s more, so one refusal cost the whole 15 s on top. A first try that failed is
            // tried again after 1, 2, 3, 4 and 5 s instead (each try asks Mi Cloud for keys and the camera once), then at
            // upstream's pace; the picture playing starts the count over.
            onclose() {
              if (this.retrySoon) {
                this.retrySoon = false;
                if (quickTries < quickWaits.length) {
                  const wait = quickWaits[quickTries++];
                  // Upstream waits until RECONNECT_TIMEOUT after `connectTS`: date the last try back so the wait is `wait`.
                  this.connectTS = Math.min(this.connectTS, Date.now() - (this.RECONNECT_TIMEOUT - wait));
                  report('retry in ' + wait / 1000 + ' s');
                }
              }
              return super.onclose();
            }

            // MSE with a small jitter buffer. Upstream video-rtc.js keeps the buffer nearly empty (playbackRate = buffered
            // seconds, down to 0.1×): every late chunk (a big keyframe every few seconds, a Wi-Fi hiccup) turned into a freeze
            // and a fast-forward. Here playback trails the live edge by `target` seconds: it starts (and restarts after a
            // stall) only with that much buffered, and the rate merely nudges the lag back towards it.
            onmse() {
              report('mode mse');
              let ms;
              const open = (MediaSource) => {
                ms.addEventListener('sourceopen', () => {
                  if (this.video.src.startsWith('blob:')) URL.revokeObjectURL(this.video.src);
                  // A live stream: without an infinite duration, running out of data counts as the end and WebKit
                  // pauses the video for good (upstream recovered only through the next seek).
                  try { ms.duration = Infinity; } catch (e) {}
                  this.send({type: 'mse', value: this.codecs(MediaSource.isTypeSupported)});
                }, {once: true});
              };
              if ('ManagedMediaSource' in window) {
                ms = new window.ManagedMediaSource();
                open(window.ManagedMediaSource);
                this.video.disableRemotePlayback = true;
                this.video.srcObject = ms;
              } else {
                ms = new MediaSource();
                open(MediaSource);
                this.video.src = URL.createObjectURL(ms);
                this.video.srcObject = null;
              }
              this.mseCodecs = '';
              // Playback starts once `target` seconds are buffered. After that it is never paused on purpose: out of
              // data, WebKit holds the last frame and goes on by itself (pausing there fought with the seeks below).
              let buffering = true;

              this.onmessage['mse'] = msg => {
                if (msg.type !== 'mse') return;
                setPhase('waiting');
                this.mseCodecs = msg.value;
                const sb = ms.addSourceBuffer(msg.value);
                sb.mode = 'segments';
                const queue = [];
                const append = (data) => {
                  try { sb.appendBuffer(data); } catch (e) { stats.errors++; }
                };
                const flush = () => {
                  if (sb.updating || !queue.length) return;
                  const data = new Uint8Array(queue.reduce((n, b) => n + b.byteLength, 0));
                  let offset = 0;
                  for (const b of queue) { data.set(new Uint8Array(b), offset); offset += b.byteLength; }
                  queue.length = 0;
                  append(data);
                };
                let rate = 1;
                sb.addEventListener('updateend', () => {
                  flush();
                  if (sb.updating || !sb.buffered || !sb.buffered.length) return;
                  const video = this.video;
                  const end = sb.buffered.end(sb.buffered.length - 1);
                  const start = sb.buffered.start(0);
                  if (end - 10 > start) {
                    sb.remove(start, end - 10);
                    try { ms.setLiveSeekableRange(end - 10, end); } catch (e) {}
                  }
                  const target = jitter.target;
                  const lag = end - video.currentTime;
                  stats.lag = lag;
                  network.note(performance.now() / 1000 - end);
                  if (video.currentTime < start || lag > target + 3) {
                    // Far behind (a long stall, the app was in the background): back to `target` behind live.
                    video.currentTime = Math.max(start, end - target);
                    if (video.currentTime > 0) stats.jumps++;
                  }
                  if (buffering || video.paused || video.ended) {
                    // Start, or carry on after WebKit stopped at the end of the data, once the cushion is back.
                    if (lag >= target) { buffering = false; this.play(); }
                    return;
                  }
                  // Small steps only: a speed change is hardly visible, a jump or a 0.1× crawl is. Behind by more than the
                  // cushion (after a stall, or the cushion just shrank) is caught up within seconds, not half a minute.
                  // Slower than real time only to restore the base cushion: a grown one is filled by the late data itself
                  // (it arrives in a burst), and when the data never comes, slowing down would only add delay — after one
                  // 2.6 s gap that crept up from 0.8 to 2.5 s within a minute.
                  const next = lag > target + 1 ? 1.3 : lag > target + 0.2 ? 1.15 : lag < jitter.min * 0.5 ? 0.95 : 1;
                  if (next !== rate) { rate = next; video.playbackRate = rate; }
                });
                if (window.playerTrace) setInterval(() => {
                  const v = this.video, b = sb.buffered;
                  let ranges = '';
                  for (let i = 0; i < b.length; i++) ranges += ' [' + b.start(i).toFixed(2) + '-' + b.end(i).toFixed(2) + ']';
                  report('trace t=' + v.currentTime.toFixed(2) + ' rate=' + v.playbackRate + ' paused=' + v.paused
                    + ' state=' + v.readyState + ' cushion=' + jitter.target.toFixed(1) + ' buffered' + ranges);
                }, 1000);
                stats.restart();
                let init = true;
                this.ondata = data => {
                  if (init) { init = false; stats.bytes += data.byteLength; } else stats.chunk(data.byteLength);
                  if (sb.updating || queue.length) queue.push(data); else append(data);
                };
              };
            }
            onhls() { report('mode hls'); return super.onhls(); }
            onmjpeg() { report('mode mjpeg'); return super.onmjpeg(); }
            ondisconnect() { report('disconnect'); return super.ondisconnect(); }
          }
          customElements.define('video-rtc', Player);
          const player = document.createElement('video-rtc');
          window.player = player;
          player.mode = \(Self.jsString(mode.go2rtcModes));
          player.background = true;
          player.src = \(socket);
          document.body.appendChild(player);
        </script>
        </body></html>
        """
    }

    #if os(iOS)
    typealias WebView = WKWebView
    #else
    typealias WebView = PlayerWebView
    #endif

    func makeWebView() -> WebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        #endif
        let log = LogHandler(onVideoSize: onVideoSize, onDelay: onDelay, onPhase: onPhase)
        configuration.userContentController.add(log, name: "log")
        // Keep feeding the player when its window is covered or not key: a throttled page stops reading the
        // WebSocket and go2rtc then drops frames for it (a freeze until the next keyframe).
        configuration.preferences.inactiveSchedulingPolicy = .none
        let webView = WebView(frame: .zero, configuration: configuration)
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        // Public API only: black behind the page, and the view stays hidden until the page (black itself) has
        // loaded, so the white default background never flashes over the dark window.
        webView.underPageBackgroundColor = .black
        webView.isHidden = true
        webView.fill = fill
        log.player = webView
        #endif
        return webView
    }

    func load(into webView: WKWebView, coordinator: Coordinator) {
        coordinator.onPageStart = onPageStart
        guard coordinator.loadedKey != key else {
            applyMute(to: webView, coordinator: coordinator)
            return
        }
        coordinator.loadedKey = key
        coordinator.server = server
        coordinator.audioEnabled = audioEnabled
        // Every load is a new connection to the camera: one more than expected is a reconnect.
        print("[player] \(LogHandler.clock.string(from: Date())) load \(stream)")
        webView.loadHTMLString(html(), baseURL: server.baseURL)
    }

    /// Mutes or unmutes the running player without reconnecting to the camera.
    private func applyMute(to webView: WKWebView, coordinator: Coordinator) {
        guard coordinator.audioEnabled != audioEnabled else { return }
        coordinator.audioEnabled = audioEnabled
        let muted = audioEnabled ? "false" : "true"
        webView.evaluateJavaScript("window.playerMuted = \(muted); if (window.player && window.player.video) { window.player.video.muted = \(muted); }")
    }

    /// Forwards player events from JavaScript into the app log; "playing 1920x1080" / "size …" also report the resolution.
    /// "delay 1.25 0.40" (buffer, network) goes to `onDelay` only (every second, not for the log); "state …" to `onPhase`.
    final class LogHandler: NSObject, WKScriptMessageHandler {
        let onVideoSize: ((CGSize) -> Void)?
        let onDelay: ((Double, Double?) -> Void)?
        let onPhase: ((PlayerPhase) -> Void)?
        #if os(macOS)
        /// Fits the picture to the video's size.
        weak var player: PlayerWebView?
        #endif
        static let clock: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm:ss"
            return formatter
        }()

        init(onVideoSize: ((CGSize) -> Void)?, onDelay: ((Double, Double?) -> Void)?, onPhase: ((PlayerPhase) -> Void)?) {
            self.onVideoSize = onVideoSize
            self.onDelay = onDelay
            self.onPhase = onPhase
        }

        /// "state error mse: streams: dial …: i/o timeout" → the last, human part of go2rtc's error chain.
        static func phase(_ state: Substring) -> PlayerPhase? {
            switch state {
            case "connecting": return .connecting
            case "waiting": return .waitingForPicture
            case "playing": return .playing
            case "stalled": return .stalled
            default:
                guard state.hasPrefix("error") else { return nil }
                let error = state.dropFirst(5).lowercased()
                // The camera turned the session down: it still serves another one (go2rtc's "the camera closed the
                // session"; a camera that ignores the newcomer instead leaves "can't send command").
                if error.contains("closed the session") || error.contains("can't send command") {
                    return .failed(String(localized: "busy with another connection"))
                }
                // Before the timeout: a camera search that timed out says why its sends failed
                // ("i/o timeout (5 sent, all failed: … no route to host)").
                if error.contains("unreachable") || error.contains("no route") {
                    return .failed(String(localized: "the camera can’t be reached on the network"))
                }
                if error.contains("timeout") { return .failed(String(localized: "no response")) }
                if error.contains("refused") { return .failed(String(localized: "connection refused")) }
                let reason = state.dropFirst(5).split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
                return .failed(reason.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "no response"))
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let text = message.body as? String, text.hasPrefix("delay ") {
                let numbers = text.dropFirst(6).split(separator: " ").compactMap { Double($0) }
                if let buffer = numbers.first { onDelay?(buffer, numbers.count > 1 && numbers[1] >= 0 ? numbers[1] : nil) }
                return
            }
            if let text = message.body as? String, text.hasPrefix("state "), let phase = Self.phase(text.dropFirst(6)) {
                onPhase?(phase)
                // Only the trouble goes to the log; connecting/playing is already there as "mode …"/"playing …".
                guard case .failed = phase else { if phase == .stalled { print("[player] \(Self.clock.string(from: Date())) stalled 2 s") }; return }
            }
            print("[player] \(Self.clock.string(from: Date())) \(message.body)")
            guard let text = message.body as? String,
                  text.hasPrefix("playing ") || text.hasPrefix("size "),
                  let dimensions = text.split(separator: " ").last?.split(separator: "x"), dimensions.count == 2,
                  let width = Double(dimensions[0]), let height = Double(dimensions[1]), width > 0, height > 0 else { return }
            let size = CGSize(width: width, height: height)
            #if os(macOS)
            player?.videoSize = size
            #endif
            onVideoSize?(size)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedKey: String?
        var server: Go2RTCServer?
        var audioEnabled = false
        var onPageStart: (() -> Void)?

        /// The new page is in (black, before its script runs): whatever the player says from here on is about it.
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            onPageStart?()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.isHidden = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            webView.isHidden = false
        }

        func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let server, server.hasCredentials, challenge.previousFailureCount == 0,
               challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic {
                completionHandler(.useCredential, URLCredential(user: server.username, password: server.password, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }
    }
}

#if os(iOS)
extension CameraWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = makeWebView()
        webView.navigationDelegate = context.coordinator
        load(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        load(into: webView, coordinator: context.coordinator)
    }
}
#else
/// The Mac's player view: the page lays the picture out in one fixed box (`pictureBox`, at its top-left) and this view
/// fits it to its own size — and zooms it — with a layer transform.
///
/// WebKit redraws a resized page a few frames late. Sized by the page, the picture trailed the «Пульт» panel's edge while
/// it was dragged or folded away, and the strip the camera gained showed WKWebView's own grey (the system control
/// background), as if the panel were left behind. A layer transform lands together with the window's own layout. The
/// video layer is scaled from the decoded frames, not from a bitmap of the box: the picture stays as sharp. The view's
/// frame is left as SwiftUI lays it out (a SwiftUI scale on it brought WebKit's toolbar inset, see `ZoomableView`).
final class PlayerWebView: WKWebView {
    /// CSS px, the box's longer side at most; every place the player is shown (the training window, the settings card)
    /// is larger.
    static let pictureBox: CGFloat = 160

    /// The page's box for a picture of `size`: the picture's own shape in whole CSS pixels, its longer side as close to
    /// `pictureBox` as that allows (848×480 → 159×90, 16:9 → 160×90, 4:3 → 160×120), so the video fills it exactly.
    /// A 160-px square with `contain` put an 848×480 picture (the C302's SD stream) at 160×90.57 px, which WebKit drew
    /// as 159×90 half a pixel in: ×8 in the window, a black strip at the left and the picture 1 % short (the owner,
    /// 2026-11-07). The page works it out the same way when the video's size changes (`CameraWebView.html`). A shape
    /// with no small whole-number form: the longer side 160, the other rounded.
    static func box(for size: CGSize) -> CGSize {
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return CGSize(width: pictureBox, height: pictureBox) }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(width, height), most = Int(pictureBox), long = max(width, height) / g
        if long <= most {
            let times = most / long
            return CGSize(width: width / g * times, height: height / g * times)
        }
        return width >= height
            ? CGSize(width: most, height: max(1, Int((Double(most * height) / Double(width)).rounded())))
            : CGSize(width: max(1, Int((Double(most * width) / Double(height)).rounded())), height: most)
    }

    /// The video's own size: the picture's aspect in the box and in the view (16:9 until the player knows).
    var videoSize = CGSize(width: 16, height: 9) {
        didSet { if videoSize != oldValue { fitPicture(animated: false) } }
    }
    /// Crop to fill the view rather than letterbox the whole frame.
    var fill = false {
        didSet { if fill != oldValue { fitPicture(animated: false) } }
    }
    /// How far up the zoomed picture may run past the view's top: the training window's camera reaches up under the
    /// toolbar (`MacCameraArea`). 0: the picture is cut at the view's edges. The sides and the bottom are cut at the
    /// view's own: the panel and the timeline are there.
    var bleedTop: CGFloat = 0 {
        didSet { if bleedTop != oldValue { updateCut() } }
    }
    private var zoomScale: CGFloat = 1
    private var zoomOffset: CGSize = .zero
    /// The cut with `bleedTop`: the view's bounds and the strip above them.
    private let cut = CALayer()

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        // The zoomed picture stays inside.
        clipsToBounds = true
        cut.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Black where the page hasn't painted yet (`underPageBackgroundColor` is the page's colour and doesn't reach
    /// there; `drawsBackground` is SPI).
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            fitPicture(animated: false)
            updateCut()
        }
    }

    /// Cut at the bounds, or at the bounds and `bleedTop` above them (a mask: the layer itself no longer clips).
    private func updateCut() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if bleedTop > 0 {
            // The backing layer is flipped (see `fitPicture`): the strip above is at negative y.
            cut.frame = CGRect(x: 0, y: -bleedTop, width: bounds.width, height: bounds.height + bleedTop)
            if layer.mask !== cut { layer.mask = cut }
            clipsToBounds = false
        } else {
            if layer.mask === cut { layer.mask = nil }
            clipsToBounds = true
        }
        CATransaction.commit()
    }

    /// `ZoomState`: scaled around the centre, then shifted by the offset; gliding there when `animated`.
    func zoom(scale: CGFloat, offset: CGSize, animated: Bool) {
        guard scale != zoomScale || offset != zoomOffset else { return }
        zoomScale = scale
        zoomOffset = offset
        fitPicture(animated: animated)
    }

    /// The page's picture in its box, onto its place in the view, then zoomed. The backing layer is flipped with its
    /// anchor at the top-left, so the transform works in the view's own points.
    private func fitPicture(animated: Bool) {
        guard let layer, bounds.width > 0, bounds.height > 0, videoSize.width > 0, videoSize.height > 0 else { return }
        let inPage = Self.place(videoSize, in: Self.box(for: videoSize), fill: false)
        let inView = Self.place(videoSize, in: bounds.size, fill: fill)
        let k = inView.width / inPage.width
        let centre = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        var transform = CATransform3DMakeTranslation(
            zoomScale * (inView.minX - k * inPage.minX - centre.x) + centre.x + zoomOffset.width,
            zoomScale * (inView.minY - k * inPage.minY - centre.y) + centre.y + zoomOffset.height, 0)
        transform = CATransform3DScale(transform, k * zoomScale, k * zoomScale, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            // The glide the CSS zoom had.
            let glide = CABasicAnimation(keyPath: "sublayerTransform")
            glide.fromValue = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
            glide.toValue = transform
            glide.duration = 0.35
            glide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            layer.add(glide, forKey: "zoom")
        } else {
            layer.removeAnimation(forKey: "zoom")
        }
        layer.sublayerTransform = transform
        CATransaction.commit()
    }

    /// `size` scaled to fit (or fill) `area`, centred in it.
    private static func place(_ size: CGSize, in area: CGSize, fill: Bool) -> CGRect {
        let scale = fill ? max(area.width / size.width, area.height / size.height)
                         : min(area.width / size.width, area.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: (area.width - width) / 2, y: (area.height - height) / 2, width: width, height: height)
    }
}

extension CameraWebView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PlayerWebView {
        let webView = makeWebView()
        webView.navigationDelegate = context.coordinator
        load(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: PlayerWebView, context: Context) {
        load(into: webView, coordinator: context.coordinator)
        webView.fill = fill
        webView.bleedTop = bleedTop
        webView.zoom(scale: zoomScale, offset: zoomOffset, animated: context.transaction.animation != nil)
    }
}
#endif

/// Placeholder shown when no camera is configured.
struct CameraPlaceholder: View {
    var text: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.10), Color(white: 0.03)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 12) {
                Image(systemName: "video.slash")
                    .font(.system(size: 36, weight: .light))
                Text(text)
                    .font(.system(.subheadline, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.4))
        }
    }
}
