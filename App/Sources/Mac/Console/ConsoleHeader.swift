#if os(macOS)
import SwiftUI
import WaitingPawsCore

// The «Пульт» header, the owner's pick (2026-11-06) from the council's variants in Design/session-header-lab:
// the session's capsule — the window's buttons, a hairline, the avatar, title and subtitle, like a Telegram chat's
// header —, the camera's island (the switcher and the camera's menu in one capsule) and the panel's groups, all 36-pt
// capsules of one dark glass on the toolbar's line (y 8…44). There is no band under them any more: over the camera they
// float, their own glass and a drop shadow; over the panel they lie flat, as the toolbar's groups always did.

/// Sizes and colours of the header's pieces. Widths are set, not left to the toolbar: `ConsolePanelLayout` adds them up
/// to know which words fit over the panel and where the camera's island ends.
enum HeaderLook {
    static let height: CGFloat = 36
    /// A little white over `ClipRecordingHUD.glass`: over the black above the picture and over the panel the pieces read
    /// like the toolbar's groups did; over a bright zoomed picture they stay dark (Liquid Glass alone turns light there).
    static let lift = 0.06
    static let wordFont = Font.system(size: 13, weight: .semibold)
    private static let wordNSFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// A segment with its icon alone; one alone in its capsule is round.
    static let iconSegment: CGFloat = 40
    static let iconBox: CGFloat = 18
    static let wordLead: CGFloat = 12, wordGap: CGFloat = 6, wordTrail: CGFloat = 14

    /// The width of `text`, rounded up with a point to spare (SwiftUI sets text a hair wider than AppKit measures).
    static func width(_ text: String, font: NSFont = wordNSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
    }

    /// A segment: its icon, with `word` after it while that fits.
    static func segment(word: String?) -> CGFloat {
        guard let word else { return iconSegment }
        return wordLead + iconBox + wordGap + width(word) + wordTrail
    }

    /// «● REC»: the time recorded is in the tip and for VoiceOver, so the group doesn't grow every minute.
    static let recFont = NSFont.systemFont(ofSize: 10, weight: .bold)
    static var recSegment: CGFloat { 14 + 7 + 5 + width("REC", font: recFont) + 14 }
}

// MARK: - Glass and shadow

/// One glass for every piece of the header: the «Только камера» plate's (`ClipRecordingHUD.glass`) with the
/// `HeaderLook.lift`, the plate's shade in an inactive window, and the plate's shadow while it floats over the picture
/// (`floating` 0…1, animated as the panel's edge passes under it).
struct HeaderGlass: ViewModifier {
    var floating: Double
    /// How the shadow comes and goes (only the shadow: the words change at once, with the toolbar's layout).
    var sweep: Animation?
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(.white.opacity(HeaderLook.lift)))
            .background(Capsule().fill(.black.opacity(appearsActive ? 0 : ClipRecordingHUD.inactiveShade)))
            .glassEffect(ClipRecordingHUD.glass, in: .capsule)
            .modifier(FloatingShadow(amount: floating, animation: sweep))
            .environment(\.colorScheme, .dark)
    }
}

/// The shadow of a piece floating over the picture — the header's and the «Только камера» plate: a contact shadow and
/// a soft one under it. Drawn outside the capsule only: under clear glass it would darken the picture seen through it.
struct FloatingShadow: ViewModifier {
    var amount: Double
    var animation: Animation?

    func body(content: Content) -> some View {
        content.background {
            ZStack {
                Capsule().fill(.black).shadow(color: .black.opacity(0.32 * amount), radius: 1, y: 0.5)
                Capsule().fill(.black).shadow(color: .black.opacity(0.42 * amount), radius: 9, y: 4)
            }
            .mask {
                Rectangle()
                    .padding(-48)
                    .overlay { Capsule().blendMode(.destinationOut) }
                    .compositingGroup()
            }
            .animation(animation, value: amount)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The thin line between the window's buttons and the session, and between the segments of a capsule.
struct HeaderHairline: View {
    var height: CGFloat = 18
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Capsule()
            .fill(.white.opacity(appearsActive ? 0.17 : 0.09))
            .frame(width: 1, height: height)
            .accessibilityHidden(true)
    }
}

/// A segment of a header capsule: a highlight while the pointer is over it, a stronger one pressed or on.
struct HeaderSegmentStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(configuration: configuration, isOn: isOn)
    }

