#!/usr/bin/env python3
"""The council's comparison page: the base build against the latest round, and every round of the current
criterion on its own tab.

    COUNCIL=<run> python3 .claude/skills/design-council/scripts/build.py   → <run>/final/index.html (/<run>/final/)

Tabs:
  «base → сейчас»  final/sections.py: per section what is better than the base, pairs final/main/ ↔ round-N/pair/
                   (capture-pair.sh, the same launch flags on both builds) and the screens the base never had
                   (round-N/wp/, capture.sh); N is the latest round with pictures;
  «Раунд N»        (N ≥ first_round in council.json) the scores, what changed (final/rounds.json), the experts'
                   «Главное до 10/10», and the shots that differ from round N-1;
  archive          optional (council.json "archive"): a link to an older page.
Pictures go to final/img/ as JPEGs no wider than 1800 px; whether two rounds' shots differ is cached in
final/.diffcache.json.
"""
import html
import importlib.util
import json
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import council_config  # noqa: E402

COUNCIL = council_config.council_dir()
CONFIG = council_config.load(COUNCIL)
HERE = COUNCIL / "final"
ROOT = council_config.repo()
IMG = HERE / "img"


def _sections():
    path = HERE / "sections.py"
    if not path.exists():
        sys.exit(f"No {path}: copy templates/sections.py there and describe the current state.")
    spec = importlib.util.spec_from_file_location("sections", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


sections = _sections()
DELEGATES = CONFIG["delegates"]
CASES = CONFIG["cases"]
FIRST = CONFIG["first_round"]
BASE = CONFIG["base"]
_rounds_file = HERE / "rounds.json"
# What each round changed, for its tab (short, for the owner): {"12": {"title": "…", "changes": ["…"]}}.
ROUNDS = ({int(k): v for k, v in json.loads(_rounds_file.read_text(encoding="utf-8")).items()}
          if _rounds_file.exists() else {})

CAPTIONS = {
    "ios-01-home": "Главный экран", "ios-02-plan-review": "Проверка плана", "ios-02b-plan-end": "Конец плана",
    "ios-02c-plan-source": "Текст тренера из плана", "ios-03-away": "Выход", "ios-03b-away-lies-down": "Выход, отметка",
    "ios-03c-away-can-come-in": "Выход, условие вышло", "ios-03d-away-wait-quiet": "Выход, тишина",
    "ios-03e-away-barking": "Выход, лает", "ios-03f-away-zoomed": "Кадр приближен", "ios-03g-away-no-frame": "Нет кадра",
    "ios-03h-away-large-text": "Шрифт xxL", "ios-03i-away-ax": "Шрифт AX", "ios-03j-away-barking-ax": "AX, лает",
    "ios-04-away-details": "Подробности выхода", "ios-05-break": "Перерыв", "ios-05b-false-start-undo": "После фальстарта",
    "ios-05c-break-false-start": "Фальстарт в перерыве", "ios-05d-break-ax": "Перерыв, AX", "ios-05e-break-ax": "Перерыв, AX",
    "ios-06-trainer-text": "Текст тренера", "ios-07-log": "Тренировка из истории", "ios-07b-log-bottom": "Она же, низ",
    "ios-07d-log-video-gap": "Запись частями", "ios-08-history": "История", "ios-08b-history-edit": "Правка истории",
    "ios-08c-history-recordings": "История, значки записи", "ios-09-cameras": "Выбор камеры", "ios-10-finish": "Финиш",
    "ios-11-island": "Dynamic Island", "ios-12-lock": "Экран блокировки", "ios-13-notify": "Уведомления",
    "mac-01-session": "Mac · выход", "mac-01b-session-lies-down": "Mac · выход, отметка", "mac-01c-session-marks": "Mac · таймлайн",
    "mac-01d-session-quiet": "Mac · тишина", "mac-01e-session-barking": "Mac · лает", "mac-02-plan": "Mac · план",
    "mac-02b-plan-edit": "Mac · правка плана", "mac-03-review": "Mac · разбор", "mac-04-break": "Mac · перерыв",
    "mac-04b-break-false-start": "Mac · фальстарт в перерыве", "mac-05-history": "Mac · история",
    "mac-06-finish": "Mac · финиш", "mac-06-finish-2": "Mac · итог",
}
CAPTIONS.update(CONFIG["captions"])


def round_numbers():
    return sorted(int(m.group(1)) for p in COUNCIL.glob("round-*") if (m := re.fullmatch(r"round-(\d+)", p.name)))


def latest_with(sub):
    found = [n for n in round_numbers() if (COUNCIL / f"round-{n}" / sub).is_dir()]
    return found[-1] if found else None


def source(kind, name):
    """kind: 'main' (final/main), 'pair' / 'wp' (the latest round's), or (N, 'wp'|'pair') for round N."""
    if kind == "main":
        return HERE / "main" / f"{name}.png", "main"
    if isinstance(kind, tuple):
        number, sub = kind
        return COUNCIL / f"round-{number}" / sub / f"{name}.png", f"r{number}-{sub}"
    # The latest round that has this picture (a Mac shot may be older when the screen was locked).
    for number in reversed(round_numbers()):
        path = COUNCIL / f"round-{number}" / kind / f"{name}.png"
        if path.exists():
            return path, f"r{number}-{kind}"
    return None, None


def jpeg(kind, name):
    path, prefix = source(kind, name)
    if not path or not path.exists():
        return None
    IMG.mkdir(exist_ok=True)
    target = IMG / f"{prefix}-{name}.jpg"
    if not target.exists() or target.stat().st_mtime < path.stat().st_mtime:
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "84", "-Z", "1800", str(path),
                        "--out", str(target)], check=True, capture_output=True)
    return f"img/{target.name}"


