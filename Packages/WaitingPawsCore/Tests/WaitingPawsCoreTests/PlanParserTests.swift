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
        XCTAssertEqual(plan.exits.map(\.endsWhenStanding), [false, false, false, false, true, false, true])
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
        XCTAssertTrue(plan.exits[8].endsWhenStanding)
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
        // By default the common conditions go to the exits of a minute and longer: here only the 3-minute one.
        XCTAssertEqual(plan.commonEntriesScope, .long)
        XCTAssertEqual(plan.exits.map(plan.usesCommonEarlyEntries), [false, false, false, false, false, false, true])
        XCTAssertEqual(plan.earlyEntries(of: plan.exits[6]).map(\.summary), ["встала и пошла → 2:00", "легла → 0:30"])
        XCTAssertEqual(plan.earlyEntries(of: plan.exits[0]), [])
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

    /// The screenshot of 04.11: «ключ ИЛИ до вставания» was one trigger. «ИЛИ до вставания» is the exit's condition.
    func testUntilStandingAfterTriggers() throws {
        let plan = PlanParser.parse("""
        3 выход - 15 секунд + куртка + ключ
        4 выход - 45 секунд + куртка + ключ ИЛИ до вставания
        5 выход - 15 секунд + ключ или телефон
        6 выход - 20 секунд + ключ или телефон ИЛИ пока не встанет

        🟡 Если встала и пошла - входим через 3 минуты от начала движения
        🟢 Если легла - входим через 1 минуту от укладки
        """)
        XCTAssertEqual(plan.exits.map(\.duration), [15, 45, 15, 20])
        XCTAssertEqual(plan.exits.map(\.triggers), [["куртка", "ключ"], ["куртка", "ключ"], ["ключ или телефон"],
                                                     ["ключ или телефон"]])
        XCTAssertEqual(plan.exits.map(\.endsWhenStanding), [false, true, false, true])
        // A 45-second exit gets no common conditions, only its own word.
        XCTAssertEqual(plan.earlyEntries(of: plan.exits[1]).map(\.summary), ["встала → сразу"])
        XCTAssertEqual(plan.exits[1].durationDescription, "45 с или до вставания")

        let english = try XCTUnwrap(PlanParser.parseExit("Exit 4 - 45 seconds + jacket + keys OR until the dog stands up"))
        XCTAssertEqual(english.triggers, ["jacket", "keys"])
        XCTAssertTrue(english.untilStanding)
        XCTAssertEqual(PlanParser.parseExit("4 выход - 45 секунд + ИЛИ до вставания")?.triggers, [])

        // A plan an older build saved with the trigger «ключ ИЛИ до вставания» comes back right.
        var saved = TrainingPlan(exits: [PlannedExit(number: 4, duration: 45)])
        saved.exits[0].triggers = ["куртка", "ключ ИЛИ до вставания"]
        let decoded = try JSONDecoder().decode(TrainingPlan.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.exits[0].triggers, ["куртка", "ключ"])
        XCTAssertTrue(decoded.exits[0].endsWhenStanding)
    }

    /// «К длинным» (the default) and «ко всем» survive an added exit and a new time; «Выбрать» and the switches flipped
    /// by hand stay as they are.
    func testCommonScopeSurvivesEdits() {
        let plan = PlanParser.parse("""
        1 выход - 15 секунд
        2 выход - 2 минуты
        3 выход - 45 секунд

        🟢 Если легла - входим через 30 секунд от укладки
        """)
        XCTAssertEqual(plan.commonEntriesScope, .long)

        // A short exit added, the 45-second one stretched to 2 minutes.
        var edited = plan
        edited.exits.append(PlannedExit(number: 4, duration: 10))
        edited.exits[2].duration = 120
        edited = edited.keepingCommonEntriesScope(from: plan)
        XCTAssertEqual(edited.commonEntriesScope, .long)
        XCTAssertEqual(edited.exits.map(\.usesCommonEarlyEntries), [false, true, true, false])

        // A switch flipped by hand makes it «Выбрать», and a later new time doesn't undo it.
        var picked = edited
        picked.exits[0].usesCommonEarlyEntries = true
        picked = picked.keepingCommonEntriesScope(from: edited)
        XCTAssertNil(picked.commonEntriesScope)
        var retimed = picked
        retimed.exits[3].duration = 90
        retimed = retimed.keepingCommonEntriesScope(from: picked)
        XCTAssertEqual(retimed.exits.map(\.usesCommonEarlyEntries), [true, true, true, false])

        // «Ко всем»: an added short exit gets them too.
        var all = plan
        all.applyCommonEarlyEntries(to: .all)
        XCTAssertEqual(all.commonEntriesScope, .all)
        var added = all
        added.exits.append(PlannedExit(number: 4, duration: 10, usesCommonEarlyEntries: false))
        added = added.keepingCommonEntriesScope(from: all)
        XCTAssertEqual(added.commonEntriesScope, .all)

        // Only long exits: both fit and the switch says «к длинным», so a short exit added later doesn't get them.
        let long = PlanParser.parse("1 выход - 2 минуты\n2 выход - 3 минуты\n\n🟢 Если легла - входим через 30 секунд")
        XCTAssertEqual(long.commonEntriesScope, .long)
        var longAdded = long
        longAdded.exits.append(PlannedExit(number: 3, duration: 20))
        XCTAssertFalse(longAdded.keepingCommonEntriesScope(from: long).exits[2].usesCommonEarlyEntries)

        // «Ещё выход» has no planned time and counts as long.
        var open = plan
        open.exits.append(.init(number: 4, duration: 0, isOpen: true))
        XCTAssertEqual(open.commonEntriesScope, .long)
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
        XCTAssertTrue(plan.exits[1].endsWhenStanding)
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

    /// "inf" typed into a duration field crashed the app: `Int(.infinity)` traps.
    func testDurationTextTakesOnlyRealTimes() {
        for text in ["inf", "nan", "1e400", "0x1p4", "99999999999999999:00", "100 часов"] {
            XCTAssertNil(DurationText.parse(text), text)
        }
        XCTAssertEqual(DurationText.parse("1e2"), 100)
        XCTAssertEqual(DurationText.parse("-5"), -5)
        XCTAssertEqual(DurationText.short(.infinity), DurationText.short(TimeInterval(Int32.max)))
        XCTAssertEqual(DurationText.short(.nan), "0 с")
        XCTAssertEqual(DurationText.compact(1e300), DurationText.compact(TimeInterval(Int32.max)))
        XCTAssertEqual(DurationText.clock(-.infinity), "−596523:14:07")
    }

    /// «🚩 … не заходите» became the condition «Залаяла, завыла → сразу»: the app said the opposite of the trainer.
    func testDoNotEnterRules() {
        let plan = PlanParser.parse("""
        6 выход - 4 минуты
        🚩 Если залаяла, завыла - ни в коем случае не заходите, ждите тишины
        """)
        XCTAssertTrue(plan.exits[0].earlyEntries.isEmpty)
        XCTAssertTrue(plan.commonEarlyEntries.isEmpty)
        XCTAssertEqual(plan.notes, ["🚩 Если залаяла, завыла - ни в коем случае не заходите, ждите тишины"])
        XCTAssertEqual(plan.doNotEnterRule?.title, "Залаяла, завыла")
        XCTAssertEqual(plan.doNotEnterRule?.detail, "ни в коем случае не заходите, ждите тишины")
        XCTAssertEqual(PlanParser.sourceLines(plan.rawText).map(\.kind), [.exit, .doNotEnter])

        // The flag alone says it, and it beats a note that only mentions not coming in.
        let flagged = PlanParser.parse("1 выход - 5 секунд\n\nНе заходить в комнату без нужды\n🚩 Если залаяла - ждём тишины")
        XCTAssertEqual(flagged.doNotEnterRule?.title, "Залаяла")

        for line in ["Если залаяла - не входите", "Если лает - нельзя возвращаться, входим когда замолчит",
                     "If she barks, do not return", "If she barks - don’t come in, wait for silence",
                     "If she barks, never enter"] {
            XCTAssertNil(PlanParser.parseEarlyEntry(line), line)
            XCTAssertTrue(PlanParser.isDoNotEnterRule(line), line)
        }
        XCTAssertFalse(PlanParser.isDoNotEnterRule("Если лает — ждём вне входа"))
        XCTAssertFalse(PlanParser.isDoNotEnterRule("Если лает — дальше не выходим"))
        // A plan saved before the flag was kept: its words still say it.
        XCTAssertNotNil(TrainingPlan(notes: ["Если залаяла, завыла - ни в коем случае не заходите"]).doNotEnterRule)
    }

    /// «через минуту», «через 0,5 минуты» were read as no time, and no time is «сразу».
    func testDelaysInWordsAndWithDecimalCommas() {
        func delay(_ line: String) -> TimeInterval? { PlanParser.parseEarlyEntry(line)?.delay }
        XCTAssertEqual(delay("🟡 Если встала - входим через минуту"), 60)
        XCTAssertEqual(delay("Если встала - входим через 0,5 минуты"), 30)
        XCTAssertEqual(delay("Если встала - входим через 1,5 минуты, когда отойдёт"), 90)
        XCTAssertEqual(delay("Если встала - входим через полминуты"), 30)
        XCTAssertEqual(delay("Если встала - входим через пол минуты"), 30)
        XCTAssertEqual(delay("Если встала - входим через полторы минуты"), 90)
        XCTAssertEqual(delay("Если легла - входим через десять секунд"), 10)
        XCTAssertEqual(delay("If she stands up - come back in a minute"), 60)
        XCTAssertEqual(delay("If she stands up - come back in half a minute"), 30)
        XCTAssertEqual(delay("If she lies down - come back after ten seconds"), 10)
        let words = PlanParser.parseEarlyEntry("Если встала - входим через две минуты от начала движения, когда сняла фокус")
        XCTAssertEqual(words?.delay, 120)
        XCTAssertEqual(words?.detail, "от начала движения, когда сняла фокус")
        XCTAssertNil(words?.unreadDelay)

        // Words it can't read stay in sight instead of «сразу».
        let vague = PlanParser.parseEarlyEntry("🟡 Если встала - входим через пару минут от начала движения, когда отойдёт")
        XCTAssertNil(vague?.delay)
        XCTAssertEqual(vague?.detail, "через пару минут от начала движения, когда отойдёт")
        XCTAssertEqual(vague?.unreadDelay, "через пару минут")
        XCTAssertEqual(vague?.summary, "встала → через пару минут")
        XCTAssertEqual(vague?.delayDescription, "через пару минут")
        XCTAssertEqual(PlanParser.parseEarlyEntry("If she lies down - come back in a couple of minutes")?.unreadDelay,
                       "in a couple of minutes")
        // «сразу» is still «сразу», and an "in" that names a place is no time.
        XCTAssertEqual(PlanParser.parseEarlyEntry("Если встала - входим сразу")?.summary, "встала → сразу")
        XCTAssertNil(PlanParser.parseEarlyEntry("If she lies down - come back in the hallway")?.unreadDelay)
    }

    /// 2/3/2/3-minute breaks: the plan's break was whichever a Dictionary gave first, different from launch to launch
    /// and from Windows. The first one written wins.
    func testTiedBreaks() {
        let plan = PlanParser.parse("""
        1 выход - 5 секунд
        Перерыв 3 минуты
        2 выход - 5 секунд
        Перерыв 2 минуты
        3 выход - 5 секунд
        Перерыв 3 минуты
        4 выход - 5 секунд
        Перерыв 2 минуты
        """)
        XCTAssertEqual(plan.defaultBreak, 180)
        XCTAssertEqual(plan.exits.map(\.breakAfter), [nil, 120, nil, 120])
    }

    /// «🟡︎», «🔖︎», «🚩︎» (with a variation selector) are the trainer's marks all the same, as on Windows.
    func testMarksWithVariationSelectors() {
        XCTAssertEqual(PlanParser.parseEarlyEntry("🟡\u{FE0F} Если встала - входим через 15 секунд")?.tone, .yellow)
        XCTAssertEqual(PlanParser.parseEarlyEntry("🟢\u{FE0E} Если легла - входим через 15 секунд")?.tone, .green)
        let text = """
        6 выход - 4 минуты
        🟡 Если встала - входим через 1 минуту
        🔖\u{FE0E} На третьей попытке завершаем тренировку
        🚩\u{FE0F} Если залаяла - ждём тишины
        """
        let plan = PlanParser.parse(text)
        XCTAssertNil(plan.exits[0].note)
        XCTAssertEqual(plan.notes, ["На третьей попытке завершаем тренировку", "🚩 Если залаяла - ждём тишины"])
        XCTAssertEqual(plan.doNotEnterRule?.title, "Залаяла")
        XCTAssertEqual(PlanParser.sourceLines(text).map(\.kind), [.exit, .earlyEntry, .falseStart, .doNotEnter])
    }

    /// A lone «➡️» row at the top was taken for the header of the trainer's text, and the header for a note.
    func testDecorationOnlyLines() {
        let text = "➡️\n🐹 Тренировка на понедельник - 19.10.2026\n1 выход - 5 секунд\n➡️\n🟢 Если легла - входим через 20 секунд"
        let plan = PlanParser.parse(text)
        XCTAssertEqual(plan.title, "Тренировка на понедельник")
        XCTAssertEqual(plan.exits[0].earlyEntries.count, 1)
        let lines = PlanParser.sourceLines(text)
        XCTAssertEqual(lines.map(\.kind), [.note, .header, .exit, .note, .earlyEntry])
        XCTAssertEqual(lines.map(\.exitNumber), [nil, nil, 1, 1, 1])
    }

    /// The plan shows each exit with the trainer's lines it was read from: an exit keeps them by its place in the text
    /// (`sourceIndex` ↔ `exitIndex`) through a reorder and a renumbering, a hand-added exit has none, and an own break
    /// after a blank line is its exit's line, as `parse` reads it.
    func testExitsKeepTheirLines() {
        let text = """
        🐹 Тренировка - 04.10.2026
        ➡️ Все перерывы 2 минуты
        3 выход - 10 секунд
        3 выход - 2 минуты
        🟢 Если легла - входим через 20 секунд

        Перерыв 5 минут
        🚩 Если залаяла - ждём, входим когда молчала 30 секунд
        """
        var plan = PlanParser.parse(text)
        XCTAssertEqual(plan.exits.map(\.sourceIndex), [0, 1])
        XCTAssertEqual(plan.exits[1].breakAfter, 300)
        let lines = PlanParser.sourceLines(text)
        XCTAssertEqual(lines.map(\.kind), [.header, .note, .exit, .exit, .earlyEntry, .blank, .breakTime, .doNotEnter])
        XCTAssertEqual(lines.map(\.exitIndex), [nil, nil, 0, 1, 1, nil, 1, nil])
        XCTAssertEqual(lines.map(\.exitNumber), [nil, nil, 3, 3, 3, nil, 3, nil])

        plan.exits.swapAt(0, 1)
        plan.exits.append(PlannedExit(number: 0, duration: 30))
        plan.renumber()
        XCTAssertEqual(plan.exits.map(\.sourceIndex), [1, 0, nil])
        let decoded = try? JSONDecoder().decode(TrainingPlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded?.exits.map(\.sourceIndex), [1, 0, nil])
        // A plan saved before the field decodes without it.
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","number":1,"duration":10,"untilStanding":false}"#
        XCTAssertNil(try JSONDecoder().decode(PlannedExit.self, from: Data(old.utf8)).sourceIndex)
    }

    /// «…входим через 30 секунд, не заходя в комнату» was taken for a rule against coming in: the condition was lost
    /// and the line became the plan's «Не входить».
    func testHowToComeInIsNoRuleAgainstIt() {
        let plan = PlanParser.parse("""
        3 выход - 2 минуты
        🟢 Если легла - входим через 30 секунд, не заходя в комнату
        """)
        XCTAssertEqual(plan.exits[0].earlyEntries.first?.delay, 30)
        XCTAssertEqual(plan.exits[0].earlyEntries.first?.detail, "не заходя в комнату")
        XCTAssertNil(plan.doNotEnterRule)
        XCTAssertEqual(PlanParser.sourceLines(plan.rawText).map(\.kind), [.exit, .earlyEntry])

        let quietly = PlanParser.parseEarlyEntry("Если встала - возвращаемся через минуту, не входя резко")
        XCTAssertEqual(quietly?.delay, 60)
        XCTAssertEqual(quietly?.detail, "не входя резко")
        XCTAssertEqual(PlanParser.parseEarlyEntry("Если встала - входим через минуту, не возвращаясь к двери")?.delay, 60)
        let bedroom = PlanParser.parseEarlyEntry("If she lies down - come back in 30 seconds, don’t enter the bedroom")
        XCTAssertEqual(bedroom?.delay, 30)
        XCTAssertEqual(bedroom?.detail, "don’t enter the bedroom")

        for line in ["Если залаяла - не входить", "Если залаяла - не заходи", "Если залаяла - не входим",
                     "Если залаяла - не возвращайтесь", "Если лает - не возвращайся, жди", "Если лает - нельзя заходить",
                     "If she barks, don't enter", "If she barks, do not enter the flat",
                     "If she barks - never enter until she is quiet"] {
            XCTAssertTrue(PlanParser.isDoNotEnterRule(line), line)
            XCTAssertNil(PlanParser.parseEarlyEntry(line), line)
        }
        XCTAssertFalse(PlanParser.isDoNotEnterRule("Если лает — в план не входит"))
    }

    /// «1 выход - 99999999999999999999 секунд» pasted into a plan crashed the Mac: the plan's length went to `Int(_:)`.
    func testHugeTimesAreNoTime() {
        XCTAssertNil(DurationText.sumOfUnits(in: "99999999999999999999 секунд"))
        XCTAssertNil(DurationText.sumOfUnits(in: String(repeating: "9", count: 400) + " секунд"))
        XCTAssertNil(DurationText.sumOfUnits(in: "25 часов"))
        XCTAssertEqual(DurationText.sumOfUnits(in: "24 часа"), 86400)

        let plan = PlanParser.parse("""
        1 выход - 99999999999999999999 секунд
        Перерыв 99999999999999999999 минут
        2 выход - 5 секунд
        🟡 Если встала - входим через секунд 99999999999999999999
        """)
        XCTAssertEqual(plan.exits.map(\.duration), [0, 5])
        XCTAssertEqual(plan.exits.map(\.breakAfter), [nil, nil])
        XCTAssertEqual(plan.notes, ["Перерыв 99999999999999999999 минут"])
        XCTAssertNil(plan.exits[1].earlyEntries.first?.delay)

        XCTAssertEqual(DurationText.wholeSeconds(.infinity), Int(Int32.max))
        XCTAssertEqual(DurationText.wholeSeconds(-.infinity), -Int(Int32.max))
        XCTAssertEqual(DurationText.wholeSeconds(.nan), 0)
        XCTAssertEqual(DurationText.wholeSeconds(89.5), 90)
    }

    /// «через секунд 30» was read as one second with «30» left over: «через 0:01 · 30».
    func testNumberAfterItsUnit() {
        func entry(_ line: String) -> EarlyEntry? { PlanParser.parseEarlyEntry(line) }
        XCTAssertEqual(entry("Если встала - входим через секунд 30")?.delay, 30)
        XCTAssertNil(entry("Если встала - входим через секунд 30")?.detail)
        XCTAssertEqual(entry("Если встала - входим через минут 5, когда отойдёт")?.delay, 300)
        XCTAssertEqual(entry("Если встала - входим через минут 5, когда отойдёт")?.detail, "когда отойдёт")
        XCTAssertEqual(entry("Если легла - входим через секунд тридцать от укладки")?.delay, 30)
        XCTAssertEqual(entry("Если легла - входим через секунд тридцать от укладки")?.detail, "от укладки")
        XCTAssertEqual(entry("Если встала - входим через минуты две")?.delay, 120)
        // A word that is no number, or a time of its own, is not the count.
        XCTAssertEqual(entry("Если встала - входим через минуту после укладки")?.delay, 60)
        XCTAssertEqual(entry("Если встала - входим через минуту после укладки")?.detail, "после укладки")
        XCTAssertNotEqual(entry("Если встала - входим через минуту 30 секунд")?.delay, 1800)
    }

    /// "come back in several minutes" said "right away": only "in a …" and a single digit were taken for a time.
    func testEnglishDelaysItCannotRead() {
        func words(_ line: String) -> String? { PlanParser.parseEarlyEntry(line)?.unreadDelay }
        XCTAssertEqual(words("If she stands up - come back in several minutes"), "in several minutes")
        XCTAssertEqual(words("If she stands up - come back in a few minutes"), "in a few minutes")
        XCTAssertEqual(words("If she stands up - come back in few minutes"), "in few minutes")
        XCTAssertEqual(words("If she lies down - come back in 15 breaths"), "in 15 breaths")
        XCTAssertEqual(words("If she lies down - come back in some time"), "in some time")
        XCTAssertEqual(words("If she stands up - come back in a couple of minutes after she lies down"),
                       "in a couple of minutes")
        XCTAssertEqual(words("If she stands up - come back after she settles"), "after she settles")
        XCTAssertNil(words("If she lies down - come back in the kitchen"))
        XCTAssertEqual(PlanParser.parseEarlyEntry("If she stands up - come back in several minutes")?.delayDescription,
                       "in several minutes")
    }

    /// «через пару минут» on the right and «через пару минут от начала движения, когда отойдёт» under the event: the
    /// trainer's words twice.
    func testDetailBesideAnUnreadDelay() {
        let vague = PlanParser.parseEarlyEntry("🟡 Если встала - входим через пару минут от начала движения, когда отойдёт")
        XCTAssertEqual(vague?.detail, "через пару минут от начала движения, когда отойдёт")
        XCTAssertEqual(vague?.detailBesideTime, "от начала движения, когда отойдёт")
        XCTAssertEqual(PlanParser.parseEarlyEntry("Если встала - входим через пару минут, когда отойдёт")?.detailBesideTime,
                       "когда отойдёт")
        XCTAssertNil(PlanParser.parseEarlyEntry("Если встала - входим через пару минут")?.detailBesideTime)
        XCTAssertEqual(PlanParser.parseEarlyEntry("If she stands up - come back in a few minutes after she lies down")?
            .detailBesideTime, "after she lies down")
        // A time it has read, or none: the detail as it is.
        XCTAssertEqual(PlanParser.parseEarlyEntry("Если встала - входим через 2 минуты от начала движения")?.detailBesideTime,
                       "от начала движения")
        XCTAssertEqual(PlanParser.parseEarlyEntry("Если встала - входим сразу, тихо")?.detailBesideTime, "тихо")
    }
}