    private struct SegmentBody: View {
        let configuration: Configuration
        let isOn: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background(Rectangle().fill(.white.opacity(configuration.isPressed ? 0.16
                                                             : isOn ? 0.12 : hovering && isEnabled ? 0.06 : 0)))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// The words and icons of the header: white, dimmed in an inactive window (as the toolbar's own).
private struct HeaderInk: ViewModifier {
    var tint: Color?
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content.foregroundStyle(tint ?? .white.opacity(appearsActive ? 1 : 0.46))
    }
}

/// An icon, and its word while it fits: `HeaderLook.segment(word:)` wide.
struct HeaderSegmentLabel: View {
    var title: String
    var systemImage: String
    var showsWord: Bool
    var tint: Color?
    /// Alone in its capsule: round without the word.
    var alone = false

    var body: some View {
        HStack(spacing: HeaderLook.wordGap) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .frame(width: HeaderLook.iconBox)
            if showsWord {
                Text(verbatim: title).font(HeaderLook.wordFont).fixedSize()
            }
        }
        .padding(.leading, showsWord ? HeaderLook.wordLead : 0)
        .frame(width: showsWord ? HeaderLook.segment(word: title)
                                : alone ? HeaderLook.height : HeaderLook.iconSegment,
               height: HeaderLook.height, alignment: showsWord ? .leading : .center)
        .modifier(HeaderInk(tint: tint))
        .contentShape(Rectangle())
        .accessibilityLabel(Text(verbatim: title))
    }
}

/// A capsule of segments over the camera or over the panel.
struct HeaderCapsule<Content: View>: View {
    var floating: Double
    var sweep: Animation?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .frame(height: HeaderLook.height)
            .clipShape(Capsule())
            .modifier(HeaderGlass(floating: floating, sweep: sweep))
    }
}

// MARK: - The session's capsule

/// Who the window is about, in the capsule: the avatar, a title and a subtitle.
struct SessionIdentity: Equatable {
    enum Avatar: Equatable {
        /// A training: the paw on the app's pink.
        case training
        /// A plan pasted, not started: the paw outlined.
        case plan
        /// A new training, «Только камера»: the camera on grey.
        case camera(online: Bool)
        /// Recording without a training: a red dot.
        case recording
    }

    var avatar: Avatar
    var title: String
    /// Shown under the title; a recording's clock runs after it («запись · 0:42»).
    var subtitle: String
    var recordingSince: Date?
}

/// Where the window's buttons are, from the capsule's toolbar item: its left edge in the window, and — while the
/// window shows its buttons beside it — the left end of the capsule's glass (concentric with the close button and the
/// window's corner) and the hairline after the zoom button. Window coordinates.
struct WindowLights: Equatable {
    var itemMinX: CGFloat
    var capsuleMinX: CGFloat?
    var hairlineX: CGFloat?
}

/// The session's capsule: the window's buttons (the system's own, not moved: the glass is drawn under them), a hairline,
/// the avatar, the title and the subtitle. In full screen, without the buttons, it starts with the avatar. Short of
/// room (`room`: how wide the item may get), the subtitle goes first, then the title takes an ellipsis.
struct SessionCapsule: View {
    var identity: SessionIdentity
    var lights: WindowLights?
    var room: CGFloat
    var onLights: (WindowLights) -> Void
    @Environment(\.appearsActive) private var appearsActive

