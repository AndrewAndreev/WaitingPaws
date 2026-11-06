# Council pipeline: commands, prompts, gotchas

All paths here are relative to the repository root. `SK=.claude/skills/design-council/scripts`. `$COUNCIL` is the
run folder from `new-run.sh`, which is never inside the repo. Every script is zsh; relative paths given to them
resolve inside `$COUNCIL`.

## Scripts

| Script | What it does |
| --- | --- |
| `new-run.sh <slug> [criterion]` | Makes the run folder: `criterion.md`, `council.json`, cloned `refs/`, `final/rounds.json` and `final/sections.py` templates, `round-1/`. |
| `capture.sh <out> [ios\|mac\|all]` | Takes every current shot, iPhone (sim «WP Screens», `$DD`) and Mac (`$MAC_DD`, unlocked screen only). It takes about 8 min for iOS and 3 min for Mac. |
| `capture-pair.sh <out> <iOS dd> <Mac dd> [what]` | Shoots the same flags on two builds: the base into `final/main`, now into `round-N/pair`. |
| `compose.sh <out>` with `W=round-N/wp` | Makes one sheet per case (`c1…c7`), Waiting Paws over the references. |
| `progress.sh <out.jpg> <title> (<label> <img>)…` | Makes before/after strips for the owner (`progress/rN-*.jpg`) and custom `c0-*.jpg` sheets. |
| `run-codex.sh round-N` | The GPT delegate: `codex exec -m ${CODEX_MODEL:-gpt-6-astra} -s read-only`, retried on 429 every 3 min, at most 6 times. |
| `report.py` | Rebuilds `LOG.md` and `index.html`: scores of every round, progress strips, the latest sheets. |
| `build.py` | Rebuilds `final/index.html`, the tabbed comparison page («base → сейчас», «Раунд N»). |
| `fetch-refs.py [slug=appId…]` | Saves App Store screenshots into `refs/`. |
| `lockcheck.sh` | Exits 1 while the screen is locked. |
| `live-activity/*.sh` | Live Activity and notification shots and their three sheets (see below). |

**`council.json`** sets these fields (defaults in `council_config.py`):
- `title`, `page_title`;
- `goal`: one line of the criterion;
- `lead`, `delegates` (report file and display name), `cases`;
- `first_round`: the first round with its own tab;
- `base`: `ref` for the code stats, `label`, `note` such as «8cc5a85, 4 нояб.»;
- `now_note`, `code_paths`, `scores_title`;
- `archive`: an extra tab linking an older page;
- `captions`.

**`final/rounds.json`** holds what each round changed, in the owner's words: `{"N": {"title": "…", "changes": ["…"]}}`.

**`final/sections.py`** describes the current state against the base. Rewrite it each round; it is not a history.

## Builds (after the helpers report)

Both apps must be built into the same derived data before the string catalog is rebuilt.

```bash
xcodebuild -project WaitingPaws.xcodeproj -scheme WaitingPaws-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/wp-dd-S CODE_SIGNING_ALLOWED=NO build
xcodebuild -project WaitingPaws.xcodeproj -scheme WaitingPaws-macOS -configuration Debug \
  -destination 'generic/platform=macOS' -derivedDataPath /tmp/wp-dd-S CODE_SIGNING_ALLOWED=NO build
xcodebuild … -scheme WaitingPaws-macOS … -derivedDataPath /tmp/wp-dd-M …   # the Mac build that gets shot
python3 Tools/strings/build_catalog.py /tmp/wp-dd-S                       # must report 0 without English
(cd Packages/WaitingPawsCore && swift test)
```

**Strings:**
- Russian literals are the catalog keys. English goes into `Tools/strings/en.json`, written with
  `json.dumps(…, indent=1, ensure_ascii=False)`. Ask helpers to list every new Russian string verbatim.
- `build_catalog.py` reads every `.stringsdata` in the derived data you give it. Run on a Mac-only folder, it drops
  the iOS keys; run on a stale folder, it brings back dead ones.
- `-quiet` builds can print «error: … exit code 0». Check for `BUILD SUCCEEDED` without `-quiet`.

**The base build**, once per run, for `final/main/`:

