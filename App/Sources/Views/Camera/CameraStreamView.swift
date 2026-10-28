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
    var onVideoSize: ((CGSize) -> Void)? = nil
    var onDelay: ((Double, Double?) -> Void)? = nil

    @State private var phase: PlayerPhase = .connecting
    /// Set inside `ZoomableView(contentZooms: true)`: the player zooms the picture itself (the Mac's `PlayerWebView`).
    @Environment(ZoomState.self) private var zoom: ZoomState?

    init(server: Go2RTCServer, stream: String, mode: PlayerMode, audioEnabled: Bool, fill: Bool = false,
         reloadToken: Int = 0, showsStatus: Bool = true, onVideoSize: ((CGSize) -> Void)? = nil,
         onDelay: ((Double, Double?) -> Void)? = nil) {
        self.server = server
        self.stream = stream
        self.mode = mode
        self.audioEnabled = audioEnabled
        self.fill = fill
        self.reloadToken = reloadToken
        self.showsStatus = showsStatus
        self.onVideoSize = onVideoSize
        self.onDelay = onDelay
    }

    var body: some View {
        CameraWebView(server: server, stream: stream, mode: mode, audioEnabled: audioEnabled, fill: fill,
                      reloadToken: reloadToken, onVideoSize: onVideoSize, onDelay: onDelay,
                      onPhase: { phase = $0 }, zoomScale: zoom?.scale ?? 1, zoomOffset: zoom?.offset ?? .zero)
            .overlay {
                if showsStatus { CameraStatusOverlay(phase: phase) }
            }
            .onChange(of: "\(server.baseURL)|\(stream)|\(mode.rawValue)|\(reloadToken)") { phase = .connecting }
    }
}

/// Spinner and a line of text while the camera connects, a pill over a frozen picture, the reason when go2rtc
/// cannot reach the camera.
struct CameraStatusOverlay: View {
    let phase: PlayerPhase
    /// Still connecting after 10 s.
    @State private var slow = false

    var body: some View {
        Group {
            switch phase {
            case .playing:
                EmptyView()
            case .stalled:
                Label {
                    Text("Нет новых кадров — ждём камеру")
                } icon: {
                    ProgressView().controlSize(.small).tint(.white)
                }
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.6), in: Capsule())
            case .connecting, .waitingForPicture:
                message(title: phase == .connecting ? String(localized: "Подключаемся к камере…")
                                                    : String(localized: "Камера на связи, ждём первый кадр…"),
                        detail: slow ? String(localized: "Дольше обычного: камера может быть не в сети или занята другим приложением.") : nil,
                        icon: nil)
            case .failed(let reason):
                message(title: String(localized: "Камера не отвечает"),
                        detail: String(localized: "\(reason). Пробуем снова…"),
                        icon: "video.slash")
            }
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.25), value: phase)
        .task(id: phase) {
            slow = false
            guard phase == .connecting else { return }
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { slow = true }
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
    /// The picture's zoom (`ZoomState`) on the Mac, applied by the web view's layer (`PlayerWebView`): scaled around
    /// the centre, then shifted by the offset. (The iPhone's picture zooms in SwiftUI.)
    var zoomScale: CGFloat = 1
    var zoomOffset: CGSize = .zero

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
        // A box of one size at the page's top-left, whatever the window does: `PlayerWebView` fits and zooms it.
        let fit = "contain"
        let box = "position: absolute; left: 0; top: 0; width: \(Int(PlayerWebView.pictureBox))px; height: \(Int(PlayerWebView.pictureBox))px;"
        #else
        let fit = fill ? "cover" : "contain"
        let box = "display: block; width: 100%; height: 100%;"
        #endif
        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
          html, body { margin: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
          video-rtc { \(box) }
          video-rtc video { width: 100%; height: 100%; object-fit: \(fit); background: #000; }
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
              this.video.addEventListener('resize', () => report('size ' + this.video.videoWidth + 'x' + this.video.videoHeight));
              this.video.addEventListener('error', () => report('video error ' + (this.video.error ? this.video.error.code : '?')));
            }
            onwebrtc() { report('mode webrtc'); return super.onwebrtc(); }
            // A (re)connection; and go2rtc's {"type":"error"} when it cannot get the camera (video-rtc.js retries).
            onconnect() { setPhase('connecting'); return super.onconnect(); }
            onopen() {
              const modes = super.onopen();
              this.onmessage['status'] = msg => { if (msg.type === 'error') setPhase('error ' + msg.value); };
              return modes;
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
                if error.contains("timeout") { return .failed(String(localized: "нет ответа")) }
                if error.contains("refused") { return .failed(String(localized: "соединение отклонено")) }
                if error.contains("unreachable") || error.contains("no route") {
                    return .failed(String(localized: "камера недоступна по сети"))
                }
                let reason = state.dropFirst(5).split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
                return .failed(reason.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "нет ответа"))
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
    /// CSS px; every place the player is shown (the training window, the settings card) is larger.
    static let pictureBox: CGFloat = 160

    /// The video's own size: the picture's aspect in the box and in the view (16:9 until the player knows).
    var videoSize = CGSize(width: 16, height: 9) {
        didSet { if videoSize != oldValue { fitPicture(animated: false) } }
    }
    /// Crop to fill the view rather than letterbox the whole frame.
    var fill = false {
        didSet { if fill != oldValue { fitPicture(animated: false) } }
    }
    private var zoomScale: CGFloat = 1
    private var zoomOffset: CGSize = .zero

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        // The zoomed picture stays inside.
        clipsToBounds = true
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
        if changed { fitPicture(animated: false) }
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
        let box = CGSize(width: Self.pictureBox, height: Self.pictureBox)
        let inPage = Self.place(videoSize, in: box, fill: false)
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
