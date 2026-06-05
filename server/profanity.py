"""Profanity filter for VikingVale.

Two entry points:
    contains_profanity(text) -> bool      # used to reject account names
    censor(text) -> str                   # used on chat messages (keeps first letter)

Catches common bypasses: leetspeak substitution (@->a, 0->o, ...) and
spaced / punctuated letters (f u c k, f.u.c.k).  Edit BAD_WORDS to update.
"""

import re

# ── Word list (edit me) ──────────────────────────────────────────────────────
# Root forms only; the matcher already tolerates separators, repeats and leet.
BAD_WORDS = [
    "fuck", "shit", "bitch", "bastard", "asshole", "dick", "piss",
    "cunt", "cock", "pussy", "slut", "whore", "douche", "wank",
    "nigger", "nigga", "faggot", "fag", "retard", "spic", "chink",
    "kike", "wetback", "tranny", "coon", "dyke",
    "rape", "rapist", "molest", "nazi", "hitler",
]

# Leetspeak / look-alike substitutions mapped to their plain letter.
_LEET = {
    "@": "a", "4": "a", "8": "b", "(": "c", "3": "e", "6": "g",
    "1": "i", "!": "i", "|": "i", "0": "o", "$": "s", "5": "s",
    "7": "t", "+": "t", "2": "z",
}


def _normalize_char(ch: str) -> str:
    ch = ch.lower()
    return _LEET.get(ch, ch)


def _collapse(text: str) -> str:
    """Lowercase, apply leet map, drop everything that isn't a letter.

    Turns 'f.u_c k', 'Fuuuck', 'f@ck' into a comparable letter stream.
    Repeated letters are squeezed so 'fuuuck' -> 'fuck'.
    """
    out = []
    prev = ""
    for ch in text:
        n = _normalize_char(ch)
        if n.isalpha():
            if n != prev:
                out.append(n)
            prev = n
        else:
            prev = ""
    return "".join(out)


def contains_profanity(text: str) -> bool:
    if not text:
        return False
    collapsed = _collapse(text)
    return any(w in collapsed for w in BAD_WORDS)


# Per-word regex that allows separators/repeats/leet between the letters, so we
# can locate offending spans in the *original* string for censoring.
def _build_word_pattern(word: str) -> re.Pattern:
    parts = []
    for ch in word:
        variants = {ch}
        for leet, plain in _LEET.items():
            if plain == ch:
                variants.add(re.escape(leet))
        cls = "".join(sorted(variants))
        parts.append("[%s]+" % cls)
    # optional non-letter separators between each letter
    sep = r"[\W_]*"
    return re.compile(sep.join(parts), re.IGNORECASE)


_PATTERNS = [(w, _build_word_pattern(w)) for w in BAD_WORDS]


def censor(text: str) -> str:
    """Replace bad words with first letter + asterisks, e.g. 'f***'."""
    if not text:
        return text
    result = text
    for _word, pat in _PATTERNS:
        def _repl(m: re.Match) -> str:
            span = m.group(0)
            letters = [c for c in span if c.isalpha()]
            if not letters:
                return span
            return letters[0] + "*" * (len(letters) - 1)
        result = pat.sub(_repl, result)
    return result