```bash
git worktree add --detach /tmp/wp-main main
ln -sfn "$PWD/Frameworks" /tmp/wp-main/Frameworks        # Frameworks/ (go2rtc) is gitignored
(cd /tmp/wp-main && xcodebuild … -scheme WaitingPaws-iOS … -derivedDataPath /tmp/wp-dd-main-S … build)
(cd /tmp/wp-main && xcodebuild … -scheme WaitingPaws-macOS … -derivedDataPath /tmp/wp-dd-main-M … build)
$SK/capture-pair.sh final/main /tmp/wp-dd-main-S /tmp/wp-dd-main-M
git worktree remove /tmp/wp-main
```

Before the first capture, cut `capture-pair.sh`'s flags down to the ones the base build knows (check
`App/Sources/Debug/DemoData.swift` and `AppModel`).

## Captures

```bash
$SK/capture.sh round-N/wp ios
$SK/capture-pair.sh round-N/pair /tmp/wp-dd-S /tmp/wp-dd-M ios
$SK/lockcheck.sh && MAC_DD=/tmp/wp-dd-M $SK/capture.sh round-N/wp mac && $SK/capture-pair.sh round-N/pair /tmp/wp-dd-S /tmp/wp-dd-M mac
```

- **Locked screen.** Mac shots need an unlocked screen, because `Tools/ui-shot.sh` captures real windows. While it is
  locked, copy the previous round's `mac-*.png` and tell the delegates which ones are old.
- **Never use `cacheDisplay` snapshots.** Rendering windows from inside the app (`cacheDisplay`,
  `bitmapImageRepForCachingDisplay`) draws the glass toolbar buttons as blank white pills, greys the traffic lights
  and drops the sheet dimming. Delegates then score artifacts, and the owner asks whether it's a bug.
- **Known failure.** `mac-03b-review-edit` always fails in `capture.sh` (`--demo-review-select` opens no window).
- **Text size.** The simulator can keep an AX text size across a shutdown. Both scripts reset `content_size large`
  after boot and wait before shutdown; if shots come out huge, check this first.
- **Helpers' simulators.** Each helper uses its own `SIM_NAME="WP Helper X"` and `DD=/tmp/wp-dd-X`, so it never
  touches «WP Screens».
- **Shut simulators down** when done. A booted capture simulator slows the next capture's boot.

## Live Activity (`ios-11-island`, `ios-12-lock`, `ios-13-notify`)

`simctl io screenshot` often hides the Dynamic Island. The scripts drive SpringBoard with a small UI-test «tapper»
(`live-activity/tapper`) that locks, wakes, long-presses the island and takes screenshots.

```bash
export LA=/tmp/wp-live/rN
$SK/live-activity/setup.sh /tmp/wp-dd-S     # private sim «WP Live rN» (iPhone 17 Pro, iOS 26, ru), app, tapper
$SK/live-activity/batch.sh all              # scenes, states that switch while suspended, notifications (~10 min)
$SK/live-activity/compose.sh                # $LA/island-sheet.png, lock-sheet.png, notify-sheet.png
magick $LA/island-sheet.png +repage $COUNCIL/round-N/wp/ios-11-island.png   # lock → ios-12-lock, notify → ios-13-notify
```

`compose.sh` captions say what each state shows: rewrite them when the Live Activity changes. The crop offsets are
for an iPhone 17 Pro.

## Delegates

Start all three at once in the background, so no delegate sees another's report:

```bash
COUNCIL=$COUNCIL $SK/run-codex.sh round-N        # Bash, run_in_background: true
```

Run the two Claude delegates as Agent calls with `subagent_type: general-purpose`, `run_in_background: true`,
`model: opus` and `model: fable`. Prompt (round 1 drops the «прошлый раунд» part):

> Ты эксперт консилиума по UI/UX приложения Waiting Paws. Прочитай бриф `$COUNCIL/round-N/brief.md` (код
> приложения — `<repo>`) и выполни его: открой листы `$COUNCIL/round-N/sheets/*.jpg` (начни с `c0-*.jpg`),
> оригиналы в `$COUNCIL/round-N/wp/`, прошлый раунд — `$COUNCIL/round-(N-1)/wp/` и свой отчёт
> `$COUNCIL/round-(N-1)/<file>.md`, кадры базы в `$COUNCIL/final/main/`, референсы в `$COUNCIL/refs/`. Только
> чтение: ничего не меняй, не собирай, не запускай. Запиши итоговый отчёт ровно в формате из брифа в файл
> `$COUNCIL/round-N/<file>.md` (последние две строки — OVERALL_SCORE и BETTER_THAN_REFERENCES). В ответе мне —
> только путь к файлу и две последние строки.