    private static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    private static let subtitleFont = NSFont.systemFont(ofSize: 12)
    private static let clockFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let avatar: CGFloat = 28
    /// A wide window's ceiling for the text.
    private static let maxText: CGFloat = 480

    var body: some View {
        let geometry = layout
        HStack(spacing: 8) {
            SessionAvatar(avatar: identity.avatar)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: identity.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(appearsActive ? 1 : 0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !geometry.oneLine { subtitle }
            }
            .frame(width: geometry.text, alignment: .leading)
        }
        .padding(.leading, geometry.lead)
        .padding(.trailing, 14)
        .frame(height: HeaderLook.height)
        .background(alignment: .trailing) {
            // The glass from the window's corner: under the buttons, then the hairline.
            ZStack(alignment: .leading) {
                Color.clear
                if let hairline = geometry.hairline { HeaderHairline(height: 20).offset(x: hairline) }
            }
            .frame(width: geometry.lead + Self.avatar + 8 + geometry.text + 14 + geometry.well)
            .modifier(HeaderGlass(floating: 1))
        }
        // Clicks go through to the title bar under it, as on a window's title: it drags the window. A toolbar item
        // takes no double click of the title bar: the probe does what the user set for one. The full title, when it
        // is cut, is the probe's tooltip (AppKit's, under the pointer whatever takes the clicks).
        .allowsHitTesting(false)
        .background(WindowLightsProbe(onRead: onLights, actsAsTitle: true,
                                      toolTip: geometry.oneLine || geometry.cut ? "\(identity.title) — \(subtitleText(at: .now))" : nil))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: identity.title))
        .accessibilityValue(Text(verbatim: subtitleText(at: .now)))
    }

    @ViewBuilder
    private var subtitle: some View {
        let style = Color.white.opacity(appearsActive ? 0.6 : 0.34)
        if identity.recordingSince != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(verbatim: subtitleText(at: context.date))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(style)
                    .lineLimit(1)
            }
        } else {
            Text(verbatim: identity.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(style)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func subtitleText(at date: Date) -> String {
        guard let since = identity.recordingSince else { return identity.subtitle }
        return "\(identity.subtitle) · \(DurationText.clock(date.timeIntervalSince(since)))"
    }

    private struct Layout {
        var lead: CGFloat, text: CGFloat, well: CGFloat, hairline: CGFloat?, oneLine: Bool, cut: Bool
    }

    private var layout: Layout {
        var lead: CGFloat = 4
        var well: CGFloat = 0
        var hairline: CGFloat?
        if let lights, let capsuleMinX = lights.capsuleMinX, let rule = lights.hairlineX {
            // The avatar 8.5 pt after the hairline (B: hairline 89.5, avatar 98…126).
            lead = max(2, rule + 8.5 - lights.itemMinX)
            well = max(0, lights.itemMinX - capsuleMinX)
            hairline = rule - capsuleMinX - 0.5
        }
        let chrome = lead + Self.avatar + 8 + 14
        let textRoom = max(40, min(Self.maxText, room - chrome))
        let title = HeaderLook.width(identity.title, font: Self.titleFont)
        // A recording's clock: as wide as «00:00» from the start, so the capsule keeps its width for an hour.
        let sub = identity.recordingSince != nil
            ? HeaderLook.width("\(identity.subtitle) · 00:00", font: Self.clockFont)
            : HeaderLook.width(identity.subtitle, font: Self.subtitleFont)
        let oneLine = max(title, sub) > textRoom
        let cut = title > textRoom
        return Layout(lead: lead, text: oneLine ? min(title, textRoom) : max(title, sub), well: well,
                      hairline: hairline, oneLine: oneLine, cut: cut)
    }
}

/// The capsule's avatar: what the window is about, as a glyph on a circle.
private struct SessionAvatar: View {
    var avatar: SessionIdentity.Avatar
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        ZStack {
            switch avatar {
            case .training:
                Circle().fill(MacPalette.pink)
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.29, green: 0.08, blue: 0.16).opacity(0.92))
            case .plan:
                Circle().fill(MacPalette.pink.opacity(0.14))
                Circle().strokeBorder(MacPalette.pink.opacity(0.72), lineWidth: 1.5)
                Image(systemName: "pawprint")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MacPalette.pink)
            case .camera(let online):
                Circle().fill(Color(red: 0.35, green: 0.35, blue: 0.37))
                Image(systemName: online ? "video.fill" : "video.slash.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            case .recording:
                Circle().fill(Color(red: 0.37, green: 0.09, blue: 0.10))
                Circle().fill(MacPalette.red).frame(width: 10, height: 10)
                    .shadow(color: MacPalette.red.opacity(0.7), radius: 3)
            }
        }
        .frame(width: 28, height: 28)
        .saturation(appearsActive ? 1 : 0)
        .opacity(appearsActive ? 1 : 0.62)
        .accessibilityHidden(true)
    }
}

