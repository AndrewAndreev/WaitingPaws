# Waiting Paws for the council: product, cases, references

Briefs quote this. Keep it short in a brief and point the delegates to the run's earlier briefs for more.

## Product

**Waiting Paws** helps train a dog to stay home alone (separation anxiety). It runs on iPhone (iOS 26, supports
iOS 17) and Mac (macOS 26). Windows mirrors the Mac app and is not judged. Dark theme, pink accent, Russian and
English UI; screenshots are in Russian.

The trainer sends the schedule as text (Telegram/WhatsApp):

```
🐹 Тренировка на понедельник - Таня/Андрей - 05.10.2026
➡️ Все перерывы 2 минуты
1 выход - 15 секунд
2 выход - 30 секунд
3 выход - 1 минута + куртка
🟡 Если встала и пошла - входим через 30 секунд
🟢 Если легла - входим через 20 секунд
4 выход - 45 секунд + взять ключи
5 выход - 2 минуты ИЛИ до вставания
🚩 Если залаяла, завыла - ждём, входим когда молчала 30 секунд
```

1. The owner pastes the text, checks the parsed plan and starts.
2. Then come many short cycles: **выход** («Вышли», the owner stands behind the door watching the dog on the
   iPhone camera) → **«Вернулись»** → **перерыв** → **«Вышли»** → …
3. **«Фальстарт»** repeats an exit after a break.
4. At the end there is a video and a **log for the trainer**, written in the trainer's notation.

The key UX moment: the person stands behind the door and watches the dog, not the timer.

The Mac can hold the camera, the timeline and the recording while the iPhone in hand runs the same training.

Constraints:
- The camera (Xiaomi or RTSP) runs on the local network.
- iPhone video plays and records only while the app is open.
- No accounts or servers.

**The owner's taste.** UI at the level of Apple's own apps. Each round's owner verdicts so far:

| Rounds | What the owner said |
| --- | --- |
| R1–11 | They came out «richer and wordier» and the owner rejected them: «больше UI и больше кнопок» — no. |
| R12–16 | Minimal, purpose clear at a glance, the UI instead of explanatory text, no tapping on exit conditions, iPhone timeline = time chips with ⚡/🏃 as in main. |
| R17 | «текст тренера … помогает понять корректность парсинга — и это то, чем заполняет пользователь расписание». The trainer's words stay visible wherever settings are parsed from them. |

**Vocabulary:**
- **выход** — time behind the door.
- **перерыв** — the pause between exits.
- **фальстарт** — a failed exit that is repeated.
- **⚡ триггер** — what to do before an exit («+ куртка»).
- **🏃 ранний вход** — a condition for coming back early («легла → через 0:20»).
- **⛔ «ждать тишины»** — the trainer's rule against entering while the dog barks.
- **«ИЛИ до вставания»** — the exit ends when the dog stands up.
- **полоска чипов «15с – 30с – 1м – 45с – 2м»** — every exit of the training, with the current one lit.

The camera picture is a drawn placeholder in demo mode (`Tools/demo-camera.jpg`). The demo plans are `PLAN_RU` (the
Sunday plan, 8 exits) and `SESSION_RU` (the Monday session, 5 exits) in `scripts/capture.sh`.

## Cases and shots

`scripts/compose.sh` makes one sheet per case: Waiting Paws on top, references below.

`c0-*.jpg` is a custom sheet for the round's theme, made with `progress.sh`, for example main | before | now.

| Case | Sheet | Shots (`round-N/wp/`) |
| --- | --- | --- |
| 1. План | c1-plan | ios-01-home, ios-02-plan-review, 02b-plan-end, 02c-plan-source, 02e-exit-editor, 02f-plan-changed, mac-02-plan, mac-03-review |
| 2. «За дверью» | c2-away, c2b-away-mac | ios-03-away, 03k-away-stopwatch, 03l-away-overdue, 03f-away-zoomed, 03g-away-no-frame, 03h/03i (large text, AX), ios-06-trainer-text, mac-01-session |
| 3. Перерыв | c3-break | ios-05f-ready, 05-break, 05b-false-start-undo, 05c-break-false-start, 05h-last-break, 05d-break-ax, mac-04-break, mac-04b-break-false-start |
| 4. Взгляд мимоходом | c4-glance | ios-11-island, ios-12-lock, ios-13-notify (Live Activity sheets), ios-03-away |
| 5. Итог и лог | c5-summary | ios-10-finish, 07-log, 07b-log-bottom, 07d-log-video-gap, mac-06-finish-2, mac-05-history |
| 6. История | c6-history | ios-08-history, 08b-history-edit, 08c-history-recordings, mac-05-history |
| 7. Камера и главный экран | c7-camera | ios-01-home, ios-09-cameras, mac-01-session |

`scripts/capture-pair.sh` shoots the subset that the base build (main) can show:
- iOS: 01, 02, 03, 05, 06, 07, 08, 09, 10, 03h, 03i, 05d;
- Mac: 01–06.

## References and why

The owner rejected direct competitors (Separation Buddy, Calm My Dog, Lopaw, Be Right Back) as «slop / 2010s UI». The
council compares against big, modern apps with the same jobs, ideally Apple's own:

| App | Folder | Compare for |
| --- | --- | --- |
| Apple Fitness / Workout | `refs/apple-fitness`; `refs/apple-support/fitness-custom-workout.png`, `fitness-workout-types.png` | interval training from a plan, the Custom Workout builder |
| Apple Health | `refs/apple-health` | Sleep Score: a score with its breakdown, summaries, trends |
| Apple Home | `refs/apple-home` | cameras on the home screen, the event feed |
| Apple Sports | `refs/apple-sports` | the Live Activity as the main live status |
| Flighty (ADA 2023) | `refs/flighty` | plan against actual, states that change with the situation, Live Activity / Dynamic Island |
| Runna | `refs/runna` | a coach's plan run step by step: now / next, Live Activity |
| Crouton (ADA 2024) | `refs/crouton` | a recipe text turned into steps, time in the text becoming a timer, hands-free step mode |
| Gentler Streak (ADA 2024) | `refs/gentler-streak` | progress against yourself, a soft tone, monthly summaries |
| Final Cut Pro | `refs/final-cut-pro` | Mac timeline tracks |

App Store shots are marketing pictures: judge the interface inside, not the frames.

To fetch the references, run `scripts/fetch-refs.py`. Never commit them.
