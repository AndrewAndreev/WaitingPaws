import SwiftUI
import WebKit
import WaitingPawsCore

/// Full-bleed live view of a go2rtc stream using the server's own `video-rtc.js` player
/// (WebRTC with MSE/HLS fallbacks) inside a WKWebView.
struct CameraStreamView {
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

    private var client: Go2RTCClient { Go2RTCClient(server: server) }

    /// What requires reloading the page. Sound is not part of it: it only mutes the player (see `applyMute`).
    private var key: String { "\(server.baseURL)|\(stream)|\(mode.rawValue)|\(fill)|\(reloadToken)" }

    private func html() -> String {
        let socket = client.playerSocketURL(stream: stream).absoluteString
        let muted = audioEnabled ? "false" : "true"
        let fit = fill ? "cover" : "contain"
        return """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
        <style>
          html, body { margin: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
          video-rtc { display: block; width: 100%; height: 100%; }
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
          // How far behind live the MSE player plays (seconds): starts at \(Self.jitterBuffer), grows up to 3.5 when data comes
          // in bursts (a camera on weak Wi-Fi, lost packets resent), shrinks back while the stream is even.
          const jitter = { target: \(Self.jitterBuffer), min: \(Self.jitterBuffer), max: 3.5 };
          // What the player went through; a summary goes to the app log every 30 s when something happened.
          const stats = {
            stalls: 0, stalledMs: 0, stallStart: 0, jumps: 0, errors: 0, bytes: 0, lastData: 0, maxGapMs: 0, lag: 0,
            // A new stream: its init segment comes first and the video only from the next keyframe (up to a whole GOP,
            // ~3 s on the C302, later). That wait is not a hiccup and must not grow the cushion.
            restart() { this.lastData = 0; },
            chunk(size) {
              const now = performance.now();
              if (this.lastData) {
                const gap = now - this.lastData;
                this.maxGapMs = Math.max(this.maxGapMs, gap);
                // A gap longer than the cushion would have frozen the picture: make the cushion cover it.
                if (gap / 1000 > jitter.target * 0.8) jitter.target = Math.min(jitter.max, gap / 1000 + 0.4);
              }
              this.lastData = now;
              this.bytes += size;
            },
          };
          setInterval(() => {
            if (stats.stallStart) { stats.stalledMs += performance.now() - stats.stallStart; stats.stallStart = performance.now(); }
            if (stats.stalls || stats.jumps || stats.errors || stats.maxGapMs > 1500) {
              report('stats 30s: stalls ' + stats.stalls + ', stalled ' + (stats.stalledMs / 1000).toFixed(1) + ' s, jumps ' + stats.jumps
                + ', errors ' + stats.errors + ', max data gap ' + Math.round(stats.maxGapMs) + ' ms, lag ' + stats.lag.toFixed(2)
                + ' s, cushion ' + jitter.target.toFixed(1) + ' s, ' + Math.round(stats.bytes * 8 / 30 / 1000) + ' kbit/s');
            }
            // An even half-minute: give back some of the delay.
            if (stats.maxGapMs < jitter.target * 400) jitter.target = Math.max(jitter.min, jitter.target - 0.5);
            Object.assign(stats, { stalls: 0, stalledMs: 0, jumps: 0, errors: 0, bytes: 0, maxGapMs: 0 });
          }, 30000);

          class Player extends VideoRTC {
            oninit() {
              super.oninit();
              this.video.muted = window.playerMuted;
              this.video.controls = false;
              this.video.style.objectFit = '\(fit)';
              let first = true;
              this.video.addEventListener('playing', () => {
                if (first) { first = false; report('playing ' + this.video.videoWidth + 'x' + this.video.videoHeight); }
              });
              // A stall is the picture not moving while it should (WebKit does not report 'waiting' for live MSE).
              let lastTime = -1, still = 0;
              setInterval(() => {
                const video = this.video;
                if (first || video.paused) { lastTime = -1; return; }
                if (video.currentTime === lastTime) {
                  still++;
                  if (still === 2 && !stats.stallStart) { stats.stalls++; stats.stallStart = performance.now(); }
                } else {
                  still = 0;
                  if (stats.stallStart) { stats.stalledMs += performance.now() - stats.stallStart; stats.stallStart = 0; }
                }
                lastTime = video.currentTime;
              }, 250);
              this.video.addEventListener('resize', () => report('size ' + this.video.videoWidth + 'x' + this.video.videoHeight));
              this.video.addEventListener('error', () => report('video error ' + (this.video.error ? this.video.error.code : '?')));
            }
            onwebrtc() { report('mode webrtc'); return super.onwebrtc(); }

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
                  // Small steps only: a speed change is hardly visible, a jump or a 0.1× crawl is.
                  const next = lag > target + 1.5 ? 1.3 : lag > target + 0.5 ? 1.1 : lag < target * 0.5 ? 0.95 : 1;
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
          player.mode = '\(mode.go2rtcModes)';
          player.background = true;
          player.src = '\(socket)';
          document.body.appendChild(player);
        </script>
        </body></html>
        """
    }

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #if os(iOS)
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        #endif
        configuration.userContentController.add(LogHandler(onVideoSize: onVideoSize), name: "log")
        // Keep feeding the player when its window is covered or not key: a throttled page stops reading the
        // WebSocket and go2rtc then drops frames for it (a freeze until the next keyframe).
        configuration.preferences.inactiveSchedulingPolicy = .none
        let webView = WKWebView(frame: .zero, configuration: configuration)
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
    final class LogHandler: NSObject, WKScriptMessageHandler {
        let onVideoSize: ((CGSize) -> Void)?
        static let clock: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "HH:mm:ss"
            return formatter
        }()

        init(onVideoSize: ((CGSize) -> Void)?) {
            self.onVideoSize = onVideoSize
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            print("[player] \(Self.clock.string(from: Date())) \(message.body)")
            guard let onVideoSize, let text = message.body as? String,
                  text.hasPrefix("playing ") || text.hasPrefix("size "),
                  let dimensions = text.split(separator: " ").last?.split(separator: "x"), dimensions.count == 2,
                  let width = Double(dimensions[0]), let height = Double(dimensions[1]), width > 0, height > 0 else { return }
            onVideoSize(CGSize(width: width, height: height))
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
extension CameraStreamView: UIViewRepresentable {
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
extension CameraStreamView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = makeWebView()
        webView.navigationDelegate = context.coordinator
        load(into: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        load(into: webView, coordinator: context.coordinator)
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
