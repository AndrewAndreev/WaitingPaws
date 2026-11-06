"""The run's settings for report.py and build.py: `$COUNCIL/council.json` over the defaults below.

The run folder comes from $COUNCIL or the first argument; the Waiting Paws checkout from $WP_REPO or the repository
this skill lives in. A run's own words (round titles, the «base → сейчас» sections) live in the run folder too:
`final/rounds.json` and `final/sections.py` (templates in ../templates/).
"""
import json
import os
import pathlib
import subprocess
import sys

DEFAULTS = {
    "title": "Консилиум Waiting Paws",             # report.py's page and LOG.md
    "page_title": "Waiting Paws: main → сейчас",    # build.py's page
    "goal": "10/10 у каждого эксперта по критерию владельца; стоп — 40 % недельной квоты Claude",
    "lead": None,               # build.py's first paragraph; None: made from the delegates and the goal
    "delegates": [["claude-opus-5.5.md", "Claude Opus 5.5"], ["claude-fable-5.1.md", "Claude Fable 5.1"],
                  ["gpt-6-astra.md", "GPT 6 Astra"]],
    "cases": ["План", "«За дверью»", "Перерыв", "Взгляд мимоходом", "Итог и лог", "История",
              "Камера и главный экран"],
    "first_round": 1,           # the first round with a tab of its own (rounds of the current criterion)
    "base": {"ref": "main", "label": "main", "note": ""},   # what final/main/ was shot from
    "now_note": "рабочая копия, не закоммичено",
    "code_paths": ["App", "Packages", "Tools"],              # counted in «файлов кода изменено против …»
    "scores_title": "Council review",
    "archive": None,            # {"href": "archive-r11/", "label": "Раунды 1–11 ↗"}: a tab that links an older page
    "captions": {},             # extra or different captions for shot names (build.py has the usual ones)
}


def council_dir() -> pathlib.Path:
    arg = next((a for a in sys.argv[1:] if not a.startswith("-")), None)
    path = os.environ.get("COUNCIL") or arg
    if not path:
        sys.exit("Set COUNCIL to the run folder (or pass it as the first argument).")
    path = pathlib.Path(path).expanduser().resolve()
    if not path.is_dir():
        sys.exit(f"No run folder at {path}")
    return path


def load(council: pathlib.Path) -> dict:
    config = json.loads(json.dumps(DEFAULTS))
    file = council / "council.json"
    if file.exists():
        for key, value in json.loads(file.read_text(encoding="utf-8")).items():
            if isinstance(value, dict) and isinstance(config.get(key), dict):
                config[key].update(value)
            else:
                config[key] = value
    config["delegates"] = [tuple(d) for d in config["delegates"]]
    return config


def repo() -> pathlib.Path:
    if os.environ.get("WP_REPO"):
        return pathlib.Path(os.environ["WP_REPO"]).expanduser()
    here = pathlib.Path(__file__).resolve().parent
    run = subprocess.run(["git", "-C", str(here), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    return pathlib.Path(run.stdout.strip()) if run.returncode == 0 else here
