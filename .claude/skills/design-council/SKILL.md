---
name: design-council
description: Run the Waiting Paws UI/UX design council. Three model delegates (Claude Opus, Claude Fable, GPT via codex) score the iPhone, Mac and Live Activity screens against Apple-class references; helper agents build what they agree on; rounds repeat until the owner's achievement criterion holds or the quota limit is reached. Use when the owner asks for a council («консилиум»), design review rounds, or to iterate the UI until independent experts agree. The argument is the achievement criterion; without one the default below applies.
argument-hint: "[критерий достижения; по умолчанию — 10/10 у всех трёх по критериям владельца, стоп на 40 % квоты]"
---

# Design council

**Criterion for this run:** $ARGUMENTS

If that line is empty, the run uses the **default criterion** below.

The council is a loop:
1. Capture the app's screens.
2. Put them beside reference apps.
3. Have three independent models score them against the owner's criterion.
4. Have helpers implement what the experts agree on.
5. Repeat until the criterion holds.

The first run took 18 rounds (2026-11-04…06). Its history is in
`~/projects/WaitingPaws-design-history/2026-11-council/`. Read its `round-12/` and `round-17/` briefs and summaries
before writing your own; they show the tone and level of detail that worked.

Details live in side files:
- [reference/pipeline.md](reference/pipeline.md): commands, prompts and gotchas for every step;
- [reference/product.md](reference/product.md): product, cases, shots and references;
- [brief-template.md](brief-template.md): the round brief.

## The criterion

The criterion is what must become true for the run to end. Read it as three parts:
1. **What the experts judge.** This becomes the brief's «Критерий владельца» and the scale.
2. **The goal.** Usually scores, e.g. every delegate 10/10 on every case plus «BETTER_THAN_REFERENCES: yes».
3. **The stop rule.** A quota limit or a round limit.

If the owner's text lacks a goal or a stop rule, take them from the default and say so in the first report.

Write the criterion verbatim into the run's `criterion.md` (`new-run.sh` does this) and quote it in every brief.