DIFFS = HERE / ".diffcache.json"
_diffs = json.loads(DIFFS.read_text()) if DIFFS.exists() else {}


def differs(a: pathlib.Path, b: pathlib.Path) -> bool:
    key = f"{a}|{a.stat().st_mtime}|{b}|{b.stat().st_mtime}"
    if key not in _diffs:
        run = subprocess.run(["magick", "compare", "-metric", "AE", "-fuzz", "4%", str(a), str(b), "null:"],
                             capture_output=True, text=True)
        try:
            pixels = float(run.stderr.split()[0])
        except (ValueError, IndexError):
            pixels = 1e9  # sizes differ, or no answer: count as changed
        _diffs[key] = pixels > 2000
    return _diffs[key]


def figure(src, caption, cls=""):
    if not src:
        return (f'<figure class="none {cls}"><div>Этого экрана не было</div>'
                f'<figcaption>{caption}</figcaption></figure>')
    return (f'<figure class="{cls}"><a href="{src}" target="_blank"><img src="{src}" loading="lazy"></a>'
            f'<figcaption>{caption}</figcaption></figure>')


def report(number, file):
    path = COUNCIL / f"round-{number}" / file
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8")
    cases = {int(m.group(1)): int(m.group(2)) for m in re.finditer(r"^### Кейс (\d+)\b.*?—\s*(\d+)/10", text, re.M)}
    overall = re.search(r"^OVERALL_SCORE:\s*(\d+)/10", text, re.M)
    better = re.search(r"^BETTER_THAN_REFERENCES:\s*(yes|no)", text, re.M)
    main = re.search(r"^### Главное до 10/10\s*$(.*?)(?=^OVERALL_SCORE|^### |\Z)", text, re.M | re.S)
    return {"cases": cases, "overall": int(overall.group(1)) if overall else None,
            "better": better.group(1) if better else None, "main": main.group(1).strip() if main else ""}


def md(text):
    """The few bits of markdown the reports use: list items, **bold**, `code`."""
    items = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        body = html.escape(re.sub(r"^(\d+[.)]|[-*•])\s+", "", line))
        body = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", body)
        body = re.sub(r"`(.+?)`", r"<code>\1</code>", body)
        items.append(f"<li>{body}</li>")
    return "<ol>" + "".join(items) + "</ol>"


def score_cell(result):
    if not result or result["overall"] is None:
        return '<td class="none">no score</td>'
    score = result["overall"]
    return f'<td class="{"ten" if score == 10 else ""}">{score}/10</td>'


def scores_table(numbers):
    head = "".join(f"<th>R{n}</th>" for n in numbers)
    rows = ""
    for file, name in DELEGATES:
        rows += f"<tr><th>{html.escape(name)}</th>" + "".join(score_cell(report(n, file)) for n in numbers) + "</tr>"
    return f"<table><tr><th>Delegate</th>{head}</tr>{rows}</table>"


def cases_table(number):
    reports = [report(number, file) for file, _ in DELEGATES]
    head = "".join(f"<th>{html.escape(name.replace('Claude ', ''))}</th>" for _, name in DELEGATES)
    rows = ""
    for index, case in enumerate(CASES, 1):
        cells = ""
        for result in reports:
            value = result["cases"].get(index) if result else None
            cells += f'<td class="{"ten" if value == 10 else ""}">{value if value is not None else "—"}</td>'
        rows += f"<tr><th>{index}. {html.escape(case)}</th>{cells}</tr>"
    return f'<table class="cases"><tr><th>Кейс</th>{head}</tr>{rows}</table>'


