#if DEBUG
import Foundation
import SwiftUI
import WaitingPawsCore

/// Sample data for UI checks without a camera or a real history (DEBUG launch arguments only).
enum DemoData {
    /// A realistic trainer's message (9 exits, own break after exit 6, notes, false-start rule).
    static let planText = """
    🐹 Тренировка на воскресенье - Таня/Андрей - 04.10.2026

    ➡️ Второго человека уводим из квартиры минимум за 30-40 минут до начала тренировки с обязательным сокрытием ухода
    ➡️ За 30-60 минут включить музыку, отпереть дверь изнутри, закрыть окна
    ➡️ В перерывах сидите за столом, работаете
    ➡️ Все перерывы 2 минуты

    1 выход - 10 секунд
    2 выход - 30 секунд
    3 выход - 15 секунд
    4 выход - 1 минута
    5 выход - 45 секунд
    6 выход - 2 минуты ИЛИ до вставания
    Перерыв 5 минут
    7 выход - 30 секунд
    8 выход - 3 минуты ИЛИ до вставания
    9 выход - 1 минута

    🔖 Фальстарт: если пошла к двери во время длинного выхода или если при выходе вы услышали звуки, на которые она будет реагировать - сразу возвращаемся, через обычный перерыв снова идём на длинный выход
    """

    /// `--demo-camera=<path>`: a still picture instead of the live stream. One argument on purpose: AppKit
    /// treats a separate argument that is an existing file path as a document to open and then shows no window.
    static let cameraImage: NSImageOrUIImage? = {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-camera=") }) else { return nil }
        return NSImageOrUIImage(contentsOfFile: String(argument.dropFirst("--demo-camera=".count)))
    }()

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private static let days: [(String, String, [TimeInterval], Int?)] = [
        ("2026-09-06 18:04", "Таня / Андрей", [0, 2, 2, 2, 5], 3),
        ("2026-09-09 19:20", "Андрей", [2, 5, 2, 5, 10], nil),
        ("2026-09-12 18:41", "Таня / Андрей", [5, 10, 5, 10, 15], nil),
        ("2026-09-14 11:02", "Таня", [5, 10, 15, 10, 20], 4),
        ("2026-09-17 19:05", "Андрей", [10, 15, 10, 20, 30], nil),
        ("2026-09-20 12:30", "Таня / Андрей", [10, 20, 30, 15, 30, 45], nil),
        ("2026-09-23 18:55", "Андрей", [15, 30, 20, 45, 30, 60], nil),
        ("2026-09-26 18:10", "Таня / Андрей", [20, 30, 45, 30, 60, 45], 4),
        ("2026-09-28 10:47", "Таня", [30, 45, 30, 60, 90, 60], nil),
        ("2026-09-30 19:12", "Андрей", [30, 60, 45, 90, 60, 120], nil),
        ("2026-10-02 18:36", "Таня / Андрей", [30, 60, 45, 90, 120, 60, 150], 6),
    ]

    private static let weekdays = ["на воскресенье", "на понедельник", "на вторник", "на среду", "на четверг", "на пятницу", "на субботу"]

    /// Eleven finished trainings over four weeks, newest first; time behind the door grows from 0:05 to 2:30.
    static func history() -> [TrainingRecord] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return days.reversed().map { start, trainers, exits, falseStartAt in
            let date = formatter.date(from: start)!
            let weekday = calendar.component(.weekday, from: date) - 1
            let plan = TrainingPlan(title: "Тренировка \(weekdays[weekday])", trainers: trainers, date: date,
                                    exits: exits.enumerated().map { PlannedExit(number: $0.offset + 1, duration: $0.element) })
            let clock = Clock(date)
            let session = TrainingSession(plan: plan, clock: { clock.now })
            for (index, planned) in exits.enumerated() {
                let jitter = TimeInterval((index * 7 + Int(planned)) % 5)
                if falseStartAt == index {
                    session.startExit(); clock.now += 6; session.markBehindDoor()
                    clock.now += max(1, planned * 0.4); session.resetExit(); clock.now += 120 + jitter
                }
                session.startExit(); clock.now += 5 + jitter; session.markBehindDoor()
                clock.now += planned + 1 + jitter / 2; session.endExit()
                clock.now += index == exits.count - 1 ? 30 : 120 + jitter
            }
            session.finish()
            return session.makeRecord(recordingFileName: nil)
        }
    }

    /// Camera settings of the Xiaomi C302 (`xiaomi.camera.c302n`), a fragment of its miot-spec.org spec.
    static let c302Spec = #"""
    {"services": [{"iid": 2, "type": "urn:miot-spec-v2:service:camera-control:0000782F:xiaomi-c302n:1", "properties": [{"iid": 3, "type": "urn:miot-spec-v2:property:night-shot:00000057:xiaomi-c302n:1", "format": "uint8", "access": ["read", "write", "notify"], "value-list": [{"value": 0, "description": "Off"}, {"value": 1, "description": "On"}, {"value": 2, "description": "Auto"}]}, {"iid": 4, "type": "urn:miot-spec-v2:property:image-rollover:00000058:xiaomi-c302n:1", "format": "uint16", "access": ["read", "write", "notify"], "value-range": [0, 270, 90]}, {"iid": 5, "type": "urn:miot-spec-v2:property:time-watermark:00000087:xiaomi-c302n:1", "format": "bool", "access": ["read", "write", "notify"]}, {"iid": 7, "type": "urn:miot-spec-v2:property:glimmer-full-color:00000089:xiaomi-c302n:1", "format": "bool", "access": ["read", "write", "notify"]}, {"iid": 9, "type": "urn:miot-spec-v2:property:human-tracking:000001A8:xiaomi-c302n:1", "format": "bool", "access": ["read", "write", "notify"]}, {"iid": 12, "type": "urn:miot-spec-v2:property:power-frequency:0000036B:xiaomi-c302n:1", "format": "uint8", "access": ["read", "write", "notify"], "value-list": [{"value": 0, "description": "auto"}, {"value": 1, "description": "50"}, {"value": 2, "description": "60"}]}]}, {"iid": 4, "type": "urn:miot-spec-v2:service:indicator-light:00007803:xiaomi-c302n:1", "properties": [{"iid": 1, "type": "urn:miot-spec-v2:property:on:00000006:xiaomi-c302n:1", "format": "bool", "access": ["read", "write", "notify"]}]}, {"iid": 8, "type": "urn:miot-spec-v2:service:ai-detection:000078C8:xiaomi-c302n:1", "properties": [{"iid": 22, "type": "urn:miot-spec-v2:property:pet-tracking:000003E4:xiaomi-c302n:1", "format": "bool", "access": ["read", "write", "notify"]}]}]}
    """#
}


#if os(macOS)
typealias NSImageOrUIImage = NSImage
#else
typealias NSImageOrUIImage = UIImage
#endif
#endif
