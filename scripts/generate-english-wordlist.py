#!/usr/bin/env python3
"""Regenerates Sources/PressayCore/EnglishWordList.swift.

The vocabulary tuner must never auto-rewrite ordinary English, so the stop
list needs broad coverage. The list is the union of:

  1. the words already in EnglishWordList.swift (function-word core and the
     original macOS-dictionary seed),
  2. the top-N most frequent English words (wordfreq) that also appear as
     lowercase entries in /usr/share/dict/words — the intersection keeps
     web-frequency artifacts ("tldr") and dictionary rarities ("absquatulate")
     out, so genuine mishearing candidates like "entropic" or "rumpod" stay
     eligible,
  3. a manual supplement for gaps in both sources.

Requires the `wordfreq` package:  python3 -m pip install wordfreq
Run from the repo root:  python3 scripts/generate-english-wordlist.py
"""

import re
import sys
from pathlib import Path

try:
    import wordfreq
except ImportError:
    sys.exit("wordfreq is required: python3 -m pip install wordfreq")

REPO = Path(__file__).resolve().parent.parent
SWIFT_FILE = REPO / "Sources/PressayCore/EnglishWordList.swift"
CURATED_FILE = REPO / "Sources/PressayCore/CuratedVocabulary.swift"
SYSTEM_DICT = Path("/usr/share/dict/words")
TOP_N = 25_000

# Common words absent from both the system dictionary and the frequency cut.
SUPPLEMENT = {"mockup", "mockups"}

HEADER = '''import Foundation

/// Common English lemmas the vocabulary tuner uses as a stop list. Generated
/// by scripts/generate-english-wordlist.py: the original function-word core
/// plus the top-{top_n} wordfreq lemmas intersected with the macOS system
/// dictionary. Regenerate with the script; do not edit by hand.
enum EnglishWordList {{
    static func contains(_ word: String) -> Bool {{
        if words.contains(word) {{ return true }}
        for suffix in ["'s", "es", "s", "ing", "ed"] where word.hasSuffix(suffix) {{
            if words.contains(String(word.dropLast(suffix.count))) {{ return true }}
        }}
        return false
    }}

    private static let words: Set<String> = Set("""
{body}
""".split(separator: "\\n").map(String.init))
}}
'''


def existing_words() -> set[str]:
    text = SWIFT_FILE.read_text()
    match = re.search(r'Set\("""\n(.*?)\n"""', text, re.DOTALL)
    if not match:
        sys.exit("could not parse the existing word list")
    return {line.strip() for line in match.group(1).splitlines() if line.strip()}


def system_dictionary() -> set[str]:
    return {
        word
        for word in SYSTEM_DICT.read_text().splitlines()
        if word and word.isascii() and word.isalpha() and word.islower()
    }


def curated_tokens() -> set[str]:
    text = CURATED_FILE.read_text()
    return {token.lower() for token in re.findall(r"[A-Za-z]{3,}", text)}


def main() -> None:
    core = existing_words()
    system = system_dictionary()
    frequent = {
        word
        for word in wordfreq.top_n_list("en", TOP_N)
        if len(word) >= 3 and word.isascii() and word.isalpha() and word in system
    }
    combined = core | frequent | SUPPLEMENT

    overlaps = sorted(combined & curated_tokens())
    print(f"core {len(core)}, frequency-intersection {len(frequent)}, "
          f"total {len(combined)}")
    print(f"overlap with curated vocabulary tokens (review only, kept): "
          f"{', '.join(overlaps)}")

    for probe in ("mix", "correction", "colleague", "mockup", "mockups"):
        assert probe in combined, f"expected {probe!r} in the list"
    for probe in ("entropic", "rumpod", "tldr", "whisperflow", "soonercloud"):
        assert probe not in combined, f"did not expect {probe!r} in the list"

    body = "\n".join(sorted(combined))
    SWIFT_FILE.write_text(HEADER.format(top_n=TOP_N, body=body))
    print(f"wrote {SWIFT_FILE} ({len(combined)} words)")


if __name__ == "__main__":
    main()
