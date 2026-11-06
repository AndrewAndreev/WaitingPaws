#!/usr/bin/env python3
"""The council's log and page, rebuilt from what is on disk after every round.

    COUNCIL=<run> python3 .claude/skills/design-council/scripts/report.py

Reads `round-N/*.md` reports (the «### Кейс N — … — K/10» lines and the strict OVERALL_SCORE / BETTER_THAN_REFERENCES
lines), `round-N/summary.md` and the before/after images `progress/rN-*.jpg`, and writes:
  - `LOG.md`: per round, the scores, the plan that came out of it and the screenshot diffs;
  - `index.html`: the same as a page, with the current state (the latest round's sheets) on top.
"""
import html
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import council_config  # noqa: E402

HERE = council_config.council_dir()
CONFIG = council_config.load(HERE)
DELEGATES = CONFIG["delegates"]
CASES = CONFIG["cases"]
GOAL = CONFIG["goal"]
TITLE = CONFIG["title"]


def rounds():
    found = []
    for path in HERE.glob("round-*"):
        match = re.fullmatch(r"round-(\d+)", path.name)
        if match and path.is_dir():
            found.append((int(match.group(1)), path))
    return sorted(found)


def parse(report: pathlib.Path):
    if not report.exists():
        return None
    text = report.read_text(encoding="utf-8")
    cases = {}
    for match in re.finditer(r"^### Кейс (\d+)\b.*?—\s*(\d+)/10", text, re.M):
        cases[int(match.group(1))] = int(match.group(2))
    overall = re.search(r"^OVERALL_SCORE:\s*(\d+)/10", text, re.M)
    better = re.search(r"^BETTER_THAN_REFERENCES:\s*(yes|no)", text, re.M)
    return {"cases": cases, "overall": int(overall.group(1)) if overall else None,
            "better": better.group(1) if better else None}


def score_text(result):
    if not result or result["overall"] is None:
        return "no score"
    return f"{result['overall']}/10" + (" ✓" if result["better"] == "yes" else "")


def progress_images(number):
    return sorted((HERE / "progress").glob(f"r{number}-*.jpg"))


def plan_of(round_dir: pathlib.Path):
    summary = round_dir / "summary.md"
    if not summary.exists():
        return None
    text = summary.read_text(encoding="utf-8")
    match = re.search(r"^## План раунда \d+.*?$(.*?)(?=^## )", text, re.M | re.S)
    return match.group(1).strip() if match else None


