"""What the «base → сейчас» tab says: per section the owner-facing list of what is better than the base now, the
pairs (final/main/ ↔ the latest round's pair/, same launch flags) and the screens the base never had (the latest
round's wp/). Rewritten after every round, so it always describes the current state — not the history of rounds."""

# A section: title, the council's case, what is better than the base (short, concrete, the owner's words), pairs
# (shot name in final/main/ and the latest pair/, caption), new screens (kind "wp", shot name, caption).
# "mac": True lays the pairs out wide.
SECTIONS = [
    {
        "title": "За дверью",
        "case": "Кейс 2 · референсы: Apple Fitness, Runna, Crouton",
        "better": [
            "FILL: one line per improvement the owner can see on the pair below.",
        ],
        "pairs": [("ios-03-away", "Выход идёт")],
        "new": [],
    },
    {
        "title": "Mac",
        "case": "Кейсы 1–3, 5, 6 на Mac",
        "mac": True,
        "better": [],
        "pairs": [("mac-01-session", "Тренировка"), ("mac-03-review", "Разбор плана")],
        "new": [],
    },
]

# «Что осталось»: what is not done, deferred or unverified (Mac shots from an older round, Windows parity, nothing
# committed…).
LEFT = [
    "FILL",
]