/// Reads, from AppKit, where the capsule's toolbar item is and where the window's buttons are beside it. In full
/// screen the toolbar is in a window of its own and the buttons show only while the menu bar is pulled down: the
/// buttons count only when they are in the item's window, visible, on the item's line.
struct WindowLightsProbe: NSViewRepresentable {
    var onRead: (WindowLights) -> Void
    /// A double click on it does what one on the window's title bar does (System Settings → Desktop & Dock).
    var actsAsTitle = false
    var toolTip: String?

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onRead = onRead
        view.actsAsTitle = actsAsTitle
        if view.toolTip != toolTip { view.toolTip = toolTip }
        view.scheduleReads()
    }

    final class ProbeView: NSView {
        var onRead: ((WindowLights) -> Void)?
        var actsAsTitle = false {
            didSet { if actsAsTitle != oldValue { watchDoubleClicks() } }
        }
        private var observers: [NSObjectProtocol] = []
        private var clicks: Any?
        private var last: WindowLights?
        private var round = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The title bar's double click, on the capsule: the window zooms (fills the screen), goes to the Dock, or
        /// nothing — as the user set. Not in full screen, where the title bar does nothing either.
        private func watchDoubleClicks() {
            if let clicks { NSEvent.removeMonitor(clicks) }
            clicks = nil
            guard actsAsTitle else { return }
            clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard event.clickCount == 2, let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                let owner = NSApp.windows.first { $0.toolbar != nil && $0.frame.contains(window.frame.origin) } ?? window
                guard !owner.styleMask.contains(.fullScreen) else { return event }
                let defaults = UserDefaults.standard
                switch defaults.string(forKey: "AppleActionOnDoubleClick") {
                case "Minimize": owner.performMiniaturize(nil)
                case "None": break
                case .none where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"): owner.performMiniaturize(nil)
                default: owner.performZoom(nil)
                }
                return nil
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didMoveNotification,
                                              NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                                              NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleReads() }
                }
            }
            // The toolbar's item viewer moves when the window's buttons come and go (full screen).
            if let viewer = superview?.superview?.superview {
                viewer.postsFrameChangedNotifications = true
                observers.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: viewer, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleReads() }
                })
            }
            scheduleReads()
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            if let clicks { NSEvent.removeMonitor(clicks) }
        }

        func scheduleReads() {
            round += 1
            let current = round
            DispatchQueue.main.async { [weak self] in self?.read() }
            for delay in [0.1, 0.4, 1.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.round == current else { return }
                    self.read()
                }
            }
        }

        private func read() {
            guard let window else { return }
            let item = window.convertToScreen(convert(bounds, to: nil))
            // The window whose content this is: in full screen the toolbar's window floats over it.
            let owner = NSApp.windows.first { $0.toolbar != nil && $0.frame.contains(CGPoint(x: item.midX, y: item.midY)) }
                ?? window
            var lights = WindowLights(itemMinX: item.minX - owner.frame.minX)
            let buttons = [NSWindow.ButtonType.closeButton, .zoomButton].map {
                owner.standardWindowButton($0) ?? window.standardWindowButton($0)
            }
            if let close = buttons[0], let zoom = buttons[1], close.window === window, !close.isHiddenOrHasHiddenAncestor,
               close.alphaValue > 0.01 {
                let closeFrame = window.convertToScreen(close.convert(close.bounds, to: nil))
                let zoomFrame = window.convertToScreen(zoom.convert(zoom.bounds, to: nil))
                // On the item's line, left of it.
                if abs(closeFrame.midY - item.midY) < 6, zoomFrame.maxX < item.maxX {
                    // Concentric with the close button: the capsule's radius (18) from its centre.
                    lights.capsuleMinX = closeFrame.midX - HeaderLook.height / 2 - owner.frame.minX
                    // As far after the zoom button as the capsule's end is before the close button.
                    lights.hairlineX = zoomFrame.maxX + (closeFrame.minX - (closeFrame.midX - HeaderLook.height / 2))
                        - owner.frame.minX
                }
            }
            guard lights != last else { return }
            last = lights
            onRead?(lights)
        }
    }
}