If the owner amends it mid-run (in round 17 the owner said the trainer's text had been hidden «слишком буквально»):
- add the amendment, dated, to `criterion.md`;
- add a «Поправка владельца к критериям (важно)» section to the next brief;
- let the experts lower the scores of cases the amendment touches.

<!-- default-criterion -->
**Критерий владельца (по умолчанию).** Каждый экран минимален, и его цель понятна с одного взгляда.
- UI вместо поясняющего текста: подписи-объяснения, фразы-выводы и подсказки — минус; текст только там, где без него
  явно хуже.
- Текст тренера — не «поясняющий текст», а данные владельца и проверка разбора. Он виден везде, где из него
  разбираются настройки (проверка плана и редактор выхода на iPhone, разбор, план и консоль на Mac). Связь «строка
  тренера ↔ настройка» видна в обе стороны: что понято, что осталось заметкой, что владелец поменял.
- Никаких нажатий на условия выхода («Встала и пошла», «Легла», «Залаяла») — они для чтения. Допустим разве что
  минимальный отдельный секундомер, не привязанный к типу условия и не поверх основного отсчёта.
- На iPhone таймлайн тренировки — чипы времени выходов с ⚡ (триггеры) и 🏃 (ранние выходы), как в main.
- Всё переусложнённое, где непонятно, что главное, — хуже: каждая лишняя строка, подпись, состояние или кнопка — минус.

**Цель:** все три эксперта ставят 10/10 в каждом кейсе и «BETTER_THAN_REFERENCES: yes».
**Стоп:** 40 % недельной квоты Claude; почти законченный раунд можно доделать до ~45 % («завершённое лучше
недоделанного»).
<!-- /default-criterion -->

## Standing rules (from the owner)

- **Nothing is committed, pushed or released unless the owner asks.** Helpers never commit or switch branches.
- **The run's history stays out of the repo.** `refs/` holds other apps' App Store screenshots, and one run is
  ~2 GB. Runs live in `~/projects/WaitingPaws-design-history/<YYYY-MM-DD>-<slug>/`.
- **Every round ends with a «## Council review» table:** `Rounds: N`, one row per delegate, one column per round.
  Write «no score» when a delegate gave none. **Never invent or round a score.**
- **Show before/after screenshots after every round,** with the scores and the comparison page link.
- **Less UI wins.** Rounds 1–11 came out «richer and wordier» and the owner rejected them. Prefer removing to adding.
  Don't build something the owner has already turned down (tap-to-start condition timers, rich cards) without
  asking.
- **Delegates are read-only and independent.** Start all three at once. None sees another's report from the same
  round.
- **Mac screenshots come only from real window captures on an unlocked screen** (`scripts/lockcheck.sh`). In-app
  `cacheDisplay` snapshots draw the glass toolbar buttons as blank white pills, and experts and the owner take that
  for a bug. If the screen is locked, reuse the previous round's Mac shots and say which ones in the brief.
- **Check the quota after every round** (`mcp__ccd_session_mgmt__get_usage`), and stop by the criterion's rule.

## Run layout

```
$COUNCIL = ~/projects/WaitingPaws-design-history/<date>-<slug>/
  criterion.md          the criterion, verbatim, plus dated amendments
  council.json          settings for the pages (goal line, base, delegates, cases, first tab round)
  refs/                 reference screenshots (cloned from the last run, or scripts/fetch-refs.py)
  index.html, LOG.md    every round's scores and before/after strips (scripts/report.py)
  progress/rN-*.jpg     before/after strips for the owner (scripts/progress.sh)
  final/                the comparison page (scripts/build.py): main/ = base build shots,
                        rounds.json = what each round changed, sections.py = current state against the base
  round-N/              brief.md, wp/ (shots), pair/ (same flags as final/main), sheets/ (c0…c7),
                        claude-opus-5.5.md, claude-fable-5.1.md, gpt-6-astra.md (+ .log), summary.md
```

The launch config «council» serves `~/projects/WaitingPaws-design-history` on :8771. The run's pages are then
`http://localhost:8771/<run>/` and `/<run>/final/`.

## Setup (once per run)

1. **Create the run:**
   `RUN=$(.claude/skills/design-council/scripts/new-run.sh <slug> "<criterion or empty for the default>")`, then
   `export COUNCIL=$RUN` for every script below (`SK=.claude/skills/design-council/scripts`).
2. **Fill `council.json`:** `goal` (one line), `base.note` (short sha and date of main), and `first_round`.
3. **Shoot the base build:** check out main in a temporary worktree with `Frameworks/` symlinked, build both apps,
   then run `$SK/capture-pair.sh final/main /tmp/wp-dd-main-S /tmp/wp-dd-main-M` (pipeline.md «The base build»).
4. **Check the references:** do they fit what the criterion judges? Fetch others if needed (product.md).
5. **Split the work among helpers** by files, A–D style (pipeline.md «Helpers»), and keep their agent ids so you
   can resume them with SendMessage.
6. **Round 1 is the baseline.** Change nothing; capture, compose sheets, write the brief, run the delegates, write
   the summary.

## One round (N)

1. **Plan.** Take round N-1's «## План раунда N»: items all three asked for first, then two of three. Give each
   helper its items (SendMessage to resume) and wait for all of them. Don't edit their files yourself meanwhile.
2. **Build and check.** Put the helpers' new Russian strings into `Tools/strings/en.json`.
   - Build iOS **and** macOS into `/tmp/wp-dd-S`, plus macOS into `/tmp/wp-dd-M`.
   - `build_catalog.py /tmp/wp-dd-S` must report 0 without English.
   - `swift test` must pass.
   - Fix what breaks, or send it back to its helper.
3. **Capture:**
   - `$SK/capture.sh round-N/wp ios`;
   - `$SK/capture-pair.sh round-N/pair /tmp/wp-dd-S /tmp/wp-dd-M ios`;
   - Mac (`capture.sh … mac` and the Mac pair) only if `$SK/lockcheck.sh` passes;
   - Live Activity sheets → `ios-11/12/13` (pipeline.md).
   - Look at the shots yourself before anyone scores them.
4. **Sheets:** `W=round-N/wp $SK/compose.sh round-N/sheets`, plus a `c0-*.jpg` for the round's theme
   (`progress.sh`), e.g. main | last round | now for the screens the round changed.
5. **Brief:** write `round-N/brief.md` from `brief-template.md`. It holds:
   - the criterion and any amendments;
   - the score history;
   - what changed, numbered and concrete, with shot names;
   - the materials, with honest notes about old or odd shots;
   - the scale and the exact report format.
6. **Delegates:** start all three in the background:
   - `$SK/run-codex.sh round-N`;
   - two Agent calls (`model: opus`, `model: fable`) with the delegate prompt from pipeline.md.

   Wait for the notifications; don't poll.
7. **Summary:** write `round-N/summary.md` with:
   - a per-case table of «prev → now» scores, with the overall and yes/no;
   - the consensus;
   - `## План раунда N+1`, each item saying who asked for it;
   - the Council review table.
8. **Page:**
   1. Add round N to `final/rounds.json` in the owner's words.
   2. Rewrite `final/sections.py` for the current state.
   3. Make 2–4 before/after strips with `progress.sh` → `progress/rN-*.jpg`.
   4. Run `python3 $SK/build.py && python3 $SK/report.py`, then open the page and check the new tab.
9. **Report to the owner:**
   - what changed, in plain words;
   - the scores and the consensus;
   - the before/after strips;
   - the page link;
   - the quota;
   - the «## Council review» table.
10. **Decide.** If the criterion holds, finish. If the stop rule is hit, finish and say what is left. Otherwise go
    to step 1 for round N+1.

## Finishing

- Write the last `summary.md`: the scores, `## Полировка (не мешает 10)`, and what was deferred (other platforms,
  re-shooting old Mac frames, code cleanup).
- Update `final/sections.py` «LEFT», rebuild both pages, and show the owner:
  - the final before/after;
  - the page;
  - the full Council review table;
  - what is uncommitted.
- Record the run in the project memory: dates, scores per round, the quota used, any amendments, the helpers'
  ownership, and new gotchas.
- Offer to commit, but don't commit without the owner's yes. Even then only the app code and this skill go into git;
  the run folder never does.

## Gotchas that cost rounds before

- **Catalog:** build both apps into the same derived data before `build_catalog.py`. A Mac-only or stale folder drops
  or revives keys.
- **Simulator text size:** the simulator can keep an AX text size between runs, so every shot comes out huge. The
  capture scripts reset it; if shots look giant, check this first.
- **Locked Mac:** the screen is often locked. Never fake Mac shots (see the standing rules). Tell the delegates which
  Mac frames are old.
- **`mac-03b-review-edit`** cannot be captured by `capture.sh`. A helper's real window capture is fine; an in-app
  snapshot is not.
- **Codex:** `codex exec` hits 429 at busy times. `run-codex.sh` retries 6 times, 3 minutes apart, and logs to
  `round-N/gpt-6-astra.log`. It needs `--skip-git-repo-check` and `</dev/null`, which the script passes.
- **Delegate drift:** a delegate can drift toward richer UI. Re-read the criterion: a high score for added features
  isn't the goal. If one delegate's demands contradict the owner's criterion, follow the owner and note it in the
  next brief.
- **Base flags:** keep `capture-pair.sh` to flags the base build knows, or the pairs show different states.