Use `claude-opus-5.5.md` and `claude-fable-5.1.md` as the file names, matching `council.json`'s `delegates`.

Wait for the task notifications instead of polling. If codex keeps getting 429, its log says so; a late report is
still that round's report.

**Report format.** `report.py` and `build.py` parse these lines; keep them exact in the brief:
- `### Кейс N — <название> — K/10 (раунд M: L/10)` once per case;
- `### Главное до 10/10` followed by up to 8 numbered edits;
- the last two lines `OVERALL_SCORE: N/10` and `BETTER_THAN_REFERENCES: yes|no`.

A missing score shows as «no score». Never type one in.

## Helpers

Use one background Agent (`model: opus`) per set of files, and keep the sets disjoint. The first run's split:

| Helper | Owned files |
| --- | --- |
| A | `App/Sources/Views/Session/*`, `Components/ExitConditionViews.swift`, `Debug/DemoData.swift` |
| B | `App/Sources/Mac/Console|Plan|History/*` |
| C | `App/Sources/Glance/*`, `App/Widgets/**`, the camera pickers |
| D | `App/Sources/Views/Plan/*`, `Views/History/*` |

The later round used E for the iPhone plan and trainer text, F for the Mac plan and console. Resume helpers with
SendMessage each round so they keep their context; start new ones only for new areas.

Each helper brief has these parts:
- **Header:** «You are helper X on Waiting Paws (SwiftUI, iOS 17+ / macOS 26), repo `<repo>`. Do NOT commit, do not
  switch branches.» Then who owns which files.
- **Why:** the criterion in the owner's words, the delegates' consensus with report paths, before/now shots to look
  at.
- **Your job:** numbered, concrete items, top-to-bottom layouts, «don't regress what the council liked».
- **Build and check:**
  - its own derived data, e.g.
    `xcodebuild … -derivedDataPath /tmp/wp-dd-X CODE_SIGNING_ALLOWED=NO build -quiet`, and the other platform once at
    the end;
  - if a failure is in a file it doesn't own, wait and retry;
  - shots with `SIM_NAME="WP Helper X" DD=/tmp/wp-dd-X $SK/capture.sh /tmp/wp-helperX ios`;
  - large text checked;
  - `swift test` if the core changed;
  - the simulator shut down at the end.
- **Report (short):** what each screen shows now, top to bottom; every new Russian UI string verbatim; new demo flags;
  the best shots' paths.

New screens need a `--demo-…` launch flag: add it to `capture.sh` with a comment saying what the shot shows.

## Summary, page, report to the owner

**`round-N/summary.md`** has these parts:
- a title with the scores;
- the report links;
- a per-case table `Opus | Fable | GPT` with «prev → now» cells and **Итог** (`N (yes)`);
- one or two lines of consensus, quoting the experts where it helps;
- `## План раунда N+1`: numbered items, each saying who asked for it, e.g. «(все трое)» or «(Opus, Fable)».
  `report.py` reads this heading. At the end of a run this becomes `## Полировка (не мешает 10)` plus what was
  deferred.
- `## Council review`.

**Before/after strips:** `$SK/progress.sh progress/rN-<screen>.jpg "<screen>" R<N-1> round-(N-1)/wp/<shot>.png R<N> round-N/wp/<shot>.png`.
Make 2–4 per round, for the screens that changed most.

**The page:**
1. Add round N to `final/rounds.json`.
2. Rewrite `final/sections.py` for the current state.
3. Run `python3 $SK/build.py` and `python3 $SK/report.py`.
4. Open `http://localhost:8771/<run>/final/` with the launch config «council» and check the new tab.

**The owner's message each round:**
- what changed, in plain words;
- scores per delegate and the consensus;
- the before/after strips (paths that open in the app);
- the page link;
- the quota;
- the «## Council review» table:

```
## Council review
Rounds: N

| Delegate | R1 | R2 | … |
| --- | --- | --- | --- |
| Claude Opus 5.5 | 5/10 | 7/10 | … |
| Claude Fable 5.1 | 6/10 | 7/10 | … |
| GPT 6 Astra | 5/10 | no score | … |
```

One column per round; «no score» where a delegate gave none.

**Quota:** check `mcp__ccd_session_mgmt__get_usage` after each round. In the first run a round cost about
1.5–3 % of the weekly quota: R1–R10 ≈ 17 %, R11–R18 ≈ 12 %.
