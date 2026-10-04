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

    /// `--demo-camera <path>`: a still picture instead of the live stream.
    static let cameraImage: NSImageOrUIImage? = {
        guard let index = CommandLine.arguments.firstIndex(of: "--demo-camera"), index + 1 < CommandLine.arguments.count else { return nil }
        return NSImageOrUIImage(contentsOfFile: CommandLine.arguments[index + 1])
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
}

#if os(macOS)
typealias NSImageOrUIImage = NSImage
#else
typealias NSImageOrUIImage = UIImage
#endif
#endif
