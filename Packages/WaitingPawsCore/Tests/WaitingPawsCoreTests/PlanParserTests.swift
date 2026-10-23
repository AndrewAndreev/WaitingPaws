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

    /// The schedule of 06.10.2026: the false-start rule names a time («первые 20 секунд») and mentions «обычный
    /// перерыв», and every break of the training became 20 s instead of «Все перерывы 2 минуты».
    func testOtherTimesInNotesDoNotChangeTheBreak() {
        let plan = PlanParser.parse("""
        🐹 Тренировка на вторник - Таня - 06.10.2026

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
        7 выход - 3 минуты

        🟡 Если встала - входим через 15 секунд от вставания

        🔖 Фальстарт: если пошла к двери в первые 20 секунд длинного выхода или если при выходе вы услышали звуки, на которые она будет реагировать - сразу возвращаемся, через обычный перерыв снова идём на длинный выход. Если на третьей попытке выхода снова зафальстартила - завершаем тренировку
        """)
        XCTAssertEqual(plan.defaultBreak, 120)
        XCTAssertTrue(plan.exits.allSatisfy { $0.breakAfter == nil })
        XCTAssertEqual(plan.exits.map(\.duration), [5, 10, 5, 15, 30, 10, 180])
    }

    /// The triggering session of 19.10.2026: triggers after «+», an exit written as a sentence, the conditions once
    /// after all exits, two notes in one line.
    func testTriggeringSchedule() {
        let plan = PlanParser.parse("""
        🐹 ТРИГГЕРОВКА на понедельник - 19.10.2026
        Делаем через 1-1,5 часа и позже после основной тренировки, но не не поздно вечером➡️ За 30 минут включить музыку, открыть дверь изнутри, положить лежанку в коридор, положить/повесить куртку на виду у Мии
        ➡️ В перерывах сидите за столом, работаете
        ➡️ Все перерывы 2 минуты

        1 выход - 5 секунд
        2 выход - 10 секунд + куртка
        3 выход - 20 секунд + куртка
        4 выход - выйти, закрыть дверь на один оборот, подождать 10 секунд и вернуться
        5 выход - 5 секунд
        6 выход - выйти, закрыть дверь на один оборот, подождать 20 секунд и вернуться
        7 выход - 3 минуты + куртка + взять ключи, звякнуть ими

        🟡 Если встала и пошла - входим через 2 минуты от начала движения, когда сняла фокус внимания с двери: села (пусть даже у двери), исследует квартиру
        🟢 Если легла - входим через 30 секунд от укладки
        """)
        XCTAssertEqual(plan.title, "ТРИГГЕРОВКА на понедельник")
        XCTAssertEqual(plan.defaultBreak, 120)
        XCTAssertEqual(plan.exits.map(\.duration), [5, 10, 20, 10, 5, 20, 180])
        XCTAssertEqual(plan.exits.map(\.triggers), [[], ["куртка"], ["куртка"], ["закрыть дверь на один оборот"], [],
                                                     ["закрыть дверь на один оборот"], ["куртка", "взять ключи, звякнуть ими"]])
        XCTAssertEqual(plan.exits[3].note, "выйти, закрыть дверь на один оборот, подождать 10 секунд и вернуться")
        XCTAssertNil(plan.exits[0].note)
        XCTAssertEqual(plan.notes.count, 4)
        XCTAssertTrue(plan.notes[0].hasSuffix("поздно вечером"))
        XCTAssertTrue(plan.notes[1].hasPrefix("За 30 минут включить музыку"))

        XCTAssertEqual(plan.commonEarlyEntries.map(\.event), ["Встала и пошла", "Легла"])
        XCTAssertEqual(plan.commonEarlyEntries.map(\.delay), [120, 30])
        XCTAssertEqual(plan.commonEarlyEntries.map(\.tone), [.yellow, .green])
        XCTAssertEqual(plan.commonEarlyEntries[0].detail,
                       "от начала движения, когда сняла фокус внимания с двери: села (пусть даже у двери), исследует квартиру")
        XCTAssertEqual(plan.commonEarlyEntries[1].detail, "от укладки")
        XCTAssertTrue(plan.exits.allSatisfy { $0.earlyEntries.isEmpty })
        XCTAssertEqual(plan.commonEntriesScope, .all)
        XCTAssertEqual(plan.earlyEntries(of: plan.exits[6]).map(\.summary), ["встала и пошла → 2:00", "легла → 0:30"])
    }

    /// The training of 19.10.2026: conditions under exits 6 and 8 with their own times, rules for the whole training.
    func testConditionsUnderExits() {
        let plan = PlanParser.parse("""
        🐹 Тренировка на понедельник - 19.10.2026

        ➡️ Второго человека уводим из квартиры минимум за 30-40 минут до начала тренировки с обязательным сокрытием ухода. Вернуться можно минимум через 20-30 минут после окончания тренировки
        ➡️ За 30-60 минут включить музыку, отпереть дверь изнутри, закрыть окна
        ➡️ В перерывах сидите за столом, работаете
        ➡️ Все перерывы 2 минуты
        ➡️ Если лежит в лежанке, особо не шевелится, засыпает - перед выходом сначала шуршим на кухне/перемещаемся по квартире пока Мия не поднимет голову, затем сразу идём на выход
        1 выход - 5 секунд

        2 выход - 10 секунд + обувь

        3 выход - 20 секунд + обувь

        4 выход - 1 минута ИЛИ до вставания

        5 выход - 20 секунд + обувь

        6 выход - 4 минуты
        🟡 Если встала и пошла - входим через 1 минуту от начала движения, когда сняла фокус внимания с двери: села (пусть даже у двери), исследует квартиру
        🟢 Если легла - входим через 20 секунд от укладки

        7 выход - 20 секунд + обувь

        8 выход - 7 минут
        🟡 Если встала и пошла - входим через 2 минуты от начала движения, когда сняла фокус внимания с двери: села (пусть даже у двери), исследует квартиру
        🟢 Если легла - входим через 40 секунд от укладки


        🚩 Если залаяла, завыла - ни в коем случае не входить, ждём когда станет чуть спокойнее или отойдёт от двери и входим когда молчала 30 секунд. Если скребёт дверь - ждём отхода от двери и возвращаемся на хорошем отвлечении от двери

        🔖 Фальстарт: если пошла к двери в первые 20 секунд длинного выхода или если при выходе вы услышали звуки, на которые она будет реагировать - сразу возвращаемся, через обычный перерыв снова идём на длинный выход. Если на третьей попытке выхода снова зафальстартила - завершаем тренировку
        """)
        XCTAssertEqual(plan.exits.count, 8)
        XCTAssertEqual(plan.exits.map(\.duration), [5, 10, 20, 60, 20, 240, 20, 420])
        XCTAssertEqual(plan.exits.map(\.triggers.count), [0, 1, 1, 0, 1, 0, 1, 0])
        XCTAssertEqual(plan.exits[1].triggers, ["обувь"])
        XCTAssertTrue(plan.commonEarlyEntries.isEmpty)
        XCTAssertEqual(plan.exits[5].earlyEntries.map(\.summary), ["встала и пошла → 1:00", "легла → 0:20"])
        XCTAssertEqual(plan.exits[7].earlyEntries.map(\.summary), ["встала и пошла → 2:00", "легла → 0:40"])
        XCTAssertEqual(plan.earlyEntries(of: plan.exits[3]).map(\.summary), ["встала → сразу"])
        XCTAssertEqual(plan.earlyEntries(of: plan.exits[6]), [])
        XCTAssertEqual(plan.notes.count, 7)
        XCTAssertEqual(plan.doNotEnterRule?.title, "Залаяла, завыла")
        XCTAssertTrue(plan.doNotEnterRule?.detail.hasPrefix("ни в коем случае не входить") == true)

        let lines = PlanParser.sourceLines(plan.rawText)
        XCTAssertEqual(lines.first?.kind, .header)
        let exit8 = lines.filter { $0.exitNumber == 8 }
        XCTAssertEqual(exit8.map(\.kind), [.exit, .earlyEntry, .earlyEntry])
        XCTAssertTrue(exit8[1].text.hasPrefix("🟡"))
        XCTAssertEqual(lines.filter { $0.kind == .doNotEnter }.count, 1)
        XCTAssertEqual(lines.filter { $0.kind == .falseStart }.count, 1)
    }

    /// A schedule pasted on Windows (or typed there and synced): \r\n is one line break, so a condition right under
    /// an exit still belongs to it.
    func testWindowsLineEnds() {
        let plan = PlanParser.parse("1 выход - 5 секунд\r\n2 выход - 4 минуты\r\n🟢 Если легла - входим через 20 секунд\r\n")
        XCTAssertEqual(plan.exits.count, 2)
        XCTAssertEqual(plan.exits[1].earlyEntries.map(\.summary), ["легла → 0:20"])
        XCTAssertTrue(plan.commonEarlyEntries.isEmpty)
        XCTAssertEqual(PlanParser.sourceLines(plan.rawText).map(\.exitNumber), [1, 2, 2])
    }

    /// The training of 23.10.2026: «- далее после перерыва делаем выход на 15 секунд» made every break 15 s; the
    /// conditions nested under exit 6 («🟡 Если встала за это время: …») landed among the training's rules.
    func testBreakTimeOfAnExitAndNotesUnderAnExit() {
        let plan = PlanParser.parse("""
        🐹 Тренировка на пятницу - Андрей - 23.10.2026

        ➡️ Гостей уводим из квартиры минимум за 1 час, без скрытия ухода➡️ Второго человека уводим из квартиры минимум за 30-40 минут до начала тренировки с обязательным сокрытием ухода. Вернуться можно минимум через 20-30 минут после окончания тренировки
        ➡️ За 30-60 минут включить музыку, отпереть дверь изнутри, закрыть окна
        ➡️ В перерывах сидите за столом, работаете
        ➡️ Все перерывы 2 минуты
        ➡️ Если лежит в лежанке, особо не шевелится, засыпает - перед выходом сначала шуршим на кухне/перемещаемся по квартире пока Мия не поднимет голову, затем сразу идём на выход
        1 выход - 5 секунд

        2 выход - 10 секунд

        3 выход - 20 секунд

        4 выход - 2 минуты ИЛИ до вставания

        5 выход - 10 секунд

        6 выход - 8 минут
        🟡 Если встала и пошла - входим через 4 минуты от начала движения, когда сняла фокус внимания с двери: села (пусть даже у двери), исследует квартиру
        🟢 Если легла - входим через 2 минуты от укладки
        🟡 Если встала за это время:
             ➡️ если бродит - вход через 2 минуты
             ➡️ если легла - вход через 30 секунд

        Если при возвращении с 6 выхода понимаешь, что она проспала его, то:
        - далее после перерыва делаем выход на 15 секунд
        - и далее после перерыва повторяем 6 выход
        🚩 Если залаяла, завыла - ни в коем случае не входить, ждём когда станет чуть спокойнее или отойдёт от двери и входим когда молчала 30 секунд. Если скребёт дверь - ждём отхода от двери и возвращаемся на хорошем отвлечении от двери

        🔖 Фальстарт: если пошла к двери в первые 20 секунд длинного выхода или если при выходе вы услышали звуки, на которые она будет реагировать - сразу возвращаемся, через обычный перерыв снова идём на длинный выход. Если на третьей попытке выхода снова зафальстартила - завершаем тренировку
        """)
        XCTAssertEqual(plan.defaultBreak, 120)
        XCTAssertTrue(plan.exits.allSatisfy { $0.breakAfter == nil })
        XCTAssertEqual(plan.exits.map(\.duration), [5, 10, 20, 120, 10, 480])
        XCTAssertEqual(plan.exits[5].earlyEntries.map(\.summary), ["встала и пошла → 4:00", "легла → 2:00"])
        XCTAssertEqual(plan.exits[5].note, "Если встала за это время:\nесли бродит - вход через 2 минуты\nесли легла - вход через 30 секунд")
        XCTAssertEqual(plan.notes.count, 11)
        XCTAssertTrue(plan.notes.contains("далее после перерыва делаем выход на 15 секунд"))
        XCTAssertEqual(plan.doNotEnterRule?.title, "Залаяла, завыла")
        XCTAssertTrue(plan.notes.last?.hasPrefix("Фальстарт") == true)
        let exit6 = PlanParser.sourceLines(plan.rawText).filter { $0.exitNumber == 6 }
        XCTAssertEqual(exit6.map(\.kind), [.exit, .earlyEntry, .earlyEntry, .note, .note, .note])
    }

    func testTimesThatAreNotTheBreak() {
        XCTAssertNil(PlanParser.commonBreak(in: "далее после перерыва делаем выход на 15 секунд"))
        XCTAssertNil(PlanParser.commonBreak(in: "Перерыв, затем выход 30 секунд"))
        XCTAssertNil(PlanParser.commonBreak(in: "After the break do an exit of 15 seconds"))
        XCTAssertEqual(PlanParser.commonBreak(in: "Перерывы между выходами — 2 минуты"), 120)
        // The first line that names the common break wins.
        let plan = PlanParser.parse("""
        ➡️ Все перерывы 2 минуты
        1 выход - 5 секунд

        Перерывы можно увеличить до 3 минут
        """)
        XCTAssertEqual(plan.defaultBreak, 120)
    }

    func testEarlyEntryLines() {
        let english = PlanParser.parseEarlyEntry("If she lies down - come back in 30 seconds")
        XCTAssertEqual(english?.event, "She lies down")
        XCTAssertEqual(english?.delay, 30)
        let rightAway = PlanParser.parseEarlyEntry("Если встала, сразу входим")
        XCTAssertEqual(rightAway?.event, "Встала")
        XCTAssertNil(rightAway?.delay)
        XCTAssertNil(PlanParser.parseEarlyEntry("🚩 Если залаяла - ни в коем случае не входить, входим когда молчала 30 секунд"))
        XCTAssertNil(PlanParser.parseEarlyEntry("Если лежит в лежанке - перед выходом сначала шуршим на кухне"))
        XCTAssertNil(PlanParser.parseEarlyEntry("Вернуться можно минимум через 20-30 минут после окончания тренировки"))
    }

    func testCommonBreakLines() {
        XCTAssertEqual(PlanParser.commonBreak(in: "Все перерывы 2 минуты"), 120)
        XCTAssertEqual(PlanParser.commonBreak(in: "Перерывы между выходами — 1 мин. 30 сек."), 90)
        XCTAssertEqual(PlanParser.commonBreak(in: "Все перерывы по 1,5 минуты"), 90)
        XCTAssertEqual(PlanParser.commonBreak(in: "Все перерывы 2 минуты, после пятого выхода 5 минут"), 120)
        XCTAssertEqual(PlanParser.commonBreak(in: "Between exits: 2 minute breaks"), 120)
        XCTAssertEqual(PlanParser.commonBreak(in: "All breaks are 3 minutes"), 180)
        // A time in the same sentence that is not the break's.
        XCTAssertNil(PlanParser.commonBreak(in: "Если лает дольше 10 секунд, в перерыве не подходим"))
        XCTAssertNil(PlanParser.commonBreak(in: "Через обычный перерыв снова идём на длинный выход, он длится 30 секунд"))
        XCTAssertNil(PlanParser.commonBreak(in: "Фальстарт: возвращаемся, перерыв 5 минут и снова на длинный выход"))
        XCTAssertNil(PlanParser.commonBreak(in: "В перерывах сидите за столом, работаете"))
        XCTAssertNil(PlanParser.commonBreak(in: "Breakfast 30 minutes before the training"))
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