def diff_stats():
    if not ROOT.is_dir():
        return 0, 0, 0
    paths = CONFIG["code_paths"]
    short = subprocess.run(["git", "diff", "--shortstat", BASE["ref"], "--", *paths], cwd=ROOT,
                           capture_output=True, text=True).stdout
    numbers = [int(n) for n in re.findall(r"(\d+) (?:files? changed|insertions?|deletions?)", short)]
    files, added, removed = (numbers + [0, 0, 0])[:3]
    new = subprocess.run(["git", "ls-files", "--others", "--exclude-standard", "--", *paths],
                         cwd=ROOT, capture_output=True, text=True).stdout.split()
    new_lines = sum(len((ROOT / f).read_text(encoding="utf-8", errors="ignore").splitlines()) for f in new)
    return files + len(new), added + new_lines, removed


def thousands(number):
    return f"{number:,}".replace(",", " ")


def now_tab(latest):
    body = ""
    for index, section in enumerate(sections.SECTIONS):
        mac = section.get("mac", False)
        items = "".join(f"<li>{html.escape(b)}</li>" for b in section["better"])
        pairs = ""
        for name, caption in section["pairs"]:
            before, after = jpeg("main", name), jpeg("pair", name)
            if after:
                shot_round = after.split("/")[1].split("-")[0][1:]
                pairs += (f'<div class="pair"><h4>{html.escape(caption)}</h4><div class="two">'
                          f'{figure(before, "main")}{figure(after, f"сейчас · R{shot_round}", "now")}</div></div>')
        new = "".join(figure(src, html.escape(caption)) for kind, name, caption in section["new"]
                      if (src := jpeg(kind, name)))
        body += (f'<section class="{"mac" if mac else "ios"}" id="now-s{index}"><h2>{html.escape(section["title"])}</h2>'
                 f'<p class="case">{html.escape(section["case"])}</p><ul>{items}</ul>'
                 + (f'<div class="pairs">{pairs}</div>' if pairs else "")
                 + (f'<h3>Новое — на {html.escape(BASE["label"])} такого нет</h3><div class="grid new">{new}</div>'
                    if new else "")
                 + "</section>")
    nav = " · ".join(f'<a href="#now" data-to="now-s{i}">{html.escape(s["title"])}</a>'
                     for i, s in enumerate(sections.SECTIONS))
    left = "".join(f"<li>{html.escape(item)}</li>" for item in sections.LEFT)
    base = html.escape(BASE["label"])
    note = f' ({html.escape(BASE["note"])})' if BASE.get("note") else ""
    now_note = f', {html.escape(CONFIG["now_note"])}' if CONFIG.get("now_note") else ""
    return (f'<p class="lead">Слева — <b>{base}</b>{note}, справа — <b>сейчас</b> (раунд {latest}{now_note}). Пары '
            f'сняты с одними и теми же параметрами запуска на обеих сборках; ниже — экраны, которых на {base} не '
            f'было. Клик по кадру открывает его целиком.</p>'
            f'<p class="jump">{nav}</p>{body}'
            f'<div class="left"><h2>Что осталось</h2><ul>{left}</ul></div>')


def round_tab(number):
    info = ROUNDS.get(number, {"title": "", "changes": []})
    changes = "".join(f"<li>{html.escape(c)}</li>" for c in info["changes"])
    experts = ""
    for file, name in DELEGATES:
        result = report(number, file)
        if result and result["main"]:
            label = f"{name} — {result['overall']}/10" if result["overall"] is not None else f"{name} — no score"
            experts += f"<details><summary>{html.escape(label)}</summary>{md(result['main'])}</details>"
        elif not result:
            experts += f'<p class="muted">{html.escape(name)}: отчёта ещё нет</p>'
    shots = ""
    previous = number - 1
    this_wp, prev_wp = COUNCIL / f"round-{number}" / "wp", COUNCIL / f"round-{previous}" / "wp"
    if number > FIRST and this_wp.is_dir() and prev_wp.is_dir():
        for path in sorted(this_wp.glob("*.png")):
            name = path.stem
            if name.endswith("-2") and not name.startswith("mac-06"):
                continue
            old = prev_wp / path.name
            if old.exists() and not differs(old, path):
                continue
            mac = name.startswith("mac-")
            before = jpeg((previous, "wp"), name) if old.exists() else None
            after = jpeg((number, "wp"), name)
            caption = html.escape(CAPTIONS.get(name, name))
            shots += (f'<div class="pair {"wide" if mac else ""}"><h4>{caption}</h4><div class="two">'
                      f'{figure(before, f"R{previous}")}{figure(after, f"R{number}", "now")}</div></div>')
    sheet = COUNCIL / f"round-{number}" / "sheets" / "c0-main-vs-now.jpg"
    extra = ""
    if number == FIRST and sheet.exists():
        extra = (f'<h3>С чего начал владелец: main и сейчас</h3><figure class="sheet"><a href="../round-{number}/'
                 f'sheets/c0-main-vs-now.jpg" target="_blank"><img src="../round-{number}/sheets/c0-main-vs-now.jpg">'
                 f'</a></figure>')
    has_reports = any(report(number, f) for f, _ in DELEGATES)
    return (f'<h2>Раунд {number}: {html.escape(info["title"])}</h2>'
            + (f'<ul>{changes}</ul>' if changes else "")
            + (f'<h3>Оценки по кейсам</h3>{cases_table(number)}' if has_reports else "")
            + (f'<h3>Главное до 10/10 — от каждого эксперта</h3>{experts}' if experts else "")
            + extra
            + (f'<h3>Что изменилось на экранах (R{previous} → R{number})</h3><div class="pairs">{shots}</div>'
               if shots else ""))