def build():
    data = []
    for number, path in rounds():
        results = {name: parse(path / file) for file, name in DELEGATES}
        data.append((number, path, results))
    done = [(n, p, r) for n, p, r in data if any(x for x in r.values())]

    # LOG.md
    lines = [f"# {TITLE}: журнал раундов", "", f"Цель: {GOAL}.", "",
             f"Страница с картинками: `{HERE}/index.html`. Пересборка: "
             f"`COUNCIL={HERE} python3 .claude/skills/design-council/scripts/report.py`.", "",
             "## Council review", "", f"Rounds: {len(done)}", ""]
    header = "| Delegate | " + " | ".join(f"Round {n}" for n, _, _ in done) + " |"
    lines += [header, "| --- |" + " --- |" * len(done)]
    for _, name in DELEGATES:
        lines.append(f"| {name} | " + " | ".join(score_text(r[name]) for _, _, r in done) + " |")
    lines.append("")
    for number, path, results in reversed(data):
        lines += [f"## Раунд {number}", ""]
        if any(results.values()):
            lines += ["| Кейс | " + " | ".join(name for _, name in DELEGATES) + " |",
                      "| --- |" + " --- |" * len(DELEGATES)]
            for index, case in enumerate(CASES, start=1):
                row = [str(results[name]["cases"].get(index, "—")) if results[name] else "—" for _, name in DELEGATES]
                lines.append(f"| {index}. {case} | " + " | ".join(row) + " |")
            lines.append("")
        else:
            lines += ["Идёт: правки и съёмка.", ""]
        images = progress_images(number)
        if images:
            lines.append("Было → стало:")
            lines += [f"- [{image.stem}](progress/{image.name})" for image in images]
            lines.append("")
        plan = plan_of(path)
        if plan:
            lines += [f"План раунда {number + 1} — из `round-{number}/summary.md`.", ""]
    (HERE / "LOG.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

    # index.html
    def esc(text):
        return html.escape(str(text))

    latest = done[-1] if done else None
    rows = "".join(
        f"<tr><th>{esc(name)}</th>" + "".join(
            f"<td class='{'yes' if r[name] and r[name]['better'] == 'yes' else ''}'>{esc(score_text(r[name]))}</td>"
            for _, _, r in done) + "</tr>" for _, name in DELEGATES)
    head = "".join(f"<th>Раунд {n}</th>" for n, _, _ in done)
    sections = []
    for number, path, results in reversed(data):
        images = progress_images(number)
        sheets = sorted((path / "sheets").glob("*.jpg")) if (path / "sheets").exists() else []
        cases = ""
        if any(results.values()):
            cases = "<table class='cases'><tr><th>Кейс</th>" + "".join(f"<th>{esc(n)}</th>" for _, n in DELEGATES) + "</tr>" + "".join(
                f"<tr><td>{i}. {esc(c)}</td>" + "".join(
                    f"<td>{esc(results[n]['cases'].get(i, '—')) if results[n] else '—'}</td>" for _, n in DELEGATES) + "</tr>"
                for i, c in enumerate(CASES, start=1)) + "</table>"
        status = "" if any(results.values()) else "<p class='note'>Идёт: правки и съёмка этого раунда.</p>"
        figures = "".join(f"<figure><a href='progress/{esc(i.name)}'><img src='progress/{esc(i.name)}' loading='lazy'></a>"
                          f"<figcaption>{esc(i.stem)}</figcaption></figure>" for i in images)
        sheet_links = " · ".join(f"<a href='round-{number}/sheets/{esc(s.name)}'>{esc(s.stem)}</a>" for s in sheets)
        reports = " · ".join(f"<a href='round-{number}/{f}'>{esc(n)}</a>" for f, n in DELEGATES if (path / f).exists())
        sections.append(
            f"<section><h2>Раунд {number}</h2>{status}{cases}"
            + (f"<h3>Было → стало</h3><div class='grid'>{figures}</div>" if figures else "")
            + (f"<p class='links'>Листы сравнения: {sheet_links}</p>" if sheet_links else "")
            + (f"<p class='links'>Отчёты: {reports} · <a href='round-{number}/summary.md'>сводка</a></p>" if reports else "")
            + "</section>")
    current = ""
    if latest:
        n, path, _ = latest
        sheets = sorted((path / "sheets").glob("*.jpg"))
        current = ("<section class='current'><h2>Текущее состояние — листы раунда " + str(n) + "</h2><div class='grid wide'>"
                   + "".join(f"<figure><a href='round-{n}/sheets/{esc(s.name)}'><img src='round-{n}/sheets/{esc(s.name)}' "
                             f"loading='lazy'></a><figcaption>{esc(s.stem)}</figcaption></figure>" for s in sheets)
                   + "</div></section>")
    experts = ", ".join(name for _, name in DELEGATES)
    final_link = ('<p class="goal"><a href="final/">Итог: что стало лучше относительно main — со скриншотами →</a></p>'
                  if (HERE / "final").is_dir() else "")
    page = f"""<!doctype html><html lang="ru"><meta charset="utf-8"><title>{esc(TITLE)}</title>
<style>
:root {{ color-scheme: dark; }}
body {{ margin: 0; padding: 32px 40px 80px; background: #111113; color: #ececf0;
       font: 15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }}
h1 {{ font-size: 30px; margin: 0 0 4px; }} h2 {{ font-size: 22px; margin: 40px 0 12px; }}
h3 {{ font-size: 15px; color: #a0a0a8; font-weight: 600; margin: 18px 0 8px; }}
.goal {{ color: #a0a0a8; margin: 0 0 20px; }}
table {{ border-collapse: collapse; margin: 8px 0; }} th, td {{ padding: 6px 12px; text-align: left; border-bottom: 1px solid #26262b; }}
th {{ color: #a0a0a8; font-weight: 600; }} td.yes {{ color: #6ee8a0; }}
.scores td {{ font-variant-numeric: tabular-nums; font-weight: 600; }}
.grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(560px, 1fr)); gap: 14px; }}
.grid.wide {{ grid-template-columns: repeat(auto-fill, minmax(480px, 1fr)); }}
figure {{ margin: 0; background: #1b1b1f; border-radius: 12px; overflow: hidden; }}
figure img {{ width: 100%; display: block; }} figcaption {{ padding: 6px 10px; color: #8e8e96; font-size: 12px; }}
.links {{ color: #8e8e96; }} a {{ color: #ffb3cf; text-decoration: none; }} .note {{ color: #ffb84d; }}
section {{ border-top: 1px solid #222227; }}
</style>
<h1>{esc(TITLE)}</h1>
<p class="goal">Цель: {esc(GOAL)}. Эксперты: {esc(experts)}. ✓ — «лучше референсов».</p>
{final_link}
<table class="scores"><tr><th>Эксперт</th>{head}</tr>{rows}</table>
<p class="links"><a href="LOG.md">LOG.md</a> · <a href="refs/">референсы</a></p>
{current}
{''.join(sections)}
</html>"""
    (HERE / "index.html").write_text(page, encoding="utf-8")
    print(f"LOG.md and index.html: {len(done)} rounds scored, {len(data)} round folders")


if __name__ == "__main__":
    build()
