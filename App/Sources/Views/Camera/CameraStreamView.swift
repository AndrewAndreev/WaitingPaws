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
          const report = (text) => { try { window.webkit.messageHandlers.log.postMessage(text); } catch (e) {} };
          class Player extends VideoRTC {
            oninit() {
              super.oninit();
              this.video.muted = window.playerMuted;
              this.video.controls = false;
              this.video.style.objectFit = '\(fit)';
              this.video.addEventListener('playing', () => report('playing ' + this.video.videoWidth + 'x' + this.video.videoHeight));
              this.video.addEventListener('resize', () => report('size ' + this.video.videoWidth + 'x' + this.video.videoHeight));
              this.video.addEventListener('error', () => report('video error ' + (this.video.error ? this.video.error.code : '?')));
            }
            onwebrtc() { report('mode webrtc'); return super.onwebrtc(); }
            onmse() { report('mode mse'); return super.onmse(); }
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
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #else
        webView.setValue(false, forKey: "drawsBackground")
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

        init(onVideoSize: ((CGSize) -> Void)?) {
            self.onVideoSize = onVideoSize
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            print("[player] \(message.body)")
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
