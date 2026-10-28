#if os(macOS)
import AppKit
import WaitingPawsCore

/// «Подключить iPhone?» for the iPhone link, shown over whatever window is in front (the welcome window
/// before a camera is set up, the «Пульт», History, Settings) — or as a standalone alert when no window is open.
/// The Dock icon bounces until the app is brought forward, since the request comes from the other device.
@MainActor
enum MacPairingPrompt {
    private static var current: (id: UUID, alert: NSAlert, window: NSWindow?)?

    static func present(_ request: SyncHost.PairingRequest, host: SyncHost) {
        dismissCurrent()
        let alert = NSAlert()
        alert.messageText = String(localized: "Подключить «\(request.device.name)»?")
        alert.informativeText = informativeText(request.device, hostName: host.hostName)
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Разрешить"))
        alert.addButton(withTitle: String(localized: "Отклонить"))
        if request.wasPaired {
            // Paired before, yet no proof of it: maybe another device under its name. Warn, and Return declines.
            alert.informativeText = String(localized: "Этот iPhone уже был подключён, но не подтвердил это. Если на нём не нажимали «Забыть», нажмите «Отклонить».")
                + "\n\n" + alert.informativeText
            alert.alertStyle = .warning
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
        }
        alert.icon = NSApp.applicationIconImage

        NSApp.requestUserAttention(.criticalRequest)
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            guard current?.id == request.id else { return }
            current = nil
            host.answerPairing(allow: response == .alertFirstButtonReturn)
        }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0.attachedSheet == nil }
        current = (request.id, alert, window)
        if let window {
            alert.beginSheetModal(for: window, completionHandler: answer)
        } else {
            answer(alert.runModal())
        }
    }

    /// Which device asks (iOS calls every iPhone just "iPhone", so its model and this Mac's name tell the pairs apart),
    /// then what it gets.
    static func informativeText(_ device: SyncDevice, hostName: String) -> String {
        String(localized: "\(device.modelTitle) просит доступ к «\(hostName)». Он увидит камеру этого Mac и сможет вести тренировку: кнопки, запись, лог. Запись и лог сохраняются на Mac. Разрешение запоминается, его можно отозвать в настройках.")
    }

    /// The iPhone disconnected before the answer.
    static func cancel(_ request: SyncHost.PairingRequest) {
        guard current?.id == request.id else { return }
        dismissCurrent()
    }

    private static func dismissCurrent() {
        guard let current else { return }
        self.current = nil
        if let window = current.window, let sheet = current.alert.window as NSWindow?, window.attachedSheet == sheet {
            window.endSheet(sheet, returnCode: .abort)
        } else {
            NSApp.abortModal()
        }
    }
}
#endif
