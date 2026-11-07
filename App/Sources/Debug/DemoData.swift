#if DEBUG
import Foundation
import SwiftUI
import WaitingPawsCore

/// Sample data for UI checks without a camera or a real history (DEBUG launch arguments only).
enum DemoData {
    /// A realistic trainer's message (9 exits, own break after exit 6, notes, false-start rule), in the app's
    /// language (screenshots for both App Store languages).
    static var planText: String { CoreLanguage.current == .ru ? planTextRU : planTextEN }

    static let planTextEN = """
    🐶 Sunday training - Anna/Mark - 04.10.2026

    ➡️ The second person leaves the apartment at least 30-40 minutes before the training, without the dog noticing
    ➡️ 30-60 minutes before: turn on music, unlock the door from inside, close the windows
    ➡️ During breaks sit at the table and work
    ➡️ All breaks 2 minutes

    Exit 1 - 10 seconds
    Exit 2 - 30 seconds
    Exit 3 - 15 seconds
    Exit 4 - 1 minute
    Exit 5 - 45 seconds
    Exit 6 - 2 minutes OR until the dog stands up
    Break 5 minutes
    Exit 7 - 30 seconds
    Exit 8 - 3 minutes OR until the dog stands up
    Exit 9 - 1 minute

    🔖 False start: if she walks to the door during a long exit, or you heard sounds she will react to, come back right away and after a normal break go for the long exit again
    """

    static let planTextRU = """
    🐹 Тренировка на воскресенье - Аня/Марк - 04.10.2026

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

    /// The second demo camera's still («Кухня» in the camera list): `<name>-kitchen.<ext>` next to the
    /// `--demo-camera` picture (Tools/demo-camera-kitchen.jpg), when it was copied along.
    static let kitchenImage: NSImageOrUIImage? = {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--demo-camera=") }) else { return nil }
        let hall = URL(fileURLWithPath: String(argument.dropFirst("--demo-camera=".count)))
        let kitchen = hall.deletingPathExtension().path + "-kitchen." + hall.pathExtension
        return NSImageOrUIImage(contentsOfFile: kitchen)
    }()

    /// `--demo-stopwatch <seconds>`: the iPhone card's stopwatch (a tap on the big number) started that long ago.
    static let stopwatchSeconds: TimeInterval? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-stopwatch"), index + 1 < arguments.count else { return nil }
        return TimeInterval(arguments[index + 1])
    }()

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private static let days: [(String, String, [TimeInterval], Int?)] = [
        ("2026-09-06 18:04", "Аня / Марк", [0, 2, 2, 2, 5], 3),
        ("2026-09-09 19:20", "Марк", [2, 5, 2, 5, 10], nil),
        ("2026-09-12 18:41", "Аня / Марк", [5, 10, 5, 10, 15], nil),
        ("2026-09-14 11:02", "Аня", [5, 10, 15, 10, 20], 4),
        ("2026-09-17 19:05", "Марк", [10, 15, 10, 20, 30], nil),
        ("2026-09-20 12:30", "Аня / Марк", [10, 20, 30, 15, 30, 45], nil),
        ("2026-09-23 18:55", "Марк", [15, 30, 20, 45, 30, 60], nil),
        ("2026-09-26 18:10", "Аня / Марк", [20, 30, 45, 30, 60, 45], 4),
        ("2026-09-28 10:47", "Аня", [30, 45, 30, 60, 90, 60], nil),
        ("2026-09-30 19:12", "Марк", [30, 60, 45, 90, 60, 120], nil),
        ("2026-10-02 18:36", "Аня / Марк", [30, 60, 45, 90, 120, 60, 150], 6),
    ]

    private static let weekdays = ["на воскресенье", "на понедельник", "на вторник", "на среду", "на четверг", "на пятницу", "на субботу"]
    private static let weekdaysEN = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private static func trainersEN(_ ru: String) -> String {
        ru.replacingOccurrences(of: "Аня", with: "Anna").replacingOccurrences(of: "Марк", with: "Mark")
    }

    /// The trainer's own break after one exit: 5 minutes after exit 6 on 2 Oct («перерыв после 5:02 (план 5 мин)»).
    private static func ownBreak(_ start: String, _ index: Int) -> TimeInterval? {
        start == "2026-10-02 18:36" && index == 5 ? 300 : nil
    }

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
            let english = CoreLanguage.current == .en
            let plan = TrainingPlan(title: english ? "\(weekdaysEN[weekday]) training" : "Тренировка \(weekdays[weekday])",
                                    trainers: english ? trainersEN(trainers) : trainers, date: date,
                                    exits: exits.enumerated().map {
                                        PlannedExit(number: $0.offset + 1, duration: $0.element,
                                                    breakAfter: ownBreak(start, $0.offset))
                                    })
            let clock = Clock(date)
            let session = TrainingSession(plan: plan, clock: { clock.now })
            for (index, planned) in exits.enumerated() {
                let jitter = TimeInterval((index * 7 + Int(planned)) % 5)
                if falseStartAt == index {
                    session.markBehindDoor()
                    clock.now += max(1, planned * 0.4); session.resetExit(); clock.now += 120 + jitter
                }
                session.markBehindDoor()
                clock.now += planned + 1 + jitter / 2; session.endExit()
                clock.now += index == exits.count - 1 ? 30 : (ownBreak(start, index) ?? 120) + jitter
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
