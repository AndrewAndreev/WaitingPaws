import SwiftUI
import WaitingPawsCore

/// Text field that accepts "15 с", "2 мин", "1:30" or plain seconds, with ± buttons.
struct DurationField: View {
    @Binding var value: TimeInterval
    var step: TimeInterval = 5

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            stepButton("minus") { value = max(0, value - stepFor(value - 1)) }
            TextField("0 с", text: $text)
                .multilineTextAlignment(.center)
                .frame(minWidth: 64)
                .focused($focused)
                .onSubmit(commit)
                .plainInput()
                #if os(macOS)
                .textFieldStyle(.roundedBorder)
                #endif
            stepButton("plus") { value += stepFor(value) }
        }
        .onAppear { text = DurationText.short(value) }
        .onChange(of: value) { _, newValue in
            if !focused { text = DurationText.short(newValue) }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
    }

    private func stepFor(_ current: TimeInterval) -> TimeInterval {
        current >= 60 ? 30 : step
    }

    private func commit() {
        if let parsed = DurationText.parse(text) {
            value = max(0, parsed)
        }
        text = DurationText.short(value)
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Same as `DurationField` but empty text means "use the default".
struct OptionalDurationField: View {
    @Binding var value: TimeInterval?
    var placeholder: String

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .multilineTextAlignment(.trailing)
            .focused($focused)
            .onSubmit(commit)
            .plainInput()
            #if os(macOS)
            .textFieldStyle(.roundedBorder)
            #endif
            .onAppear { text = value.map(DurationText.short) ?? "" }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            value = nil
        } else if let parsed = DurationText.parse(trimmed) {
            value = max(0, parsed)
        }
        text = value.map(DurationText.short) ?? ""
    }
}


/// Preset lists for the plan editor.
enum DurationPresets {
    static let exits: [TimeInterval] = [0, 2, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 300, 600]
    static let breaks: [TimeInterval] = [60, 90, 120, 180, 240, 300, 420, 600, 900]
}

/// Value chip that opens `DurationEditor` in a popover. With `defaultValue`, `nil` means "use the default"
/// and is shown dimmed. A fixed `width` keeps neighbouring controls in place while the value changes.
struct DurationButton: View {
    @Binding var value: TimeInterval?
    var title: String
    var presets: [TimeInterval]
    var defaultValue: TimeInterval? = nil
    var secondsStep = 1
    var font: Font = .system(.body, design: .rounded)
    var width: CGFloat? = nil

    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            Text(label)
                .font(font.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(value == nil ? .secondary : .primary)
                .frame(width: width)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(DurationText.short(shown))
        .popover(isPresented: $editing) {
            DurationEditor(value: $value, title: title, presets: presets, defaultValue: defaultValue, secondsStep: secondsStep)
                .presentationCompactAdaptation(.popover)
        }
        #if DEBUG
        // `--demo-duration-editor` opens the first exit's break editor (UI checks without tapping).
        .task {
            guard CommandLine.arguments.contains("--demo-duration-editor"), title == "Перерыв после выхода 1" else { return }
            try? await Task.sleep(for: .seconds(1))
            editing = true
        }
        #endif
    }

    private var shown: TimeInterval { (value ?? defaultValue ?? 0).rounded() }

    /// "2 с", "5 мин", or "1:30" when minutes and seconds mix ("1 мин 30 с" does not fit a chip).
    private var label: String {
        shown >= 60 && Int(shown) % 60 != 0 ? DurationText.clock(shown) : DurationText.short(shown)
    }
}

extension DurationButton {
    /// For values without a default.
    init(value: Binding<TimeInterval>, title: String, presets: [TimeInterval], secondsStep: Int = 1,
         font: Font = .system(.body, design: .rounded), width: CGFloat? = nil) {
        self.init(value: Binding<TimeInterval?>(get: { value.wrappedValue }, set: { value.wrappedValue = $0 ?? 0 }),
                  title: title, presets: presets, secondsStep: secondsStep, font: font, width: width)
    }
}

/// Any duration: minute and second wheels (a text field on the Mac), quick presets and an optional "default".
struct DurationEditor: View {
    @Binding var value: TimeInterval?
    var title: String
    var presets: [TimeInterval]
    var defaultValue: TimeInterval?
    var secondsStep: Int

    @Environment(\.dismiss) private var dismiss

    private var total: Int { Int((value ?? defaultValue ?? 0).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(.headline, design: .rounded))
                Spacer()
                Button("Готово") { dismiss() }
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
            }
            #if os(iOS)
            HStack(spacing: 0) {
                wheel(String(localized: "Минуты"), selection: Binding(get: { total / 60 }, set: { value = TimeInterval($0 * 60 + total % 60) }),
                      options: Array(0...max(30, total / 60)), unit: String(localized: "мин"))
                wheel(String(localized: "Секунды"), selection: Binding(get: { total % 60 }, set: { value = TimeInterval(total / 60 * 60 + $0) }),
                      options: secondOptions, unit: String(localized: "с"))
            }
            .frame(height: 140)
            #else
            DurationField(value: Binding(get: { TimeInterval(total) }, set: { value = $0 }), step: TimeInterval(secondsStep))
            #endif
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    chip(DurationText.short(preset), selected: value != nil && total == Int(preset)) {
                        value = preset
                        dismiss()
                    }
                }
            }
            if let defaultValue {
                chip(String(localized: "По умолчанию · \(DurationText.short(defaultValue))"), selected: value == nil) {
                    value = nil
                    dismiss()
                }
            }
        }
        .padding(16)
        .frame(width: 290)
    }

    /// Seconds offered by the wheel; the current value is always selectable even off the step.
    private var secondOptions: [Int] {
        var options = Array(stride(from: 0, to: 60, by: max(1, secondsStep)))
        if !options.contains(total % 60) { options.append(total % 60); options.sort() }
        return options
    }

    #if os(iOS)
    private func wheel(_ label: String, selection: Binding<Int>, options: [Int], unit: String) -> some View {
        Picker(label, selection: selection) {
            ForEach(options, id: \.self) { Text(verbatim: "\($0) \(unit)").tag($0) }
        }
        .pickerStyle(.wheel)
        .frame(maxWidth: .infinity)
        .clipped()
    }
    #endif

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(.subheadline, design: .rounded, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .foregroundStyle(selected ? .black : .white)
                .background(selected ? Theme.accent : Theme.control, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
