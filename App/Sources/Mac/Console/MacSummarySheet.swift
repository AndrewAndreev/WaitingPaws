#if os(macOS)
import AppKit
import Charts
import SwiftUI
import WaitingPawsCore

/// After the last exit: the numbers, plan vs actual per exit, the trainer log, the video file.
struct MacSummarySheet: View {
    @Environment(AppModel.self) private var model
    let record: TrainingRecord
    var onHistory: () -> Void
    var onClose: () -> Void
    @State private var copied = false

    var body: some View {
        let log = SessionLogFormatter.text(for: record)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(MacPalette.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Тренировка завершена").font(.title3.weight(.semibold))
                    Text("\(record.plan.title) · \(MacFormat.time.string(from: record.startedAt))–\(MacFormat.time.string(from: record.finishedAt)) (\(DurationText.short(max(60, (record.duration / 60).rounded() * 60))))")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                stat(String(localized: "\(record.completedExits) из \(record.plan.exits.count)"), String(localized: "выходов"))
                Divider().frame(height: 34)
                stat("\(record.falseStarts)", String(localized: "фальстартов"), tint: record.falseStarts > 0 ? MacPalette.orange : nil)
                Divider().frame(height: 34)
                stat(DurationText.clock(longest), String(localized: "дольше всего за дверью"))
            }
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("План и факт").font(.headline)
                    Spacer()
                    legend(MacPalette.pink.opacity(0.35), String(localized: "план"))
                    legend(MacPalette.green, String(localized: "за дверью"))
                    legend(MacPalette.orange, String(localized: "фальстарт"))
                }
                Chart {
                    ForEach(record.plan.exits) { exit in
                        BarMark(x: .value("Выход", "\(exit.number)"), y: .value("План", exit.duration / 60), width: .ratio(0.7))
                            .foregroundStyle(MacPalette.pink.opacity(0.28))
                    }
                    ForEach(record.results) { result in
                        BarMark(x: .value("Выход", "\(result.number)"), y: .value("Факт", result.awayDuration / 60),
                                width: .ratio(result.falseStart ? 0.22 : 0.4))
                            .foregroundStyle(result.falseStart ? MacPalette.orange : MacPalette.green)
                            .position(by: .value("Попытка", result.falseStart ? "a" : "b"))
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let minutes = value.as(Double.self) { Text(DurationText.clock(minutes * 60)) }
                        }
                    }
                }
                .frame(height: 130)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Лог для тренера").font(.headline)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log, forType: .string)
                        copied = true
                    } label: { Label(copied ? "Скопировано" : "Скопировать", systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .controlSize(.small)
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                }
                ScrollView {
                    Text(log)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 118)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            }

            if let url = model.store.recordingURL(for: record) {
                HStack(spacing: 10) {
                    Image(systemName: "film").foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text(fileInfo(url)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Показать в Finder") { Finder.reveal(url) }
                        .controlSize(.small)
                }
            }

            Divider()

            HStack {
                ShareLink(item: log) { Label("Отправить лог…", systemImage: "square.and.arrow.up") }
                Button("История", action: onHistory)
                Spacer()
                Button("Готово", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(MacPalette.pinkDeep)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    private var longest: TimeInterval {
        record.results.filter { !$0.falseStart }.map(\.awayDuration).max() ?? 0
    }

    private func fileInfo(_ url: URL) -> String {
        var parts = [DurationText.clock(record.duration)]
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if model.finalizingFileNames.contains(url.lastPathComponent) { parts.append(String(localized: "готовится…")) }
        return parts.joined(separator: " · ")
    }

    private func stat(_ value: String, _ label: String, tint: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Text(value).font(MacPalette.digits(20, weight: .semibold)).foregroundStyle(tint ?? .primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// After «Только запись»: where the file is.
struct MacClipSavedSheet: View {
    let clip: RecordingClip
    var onHistory: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "film.stack")
                    .font(.system(size: 26))
                    .foregroundStyle(MacPalette.pink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Запись сохранена").font(.title3.weight(.semibold))
                    Text(clip.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack {
                ShareLink(item: clip.url) { Label("Отправить…", systemImage: "square.and.arrow.up") }
                Button("Показать в Finder") { Finder.reveal(clip.url) }
                Spacer()
                Button("История", action: onHistory)
                Button("Готово", action: onClose)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(MacPalette.pinkDeep)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
#endif
