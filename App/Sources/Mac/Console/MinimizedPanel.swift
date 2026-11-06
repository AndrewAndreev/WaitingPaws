#if os(macOS)
import AppKit
import SwiftUI
import WaitingPawsCore

/// While the training window sits in the Dock, a glass capsule with the timer and the two actions floats
/// at the bottom of the screen (over other apps); it disappears when the window comes back.
/// Only shown while a training or a recording is running.
struct MinimizedPanelHook: NSViewRepresentable {
    let model: AppModel
    let ui: MacUIState

    func makeNSView(context: Context) -> HookView { HookView(model: model, ui: ui) }

    func updateNSView(_ nsView: HookView, context: Context) {}

    final class HookView: NSView {
        private let model: AppModel
        private let ui: MacUIState
        private var observers: [NSObjectProtocol] = []
        private var panel: NSPanel?

        init(model: AppModel, ui: MacUIState) {
            self.model = model
            self.ui = ui
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let window else {
                hidePanel()
                return
            }
            let center = NotificationCenter.default
            func observe(_ name: Notification.Name, _ action: @escaping @MainActor (HookView) -> Void) {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        if let self { action(self) }
                    }
                })
            }
            observe(NSWindow.didMiniaturizeNotification) { $0.showPanel() }
            observe(NSWindow.didDeminiaturizeNotification) { $0.hidePanel() }
            observe(NSWindow.willCloseNotification) { $0.hidePanel() }
            #if DEBUG
            // `--demo-minimize`: send the window to the Dock shortly after launch (checks the capsule without clicks).
            if CommandLine.arguments.contains("--demo-minimize") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak window] in window?.miniaturize(nil) }
            }
            #endif
        }

        private func showPanel() {
            guard panel == nil, model.session != nil || model.isRecordingNow,
                  let screen = window?.screen ?? NSScreen.main else { return }
            let strip = MinimizedStrip(onRestore: { [weak self] in self?.restore() },
                                       // Next turn: the strip's own update is still running.
                                       onIdle: { [weak self] in DispatchQueue.main.async { self?.hidePanel() } })
                .environment(model)
                .environment(ui)
                .environment(\.colorScheme, .dark)
            let host = FirstClickHostingView(rootView: strip)
            host.sizingOptions = [.intrinsicContentSize]
            let size = host.fittingSize
            let visible = screen.visibleFrame
            let frame = CGRect(x: visible.midX - size.width / 2, y: visible.minY + 24, width: size.width, height: size.height)
            let panel = StripPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = String(localized: "Waiting Paws — панель")
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = host
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            panel.invalidateShadow()
            self.panel = panel
        }

        private func hidePanel() {
            panel?.orderOut(nil)
            panel = nil
        }

        private func restore() {
            guard let window else { return }
            NSApp.activate()
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// Borderless panels can't become key by default; this one may (without activating the app), so its
/// buttons react to the first click while another app is in front.
private final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The capsule: paw, REC, phase + timer, the same two buttons as the window, «Развернуть».
private struct MinimizedStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    var onRestore: () -> Void
    /// Neither a training nor a recording any more (finished from the iPhone, the last break ran out): nothing to
    /// show or stop, the capsule goes.
    var onIdle: () -> Void
    /// «Остановить» asks right in the capsule: «Продолжить» takes its place, «Остановить» moves to its right, so a
    /// double click lands on the safe one.
    @State private var askingStop = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 12) {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.09, green: 0.10, blue: 0.20))
                        .frame(width: 28, height: 28)
                        .background(MacPalette.pink, in: Circle())
                    if model.isRecordingNow {
                        RecBadge(text: DurationText.clock(model.recordingDuration(at: context.date)))
                    }
                    if let session = model.session {
                        let live = LiveSessionModel(session: session, now: context.date,
                                                    recordingSince: model.isRecordingNow ? model.recordingStartedAt : nil)
                        Divider().frame(height: 22)
                        ZStack {
                            ProgressRing(value: live.progress, tint: live.tint, lineWidth: 3)
                            Text("\(session.currentExit?.number ?? 0)")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(live.title) · \(live.phaseName.lowercased())")
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize()
                            Text(live.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: 260, alignment: .leading)
                        Text(live.timerText)
                            .font(MacPalette.digits(26, weight: .semibold))
                            .foregroundStyle(live.tint)
                            .frame(minWidth: 64, alignment: .trailing)
                        Divider().frame(height: 22)
                        if let primary = live.primary {
                            Button { ui.primaryStep(model) } label: {
                                Label { Text(primary.title) } icon: { StepIcon(kind: primary.icon, size: 13) }
                            }
                            .buttonStyle(HUDButtonStyle(tint: primary.tint ?? MacPalette.pink, height: 36))
                        }
                        let content = ReadoutContent(session: session)
                        if content.showsFalseStart(at: context.date) {
                            // Orange, as in the panel; what a click does is in the pointer's tip.
                            Button { ui.falseStart(model) } label: {
                                Label("Фальстарт", systemImage: "arrow.uturn.backward")
                                    .foregroundStyle(MacPalette.orange)
                            }
                            .buttonStyle(HUDButtonStyle(height: 36))
                            .help([String(localized: "Фальстарт"), content.falseStartHint]
                                .compactMap { $0 }.joined(separator: " — "))
                            .accessibilityLabel(content.falseStartAccessibilityLabel)
                            .accessibilityHint(content.falseStartHint ?? "")
                        }
                    } else {
                        Text(askingStop ? "Остановить запись?" : "Запись без тренировки").font(.system(size: 12.5, weight: .semibold))
                        if askingStop {
                            Button { askingStop = false } label: { Label("Продолжить", systemImage: "record.circle") }
                                .buttonStyle(HUDButtonStyle(height: 36))
                            Button {
                                askingStop = false
                                model.stopRecording(deleteFile: false)
                            } label: { Label("Остановить", systemImage: "stop.fill") }
                                .buttonStyle(HUDButtonStyle(tint: MacPalette.red, height: 36))
                        } else {
                            Button { askingStop = true } label: { Label("Остановить", systemImage: "stop.fill") }
                                .buttonStyle(HUDButtonStyle(tint: MacPalette.red, height: 36))
                        }
                    }
                    Button(action: onRestore) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(HUDButtonStyle(height: 36, circle: true))
                        .help("Развернуть окно тренировки")
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .frame(height: 58)
                .glassEffect(.regular, in: .capsule)
            }
            .padding(10)
        }
        .onChange(of: model.session == nil && !model.isRecordingNow) { _, idle in if idle { onIdle() } }
        // The question goes away by itself: the capsule is back to «Остановить» a few seconds later.
        .task(id: askingStop) {
            guard askingStop else { return }
            try? await Task.sleep(for: .seconds(5))
            askingStop = false
        }
    }
}
#endif