// MARK: - The camera's island

/// The camera's buttons in one capsule: «C302 | C200» (with a second camera), the camera's menu, and turning the
/// camera when it turns.
struct CameraIsland: View {
    @Environment(AppModel.self) private var model
    var onReconnect: () -> Void

    var body: some View {
        HeaderCapsule(floating: 1) {
            if model.hasSecondCamera {
                CameraSwitcherSegments()
                    .padding(.leading, 4)
                    .padding(.trailing, 2)
                HeaderHairline()
            }
            CameraMenuSegment(onReconnect: onReconnect)
            if model.canPanTilt {
                HeaderHairline()
                PanTiltSegment()
            }
        }
    }
}

/// «C302 · C200» (⌘1 / ⌘2): which camera is on screen, and recorded. Both keep playing.
private struct CameraSwitcherSegments: View {
    @Environment(AppModel.self) private var model
    @Environment(\.appearsActive) private var appearsActive
    @Namespace private var pill

    var body: some View {
        let names = CameraShortNames.make(
            model.settings.cameraDisplayName.isEmpty ? String(localized: "Камера 1") : model.settings.cameraDisplayName,
            model.activeSecondCameraName)
        HStack(spacing: 0) {
            segment(names.0, second: false)
            segment(names.1, second: true)
        }
        .animation(.smooth(duration: 0.25), value: model.isShowingSecondCamera)
        .help("Какую камеру показывать · ⌘1 / ⌘2. Записывается та, что на экране")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Камера")
    }

