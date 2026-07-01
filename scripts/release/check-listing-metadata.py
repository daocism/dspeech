#!/usr/bin/env python3
from __future__ import annotations
import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LISTING_DIR = Path("docs/product/app-store")

# App Store Connect hard limits (character counts on the unicode string; App Store
# counts characters, not bytes). Keywords is a single comma-separated string.
LIMIT_TITLE = 30
LIMIT_SUBTITLE = 30
LIMIT_PROMOTIONAL = 170
LIMIT_KEYWORDS = 100
LIMIT_DESCRIPTION = 4000

# Metadata table row order is structurally identical across every locale draft
# (field labels are localized, so positions — not label text — are the anchor):
# 0 name, 1 subtitle, 2 promotional, 3 support URL, 4 marketing URL, 5 keywords.
METADATA_ROW_MIN = 6
LENGTH_CHECKS = {
    0: ("name/title", LIMIT_TITLE),
    1: ("subtitle", LIMIT_SUBTITLE),
    2: ("promotional text", LIMIT_PROMOTIONAL),
    5: ("keywords", LIMIT_KEYWORDS),
}

# CIS regions are forbidden in availability / region / marketing lists (repo hard
# rule + docs/product/pricing-top20-aviation.md). The ru/uk *language* listings are
# deliberate localizations, so this scans for CIS country NAMES appearing as words,
# not for the existence of a locale file. Ukraine/Georgia are intentionally excluded
# (uk is a shipped localization; Georgia is ambiguous with the US state and left the
# grouping) to avoid false positives.
FORBIDDEN_REGION_TERMS = [
    "Russia",
    "Russian Federation",
    "Belarus",
    "Kazakhstan",
    "Kyrgyzstan",
    "Kyrgyz Republic",
    "Tajikistan",
    "Turkmenistan",
    "Uzbekistan",
    "Armenia",
    "Azerbaijan",
    "Moldova",
    "Россия",
    "Российская",
    "Беларусь",
    "Казахстан",
    "Кыргызстан",
    "Киргизия",
    "Таджикистан",
    "Туркменистан",
    "Узбекистан",
    "Армения",
    "Азербайджан",
    "Молдова",
    "Молдавия",
]
FORBIDDEN_REGION_PATTERNS = [
    (term, re.compile(rf"(?<!\w){re.escape(term)}(?!\w)", re.IGNORECASE | re.UNICODE))
    for term in FORBIDDEN_REGION_TERMS
]

SEPARATOR_ROW = re.compile(r"^\|[\s:\-|]+\|$")


class CheckState:
    def __init__(self) -> None:
        self.failures: list[str] = []

    def fail(self, message: str) -> None:
        self.failures.append(message)


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


@dataclass(frozen=True)
class Section:
    title: str
    body: str


def split_h2_sections(text: str) -> list[Section]:
    sections: list[Section] = []
    current_title: str | None = None
    current_lines: list[str] = []
    for line in text.splitlines():
        if line.startswith("## "):
            if current_title is not None:
                sections.append(Section(current_title, "\n".join(current_lines).strip()))
            current_title = line[3:].strip()
            current_lines = []
        elif current_title is not None:
            current_lines.append(line)
    if current_title is not None:
        sections.append(Section(current_title, "\n".join(current_lines).strip()))
    return sections


def table_data_rows(body: str) -> list[list[str]]:
    pipe_lines = [
        line.strip()
        for line in body.splitlines()
        if line.strip().startswith("|")
        and not SEPARATOR_ROW.match(line.strip())
    ]
    # First remaining pipe line is the header row (field/draft); the rest are data.
    rows: list[list[str]] = []
    for line in pipe_lines[1:]:
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        rows.append(cells)
    return rows


def check_listing(path: Path, state: CheckState) -> None:
    name = rel(path)
    text = path.read_text(encoding="utf-8")

    if not text.lstrip().startswith("# "):
        state.fail(f"{name}: missing H1 title (first content line must be '# ...')")

    sections = split_h2_sections(text)
    if len(sections) < 2:
        state.fail(
            f"{name}: expected at least 2 '## ' sections (metadata + description), "
            f"found {len(sections)}"
        )
        return

    metadata = sections[0]
    description = sections[1]

    rows = table_data_rows(metadata.body)
    if len(rows) < METADATA_ROW_MIN:
        state.fail(
            f"{name}: metadata table has {len(rows)} data rows, expected at least "
            f"{METADATA_ROW_MIN} (name, subtitle, promotional, support, marketing, keywords)"
        )
    else:
        for index, (field_name, limit) in LENGTH_CHECKS.items():
            cells = rows[index]
            if len(cells) < 2:
                state.fail(f"{name}: metadata row {index} ({field_name}) has no value cell")
                continue
            value = cells[1]
            length = len(value)
            if length > limit:
                state.fail(
                    f"{name}: {field_name} is {length} chars, exceeds {limit} "
                    f"(value: {value!r})"
                )

    description_length = len(description.body)
    if description_length == 0:
        state.fail(f"{name}: description section is empty")
    elif description_length > LIMIT_DESCRIPTION:
        state.fail(
            f"{name}: description is {description_length} chars, exceeds {LIMIT_DESCRIPTION}"
        )

    scan_forbidden_regions(path, name, text, state)


def scan_forbidden_regions(path: Path, name: str, text: str, state: CheckState) -> None:
    lines = text.splitlines()
    for term, pattern in FORBIDDEN_REGION_PATTERNS:
        for line_number, line in enumerate(lines, start=1):
            if pattern.search(line):
                state.fail(
                    f"{name}:{line_number}: forbidden CIS region name {term!r} in "
                    f"listing (availability must follow pricing-top20-aviation.md; no CIS)"
                )


def listing_paths(state: CheckState) -> list[Path]:
    listing_dir = ROOT / LISTING_DIR
    paths = sorted(listing_dir.glob("listing-*.md"))
    if not paths:
        state.fail(f"no App Store listing files found in {rel(listing_dir)}")
    return paths


def print_results(state: CheckState, checked: int) -> int:
    if state.failures:
        print("Listing metadata check failed:", file=sys.stderr)
        for failure in state.failures:
            print(f" - {failure}", file=sys.stderr)
        return 1
    print(f"Listing metadata checks passed ({checked} listing file(s)).")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate App Store listing metadata length limits and region policy"
    )
    parser.parse_args()

    state = CheckState()
    paths = listing_paths(state)
    for path in paths:
        check_listing(path, state)
    return print_results(state, len(paths))


if __name__ == "__main__":
    raise SystemExit(main())