def scores_line(number):
    if number is None:
        return "—"
    parts = []
    for file, _ in DELEGATES:
        result = report(number, file)
        parts.append(str(result["overall"]) if result and result["overall"] is not None else "no score")
    return " · ".join(parts)


def page():
    numbers = round_numbers()
    new_rounds = [n for n in numbers if n >= FIRST]
    latest = latest_with("pair") or FIRST
    files, added, removed = diff_stats()
    tabs = [f'<a href="#now" class="tab">{html.escape(BASE["label"])} → сейчас</a>'] + [
        f'<a href="#r{n}" class="tab">Раунд {n}</a>' for n in new_rounds]
    if CONFIG.get("archive"):
        tabs.append(f'<a href="{html.escape(CONFIG["archive"]["href"])}" class="tab ext">'
                    f'{html.escape(CONFIG["archive"]["label"])}</a>')
    names = [name for _, name in DELEGATES]
    short = " · ".join(name.replace("Claude ", "").split()[0] for name in names)
    lead = CONFIG.get("lead") or (f"Консилиум: {', '.join(names)}. С раунда {FIRST} — критерий: "
                                  f"{CONFIG['goal']}.")
    panels = f'<div class="panel" id="now">{now_tab(latest)}</div>' + "".join(
        f'<div class="panel" id="r{n}">{round_tab(n)}</div>' for n in new_rounds)
    last_scored = max((n for n in new_rounds if any(report(n, f) for f, _ in DELEGATES)), default=None)
    DIFFS.write_text(json.dumps(_diffs, ensure_ascii=False, indent=0))
    return f"""<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(CONFIG["page_title"])}</title>
<style>
:root {{ color-scheme: dark; }}
body {{ margin: 0; padding: 32px 44px 90px; background: #111113; color: #ececf0;
       font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }}
h1 {{ font-size: 32px; margin: 0 0 6px; letter-spacing: -0.01em; }}
h2 {{ font-size: 24px; margin: 0 0 4px; }} h3 {{ font-size: 14px; color: #a0a0a8; font-weight: 600; margin: 28px 0 10px; }}
h4 {{ font-size: 13px; color: #c8c8d0; font-weight: 600; margin: 0 0 8px; }}
.lead {{ color: #a0a0a8; margin: 0 0 14px; max-width: 1000px; }} .muted {{ color: #6c6c74; }}
.stats {{ display: flex; gap: 12px; flex-wrap: wrap; margin: 14px 0 18px; }}
.stat {{ background: #1b1b1f; border-radius: 14px; padding: 10px 16px; min-width: 140px; }}
.stat b {{ display: block; font-size: 24px; font-variant-numeric: tabular-nums; }}
.stat span {{ color: #8e8e96; font-size: 13px; }}
table {{ border-collapse: collapse; margin: 0 0 8px; font-variant-numeric: tabular-nums; }}
th, td {{ padding: 6px 10px; text-align: center; border-bottom: 1px solid #26262b; }}
th {{ color: #a0a0a8; font-weight: 600; }} tr th:first-child {{ text-align: left; color: #ececf0; }}
td {{ font-weight: 600; color: #c8c8d0; }} td.ten {{ color: #111113; background: #6ee8a0; }} td.none {{ color: #6c6c74; }}
.tabs {{ position: sticky; top: 0; z-index: 3; background: rgba(17,17,19,0.94); backdrop-filter: blur(12px);
        display: flex; gap: 6px; flex-wrap: wrap; padding: 12px 0; margin: 10px 0 18px; border-bottom: 1px solid #26262b; }}
.tab {{ padding: 6px 14px; border-radius: 999px; background: #1b1b1f; color: #c8c8d0; font-size: 14px; }}
.tab.on {{ background: #ff7aa8; color: #111113; font-weight: 600; }} .tab.ext {{ color: #8e8e96; }}
a {{ color: #ffb3cf; text-decoration: none; }} code {{ font-size: 13px; color: #c8c8d0; }}
.panel {{ display: none; }} .panel.on {{ display: block; }}
.jump {{ font-size: 14px; color: #8e8e96; }}
section {{ margin: 40px 0 0; }}
.case {{ color: #8e8e96; margin: 0 0 10px; font-size: 13px; }}
ul, ol {{ margin: 0 0 16px; padding-left: 22px; max-width: 1080px; }} li {{ margin: 3px 0; }}
details {{ background: #1b1b1f; border-radius: 12px; padding: 10px 16px; margin: 8px 0; max-width: 1080px; }}
summary {{ cursor: pointer; font-weight: 600; }}
.pairs {{ display: flex; flex-wrap: wrap; gap: 26px; }}
.pair {{ flex: 0 0 auto; }} .two {{ display: flex; gap: 10px; }} .two figure {{ width: 250px; }}
.mac .pair, .pair.wide {{ width: 100%; }} .mac .two, .pair.wide .two {{ display: grid; grid-template-columns: 1fr 1fr; gap: 14px; }}
.mac .two figure, .pair.wide .two figure {{ width: auto; }}
figure {{ margin: 0; background: #1b1b1f; border-radius: 12px; overflow: hidden; }}
figure img {{ width: 100%; display: block; }} figure.sheet {{ max-width: 1400px; }}
figcaption {{ padding: 6px 10px; color: #8e8e96; font-size: 12px; }}
figure.now {{ box-shadow: 0 0 0 2px #ff7aa8; }} figure.now figcaption {{ color: #ffb3cf; font-weight: 600; }}
figure.none {{ display: flex; flex-direction: column; justify-content: space-between; min-height: 200px; }}
figure.none div {{ flex: 1; display: grid; place-items: center; color: #6c6c74; padding: 40px 16px; text-align: center; }}
.grid {{ display: grid; gap: 12px; }}
.ios .grid.new {{ grid-template-columns: repeat(auto-fill, minmax(190px, 1fr)); }}
.mac .grid.new {{ grid-template-columns: repeat(auto-fill, minmax(420px, 1fr)); }}
.left {{ background: #1b1b1f; border-radius: 14px; padding: 16px 22px; margin-top: 50px; max-width: 1080px; }}
.left h2 {{ font-size: 18px; margin-bottom: 8px; }}
</style></head><body>
<h1>{html.escape(CONFIG["page_title"])}</h1>
<p class="lead">{html.escape(lead)}</p>
<div class="stats">
<div class="stat"><b>{scores_line(last_scored)}</b><span>{html.escape(short)}, раунд {last_scored or "—"}</span></div>
<div class="stat"><b>{files}</b><span>файлов кода изменено против {html.escape(BASE["label"])}</span></div>
<div class="stat"><b>+{thousands(added)} −{thousands(removed)}</b><span>строк против {html.escape(BASE["label"])}</span></div>
</div>
<h3>{html.escape(CONFIG["scores_title"])}</h3>
{scores_table(new_rounds)}
<nav class="tabs">{"".join(tabs)}</nav>
{panels}
<script>
const panels = [...document.querySelectorAll('.panel')], tabs = [...document.querySelectorAll('.tab:not(.ext)')];
function show() {{
  const id = location.hash.slice(1) || 'now';
  const target = panels.find(p => p.id === id) ? id : 'now';
  panels.forEach(p => p.classList.toggle('on', p.id === target));
  tabs.forEach(t => t.classList.toggle('on', t.getAttribute('href') === '#' + target));
}}
document.querySelectorAll('[data-to]').forEach(a => a.addEventListener('click', e => {{
  e.preventDefault(); location.hash = 'now'; show();
  document.getElementById(a.dataset.to).scrollIntoView({{behavior: 'smooth'}});
}}));
window.addEventListener('hashchange', show); show();
</script>
</body></html>
"""


if __name__ == "__main__":
    HERE.mkdir(exist_ok=True)
    (HERE / "index.html").write_text(page(), encoding="utf-8")
    print(f"{HERE}/index.html")