    private func segment(_ name: String, second: Bool) -> some View {
        let selected = model.isShowingSecondCamera == second
        return Button { model.showCamera(second: second) } label: {
            Text(verbatim: name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.white.opacity(appearsActive ? (selected ? 1 : 0.8) : (selected ? 0.55 : 0.42)))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background {
                    if selected {
                        Capsule().fill(.white.opacity(appearsActive ? 0.17 : 0.1))
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The camera's menu: choose a camera, the quality, the modes, reconnect.
private struct CameraMenuSegment: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    var onReconnect: () -> Void
    @State private var hovering = false

    var body: some View {
        Menu {
            Button("Выбрать камеру…", systemImage: "video.badge.plus") { ui.showCameraPicker = true }
            Button(model.hasSecondCamera ? "Другая вторая камера…" : "Вторая камера…", systemImage: "rectangle.on.rectangle") {
                ui.showSecondCameraPicker = true
            }
            if model.hasSecondCamera {
                Button("Убрать вторую камеру", systemImage: "rectangle.badge.minus") { model.removeSecondCamera() }
            }
            #if !WP_NO_XIAOMI
            Button(model.settings.xiaomiAccountID.isEmpty ? "Войти в Xiaomi…" : "Войти в другой аккаунт Xiaomi…",
                   systemImage: "person.crop.circle.badge.plus") { ui.showXiaomiSignIn = true }
            #endif
            Divider()
            Button("Переподключить", systemImage: "arrow.clockwise", action: onReconnect)
            // The quality of the camera on screen, the one recorded.
            if let quality = model.shownXiaomiQuality {
                let second = model.isShowingSecondCamera
                Divider()
                Picker("Качество", selection: Binding(
                    get: { quality },
                    set: { newValue in
                        Task { await model.setXiaomiQuality(newValue, second: second) }
                    })) {
                    ForEach(AppModel.XiaomiQuality.allCases) {
                        Text(model.qualityTitle($0, source: second ? model.secondXiaomiSource : nil)).tag($0)
                    }
                }
                Text("Записи — в этом же качестве")
                if let size = second ? model.secondVideoSize : model.videoSize {
                    Text("Сейчас \(Int(size.width))×\(Int(size.height))")
                }
            }
            if model.cameraModes.hasOptions {
                Divider()
                CameraModeMenuItems()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.cameraOnScreenIsOnline ? "video.fill" : "video.slash")
                    .font(.system(size: 15, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.85)
            }
            .modifier(HeaderInk(tint: nil))
            .padding(.leading, 12)
            .padding(.trailing, 13)
            .frame(height: HeaderLook.height)
            .background(Rectangle().fill(.white.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(model.cameraOnScreenIsOnline ? "Камера, качество и режим съёмки" : "Камера не на связи — выбрать или переподключить")
        .accessibilityLabel("Камера")
    }
}

/// «Повернуть»: the turning mode — the pad over the picture and the arrow keys (Esc or «Готово» to end it).
private struct PanTiltSegment: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = model.panTilt.isActive
        Button {
            withAnimation(.smooth(duration: 0.25)) { active ? model.panTilt.stop() : model.panTilt.start() }
        } label: {
            HeaderSegmentLabel(title: String(localized: "Повернуть"), systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                               showsWord: true, tint: nil)
        }
        .buttonStyle(HeaderSegmentStyle(isOn: active))
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(active ? "Закончить поворот камеры · Esc" : "Повернуть камеру: стрелки на картинке или на клавиатуре")
    }
}

// MARK: - The panel's groups

/// The panel's words that drop, one at a time, when the groups don't fit over the panel: «Завершить» → «История» →
/// iPhone → «Звук» (→ «Запись»).
enum HeaderWord: Int, CaseIterable, Comparable {
    case finish, history, device, sound, record

    static func < (a: HeaderWord, b: HeaderWord) -> Bool { a.rawValue < b.rawValue }
}

/// What the panel's groups hold, and how wide they are with some words dropped. The groups as before: recording and
/// sound · the linked iPhone · history and finishing.
struct PanelButtons: Equatable {
    var recording: Bool
    var session: Bool
    /// The linked devices' names, nil when none is linked.
    var devices: String?

    /// The words there are, in the order they drop.
    var words: [HeaderWord] {
        HeaderWord.allCases.filter { word in
            switch word {
            case .finish: return session
            case .device: return devices != nil
            case .record: return session && !recording
            case .history, .sound: return true
            }
        }
    }

    /// The words dropped at `level`.
    func folded(_ level: Int) -> Set<HeaderWord> { Set(words.prefix(level)) }

    /// The groups' widths with the words at `level` dropped (the toolbar's spacing aside).
    func width(level: Int) -> CGFloat {
        let folded = folded(level)
        func segment(_ word: HeaderWord, _ title: String, alone: Bool = false) -> CGFloat {
            folded.contains(word) ? (alone ? HeaderLook.height : HeaderLook.iconSegment) : HeaderLook.segment(word: title)
        }
        var first: CGFloat = 0
        if recording {
            first = HeaderLook.recSegment + 1
        } else if session {
            first = segment(.record, Self.recordWord) + 1
        }
        first += segment(.sound, Self.soundWord, alone: first == 0)
        var total = first
        if let devices { total += segment(.device, devices, alone: true) }
        total += session ? segment(.history, Self.historyWord) + 1 + segment(.finish, Self.finishWord)
                         : segment(.history, Self.historyWord, alone: true)
        return total
    }

    static var recordWord: String { String(localized: "Запись") }
    static var soundWord: String { String(localized: "Звук") }
    static var historyWord: String { String(localized: "История") }
    static var finishWord: String { String(localized: "Завершить") }
}

/// «● REC» (or «Запись» in a training not recorded, ⌘R) and «Звук».
struct RecordSoundGroup: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    var folded: Set<HeaderWord>
    var floating: Double
    var sweep: Animation?

    var body: some View {
        HeaderCapsule(floating: floating, sweep: sweep) {
            if model.isRecordingNow || model.session != nil {
                record
                HeaderHairline()
            }
            let on = model.settings.audioEnabled
            Button { model.settings.audioEnabled.toggle() } label: {
                HeaderSegmentLabel(title: PanelButtons.soundWord, systemImage: on ? "speaker.wave.2.fill" : "speaker.slash.fill",
                                   showsWord: !folded.contains(.sound), tint: nil,
                                   alone: !(model.isRecordingNow || model.session != nil))
            }
            .buttonStyle(HeaderSegmentStyle(isOn: on))
            .accessibilityValue(on ? Text("включено") : Text("выключено"))
            .help(on ? "Выключить звук камеры в приложении (запись всегда со звуком)"
                     : "Включить звук камеры в приложении (запись всегда со звуком)")
        }
    }

    private var record: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Button { ui.toggleRecording(model) } label: {
                if model.isRecordingNow {
                    // «● REC» alone, as on the iPhone: the time recorded is in the tip and for VoiceOver.
                    HStack(spacing: 5) {
                        Circle().fill(MacPalette.red).frame(width: 7, height: 7)
                        Text(verbatim: "REC").font(.system(size: 10, weight: .bold)).foregroundStyle(MacPalette.red)
                    }
                    .frame(width: HeaderLook.recSegment, height: HeaderLook.height)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Остановить запись")
                    .accessibilityValue(DurationText.clock(model.recordingDuration(at: context.date)))
                } else {
                    HeaderSegmentLabel(title: PanelButtons.recordWord, systemImage: "record.circle",
                                       showsWord: !folded.contains(.record), tint: nil)
                }
            }
            .buttonStyle(HeaderSegmentStyle())
            .help(model.isRecordingNow
                  ? "REC \(DurationText.clock(model.recordingDuration(at: context.date))) — \(String(localized: "Остановить запись · ⌘R"))"
                  : String(localized: "Записать видео · ⌘R"))
            .disabled(!model.isRecordingNow && !model.settings.isConfigured)
        }
    }
}

/// The linked iPhone (information, not a button): it sees the camera and runs this training.
struct LinkedDeviceGroup: View {
    @Environment(AppModel.self) private var model
    var folded: Set<HeaderWord>
    var floating: Double
    var sweep: Animation?

    var body: some View {
        let devices = model.syncHost.connectedDevices
        if let first = devices.first {
            HeaderCapsule(floating: floating, sweep: sweep) {
                HeaderSegmentLabel(title: devices.map(\.name).joined(separator: ", "), systemImage: first.symbolName,
                                   showsWord: !folded.contains(.device), tint: MacPalette.blue, alone: true)
            }
            .help(devices.count == 1
                  ? String(localized: "\(first.modelTitle) «\(first.name)» видит камеру и ведёт эту тренировку")
                  : String(localized: "Камеру видят и ведут тренировку: \(devices.map(\.name).joined(separator: ", "))"))
        }
    }
}

/// «История» (⌘Y) and, in a training, «Завершить» (⌘.).
struct HistoryFinishGroup: View {
    @Environment(AppModel.self) private var model
    @Environment(MacUIState.self) private var ui
    @Environment(\.openWindow) private var openWindow
    var folded: Set<HeaderWord>
    var floating: Double
    var sweep: Animation?

    var body: some View {
        HeaderCapsule(floating: floating, sweep: sweep) {
            Button { openWindow(id: "history") } label: {
                HeaderSegmentLabel(title: PanelButtons.historyWord, systemImage: "clock.arrow.circlepath",
                                   showsWord: !folded.contains(.history), tint: nil, alone: model.session == nil)
            }
            .buttonStyle(HeaderSegmentStyle())
            .help("История тренировок · ⌘Y")
            if model.session != nil {
                HeaderHairline()
                Button { ui.confirmFinish = true } label: {
                    // One short word, so the panel's buttons keep their words over the panel (a recording stops with
                    // the training: the confirmation says so).
                    HeaderSegmentLabel(title: PanelButtons.finishWord, systemImage: "flag.checkered",
                                       showsWord: !folded.contains(.finish), tint: nil)
                }
                .buttonStyle(HeaderSegmentStyle())
                .help("Завершить тренировку · ⌘.")
            }
        }
    }
}

extension AppModel {
    /// The quality of the camera on screen; nil when it is not a Mi Home camera.
    var shownXiaomiQuality: XiaomiQuality? { isShowingSecondCamera ? secondXiaomiQuality : xiaomiQuality }

    /// Whether the camera on screen can be shown: go2rtc runs (or an outside one is used).
    var cameraOnScreenIsOnline: Bool {
        #if DEBUG
        // `--demo-camera`: the still picture is the camera, and it is on screen (go2rtc never runs in these copies).
        if DemoData.cameraImage != nil { return true }
        #endif
        return settings.connectionMode == .external || embedded.status.isRunning
    }

    /// The camera on screen by its short name: «C302» for «Xiaomi Smart Camera C302» (the switcher's names).
    var shownCameraShortName: String {
        let first = settings.cameraDisplayName.isEmpty ? String(localized: "Камера 1") : settings.cameraDisplayName
        if hasSecondCamera {
            let names = CameraShortNames.make(first, activeSecondCameraName)
            return isShowingSecondCamera ? names.1 : names.0
        }
        return first.count <= 14 ? first : CameraShortNames.model(of: first) ?? first
    }
}

// MARK: - The shadow's way across the panel's edge

/// When the panel folds away or comes back, its edge sweeps under the panel's groups along the panel's own curve
/// (`.smooth(duration: 0.35)`): each group's shadow comes as the picture slides under it, and goes as the panel covers
/// the picture under it again.
enum HeaderShadowSweep {
    static let panelDuration = ConsolePanelLayout.foldDuration

    /// The moment the edge, on its way from the panel's place to the window's edge (or back), is under `x`.
    static func animation(groupMidX x: CGFloat, edge: CGFloat, window: CGFloat, floating: Bool) -> Animation {
        guard window - edge > 1 else { return .easeInOut(duration: 0.2) }
        let fraction = floating ? (x - edge) / (window - edge) : (window - x) / (window - edge)
        let delay = max(0, time(atFraction: min(max(fraction, 0), 1)) - 0.04 * ConsolePanelLayout.slowMotion)
        let slow = ConsolePanelLayout.slowMotion
        return floating ? .easeOut(duration: 0.16 * slow).delay(delay) : .easeIn(duration: 0.1 * slow).delay(delay)
    }

    /// A critically damped spring (SwiftUI's `.smooth`): 1 − (1 + ωt)·e^(−ωt), ω = 2π / duration.
    private static func time(atFraction fraction: CGFloat) -> Double {
        let omega = 2 * Double.pi / panelDuration
        func position(_ t: Double) -> Double { 1 - (1 + omega * t) * exp(-omega * t) }
        var low = 0.0, high = panelDuration * 1.5
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if position(mid) < Double(fraction) { low = mid } else { high = mid }
        }
        return low
    }
}
#endif
