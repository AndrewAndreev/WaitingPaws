#!/usr/bin/env python3
"""Writes docs/privacy.html (English + Russian) from App/Resources/Legal/PrivacyPolicy-*.md, so the page published
for App Store Connect and the text inside the app are the same. Run after editing either Markdown file."""
import html
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def render(markdown):
    out = []
    for line in markdown.splitlines():
        line = line.strip()
        if not line:
            continue
        text = html.escape(line.lstrip("# ").strip())
        text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
        if line.startswith("## "):
            out.append(f"<h2>{text}</h2>")
        elif line.startswith("# "):
            out.append(f"<h1>{text}</h1>")
        else:
            out.append(f"<p>{text}</p>")
    return "\n".join(out)


def main():
    legal = os.path.join(ROOT, "App/Resources/Legal")
    en = render(open(os.path.join(legal, "PrivacyPolicy-en.md"), encoding="utf-8").read())
    ru = render(open(os.path.join(legal, "PrivacyPolicy-ru.md"), encoding="utf-8").read())
    page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Waiting Paws — Privacy Policy</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<nav><a href="index.html">Waiting Paws</a> · <a href="#en">English</a> · <a href="#ru">Русский</a></nav>
<article id="en" lang="en">
{en}
</article>
<hr>
<article id="ru" lang="ru">
{ru}
</article>
</body>
</html>
"""
    with open(os.path.join(ROOT, "docs/privacy.html"), "w", encoding="utf-8") as f:
        f.write(page)
    print("Wrote docs/privacy.html")


if __name__ == "__main__":
    main()
