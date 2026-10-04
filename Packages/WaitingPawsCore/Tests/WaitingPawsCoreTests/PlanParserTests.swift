import XCTest
@testable import WaitingPawsCore

final class PlanParserTests: XCTestCase {
    /// These tests check the Russian texts (the default language of the app's first users).
    override func setUp() {
        super.setUp()
        CoreLanguage.current = .ru
    }

    let sampleWithDefaultBreaks = """
    🐹 Тренировка на понедельник - Таня/Андрей - 05.10.2026

    ➡️ Второго человека уводим из квартиры минимум за 30-40 минут до начала тренировки с обязательным сокрытием ухода. Вернуться можно минимум через 20-30 минут после окончания тренировки
    ➡️ За 30-60 минут включить музыку, отпереть дверь изнутри, закрыть окна
    ➡️ В перерывах сидите за столом, работаете
    ➡️ Все перерывы 2 минуты 

    1 выход - 5 секунд
    2 выход - 10 секунд
    3 выход - 5 секунд
    4 выход - 15 секунд
    5 выход - 30 секунд ИЛИ до вставания
    6 выход - 10 секунд
    7 выход - 1 минута ИЛИ до вставания

    🔖 Фальстарт: если пошла к двери во время длинного выхода или если при выходе вы услышали звуки, на которые она будет реагировать - сразу возвращаемся, через обычный перерыв снова идём на длинный выход. Если на третьей попытке выхода снова зафальстартила - завершаем тренировку
    """

    let sampleWithExplicitBreaks = """
    🐹 Тренировка на пятницу - Андрей - 25.09.2026

    ➡️ За 30-60 минут включить музыку, отпереть дверь изнутри, закрыть окна
    ➡️ В перерывах сидите за столом, работаете
    ➡️ Второй человек сидит за столом, работает. Дверь к нему открыта

    1 выход - 0 секунд (выйти и сразу вернуться)
    Перерыв 2 минуты
    2 выход - 2 секунды
    Перерыв 2 минуты
    3 выход - 2 секунды
    Перерыв 5 минут
    4 выход - 2 секунды
    Перерыв 2 минуты
    5 выход - 5 секунд
    Перерыв 2 минуты
    6 выход - 5 секунд
    Перерыв 5 минут
    7 выход - 2 секунды
    Перерыв 2 минуты
    8 выход - 5 секунд
    Перерыв 2 минуты
    9 выход - 20 секунд ИЛИ до вставания
    """

    func testDefaultBreaksSample() {
        let plan = PlanParser.parse(sampleWithDefaultBreaks)

        XCTAssertEqual(plan.title, "Тренировка на понедельник")
        XCTAssertEqual(plan.trainers, "Таня/Андрей")
        XCTAssertEqual(plan.date.map { TrainingPlan.dateFormatter.string(from: $0) }, "05.10.2026")
        XCTAssertEqual(plan.defaultBreak, 120)
        XCTAssertEqual(plan.exits.count, 7)
        XCTAssertEqual(plan.exits.map(\.duration), [5, 10, 5, 15, 30, 10, 60])
        XCTAssertEqual(plan.exits.map(\.untilStanding), [false, false, false, false, true, false, true])
        XCTAssertTrue(plan.exits.allSatisfy { $0.breakAfter == nil })
        XCTAssertEqual(plan.breakAfter(exitAt: 3), 120)
        XCTAssertEqual(plan.notes.count, 5)
        XCTAssertTrue(plan.notes.last?.hasPrefix("Фальстарт") == true)
    }

    func testExplicitBreaksSample() {
        let plan = PlanParser.parse(sampleWithExplicitBreaks)

        XCTAssertEqual(plan.title, "Тренировка на пятницу")
        XCTAssertEqual(plan.trainers, "Андрей")
        XCTAssertEqual(plan.exits.count, 9)
        XCTAssertEqual(plan.exits[0].duration, 0)
        XCTAssertEqual(plan.exits[0].note, "выйти и сразу вернуться")
        // "Перерыв 2 минуты" after most exits becomes the plan's break; only the 5-minute ones stay per exit.
        XCTAssertEqual(plan.defaultBreak, 120)
        XCTAssertEqual(plan.exits.map(\.breakAfter), [nil, nil, 300, nil, nil, 300, nil, nil, nil])
        XCTAssertEqual(plan.breakAfter(exitAt: 0), 120)
        XCTAssertEqual(plan.exits[8].duration, 20)
        XCTAssertTrue(plan.exits[8].untilStanding)
        XCTAssertNil(plan.exits[8].breakAfter)
        XCTAssertEqual(plan.notes.count, 3)
    }

    func testSingleExplicitBreakKeepsDefault() {
        let plan = PlanParser.parse("""
        1 выход - 5 секунд
        2 выход - 10 секунд
        Перерыв 5 минут
        3 выход - 5 секунд
        4 выход - 5 секунд
        """)
        XCTAssertEqual(plan.defaultBreak, TrainingPlan.defaultBreakDuration)
        XCTAssertEqual(plan.exits.map(\.breakAfter), [nil, 300, nil, nil])
    }

    func testBreakEqualToStatedDefaultFollowsDefault() {
        let plan = PlanParser.parse("""
        ➡️ Все перерывы 3 минуты
        1 выход - 5 секунд
        Перерыв 3 минуты
        2 выход - 10 секунд
        Перерыв 5 минут
        3 выход - 5 секунд
        """)
        XCTAssertEqual(plan.defaultBreak, 180)
        XCTAssertEqual(plan.exits.map(\.breakAfter), [nil, 300, nil])
    }

    func testAlternativeSpellings() {
        let plan = PlanParser.parse("""
        Тренировка
        Выход 1 — 1 мин 30 сек
        Выход №2: 2 минуты или до вставания
        """)
        XCTAssertEqual(plan.exits.count, 2)
        XCTAssertEqual(plan.exits[0].duration, 90)
        XCTAssertEqual(plan.exits[1].duration, 120)
        XCTAssertTrue(plan.exits[1].untilStanding)
    }

    func testDurationText() {
        XCTAssertEqual(DurationText.parse("15 с"), 15)
        XCTAssertEqual(DurationText.parse("2 минуты"), 120)
        XCTAssertEqual(DurationText.parse("1:30"), 90)
        XCTAssertEqual(DurationText.parse("90"), 90)
        XCTAssertEqual(DurationText.parse("1,5 минуты"), 90)
        XCTAssertNil(DurationText.parse("до вставания"))
        XCTAssertEqual(DurationText.short(90), "1 мин 30 с")
        XCTAssertEqual(DurationText.short(0), "0 с")
        XCTAssertEqual(DurationText.clock(-12), "−0:12")
        XCTAssertEqual(DurationText.clock(3725), "1:02:05")
    }
}
