import SwiftUI
import WaitingPawsCore

/// Camera modes inside the camera menu (Mac toolbar, iPhone camera pill): night mode on its own,
/// everything else the camera declares in a submenu. Nothing for cameras without settings.
struct CameraModeMenuItems: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let modes = model.cameraModes
        if modes.hasOptions {
            if let night = modes.nightMode {
                CameraModeMenuControl(option: night)
            }
            let others = modes.options.filter { $0.setting != .nightShot }
            if !others.isEmpty {
                Menu {
                    Section { ForEach(others.filter(\.setting.isPicture)) { CameraModeMenuControl(option: $0) } }
                    Section { ForEach(others.filter { !$0.setting.isPicture }) { CameraModeMenuControl(option: $0) } }
                    if case .unavailable(let reason) = modes.state {
                        Section { Text(reason) }
                    }
                } label: {
                    Label("Camera Settings", systemImage: "camera.badge.ellipsis")
                }
            }
        }
    }
}

/// One camera mode as a menu item: a checkmark for switches, a submenu of choices for modes.
struct CameraModeMenuControl: View {
    @Environment(AppModel.self) private var model
    let option: CameraModeOption

    var body: some View {
        let modes = model.cameraModes
        switch option.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { modes.isOn(option) }, set: { change(to: option.value(on: $0)) })) {
                Label(option.title, systemImage: option.systemImage)
            }
            .disabled(!modes.canChange(option))
        case .choice(let choices):
            Picker(selection: Binding(get: { modes.choice(option) }, set: { change(to: option.value(choice: $0)) })) {
                ForEach(choices) { Text($0.title).tag($0.value) }
            } label: {
                #if os(macOS)
                // A Mac submenu title does not show the selection by itself.
                Label("\(option.title) · \(option.text(for: modes.value(option)))", systemImage: option.systemImage)
                #else
                Label(option.title, systemImage: option.systemImage)
                #endif
            }
            .pickerStyle(.menu)
            .disabled(!modes.canChange(option))
        }
    }

    private func change(to value: MiotValue) {
        Task {
            await model.cameraModes.set(option, to: value)
            if let error = model.cameraModes.changeError { model.errorMessage = error }
        }
    }
}

/// Camera modes as form rows (Mac Settings → Камера): a menu picker or a switch per setting.
struct CameraModeFormRow: View {
    @Environment(AppModel.self) private var model
    let option: CameraModeOption

    var body: some View {
        let modes = model.cameraModes
        switch option.kind {
        case .toggle:
            Toggle(isOn: Binding(get: { modes.isOn(option) }, set: { change(to: option.value(on: $0)) })) {
                label
            }
            .disabled(!modes.canChange(option))
        case .choice(let choices):
            Picker(selection: Binding(get: { modes.choice(option) }, set: { change(to: option.value(choice: $0)) })) {
                ForEach(choices) { Text($0.title).tag($0.value) }
            } label: {
                label
            }
            .disabled(!modes.canChange(option))
        }
    }

    @ViewBuilder private var label: some View {
        Text(option.title)
        if let hint = option.hint { Text(hint) }
    }

    private func change(to value: MiotValue) {
        Task { await model.cameraModes.set(option, to: value) }
    }
}
