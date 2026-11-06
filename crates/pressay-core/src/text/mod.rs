//! Shipping deterministic dictation rules, with a portable language detector.
//! Explicit non-English hints and uncertain language detection disable English
//! filler, correction-command and phonetic rules. Vocabulary remains user-owned.
use crate::vocabulary::{self, Entry};
use regex::Regex;
use std::{collections::HashSet, sync::OnceLock};
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};

pub fn is_terminal(app: Option<&str>) -> bool {
    let app = app.unwrap_or("").to_lowercase();
    [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.warp-stable",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "windowsterminal.exe",
        "powershell.exe",
        "pwsh.exe",
        "cmd.exe",
        "gnome-terminal",
        "konsole",
        "alacritty",
        "kitty",
        "wezterm",
        "ghostty",
        "foot",
        "xterm",
    ]
    .contains(&app.as_str())
}

pub fn uses_english_rules(text: &str, language_hint: Option<&str>) -> bool {
    if let Some(hint) = language_hint.filter(|hint| !matches!(*hint, "auto" | "")) {
        return matches!(hint, "en" | "english" | "English");
    }
    whatlang::detect(text)
        .is_some_and(|info| info.lang() == whatlang::Lang::Eng && info.confidence() >= 0.8)
}

pub fn clean(
    source: &str,
    entries: &[Entry],
    capitalize: bool,
    phonetic: bool,
    english: bool,
) -> String {
    let mut text = source.to_owned();
    if english {
        text = spoken_formatting(&text);
        text = scratch_that(&text);
        let filler = Regex::new(r"(?i)(^|[\s,])(um+|uh+|erm+)").unwrap();
        // The right delimiter is inspected rather than consumed: adjacent fillers
        // still match, and "umbrella"/"uhuru" remain intact.
        let mut edits = vec![];
        for cap in filler.captures_iter(&text) {
            let m = cap.get(0).unwrap();
            if text[m.end()..]
                .chars()
                .next()
                .is_none_or(|c| c.is_whitespace() || c == ',')
            {
                edits.push((m.range(), cap[1].to_owned()));
            }
        }
        for (range, replacement) in edits.into_iter().rev() {
            text.replace_range(range, &replacement);
        }
        text = stutters(&text);
    }
    text = vocabulary::normalize(&text, entries);
    if phonetic && english {
        text = phonetic_correct(&text, entries);
    }
    for (pattern, replacement) in [(r"[ \t]{2,}", " "), (r" *\n *", "\n"), (r"\n{3,}", "\n\n")] {
        text = Regex::new(pattern)
            .unwrap()
            .replace_all(&text, replacement)
            .into_owned();
    }
    text = text.trim().to_owned();
    if capitalize {
        if let Some(first) = text
            .chars()
            .next()
            .filter(|c| c.is_alphabetic() && c.is_lowercase())
        {
            text.replace_range(..first.len_utf8(), &first.to_uppercase().to_string());
        }
    }
    text
}

pub fn deterministic(
    source: &str,
    entries: &[Entry],
    app: Option<&str>,
    language: Option<&str>,
) -> String {
    let terminal = is_terminal(app);
    clean(
        source,
        entries,
        !terminal,
        !terminal,
        uses_english_rules(source, language),
    )
}

pub fn spoken_formatting(source: &str) -> String {
    let mut text = source.to_owned();
    for (spoken, rendered) in [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("bullet point", "\n• "),
        ("bullet", "\n• "),
        ("open quote", "\""),
        ("close quote", "\""),
        ("open parenthesis", "("),
        ("close parenthesis", ")"),
        ("colon", ":"),
        ("semicolon", ";"),
    ] {
        text = Regex::new(&format!(r"(?i)\b{}\b", regex::escape(spoken)))
            .unwrap()
            .replace_all(&text, rendered)
            .into_owned();
    }
    text.replace(" \n", "\n").replace("\n ", "\n")
}

fn stutters(text: &str) -> String {
    const KEEP: &[&str] = &[
        "that", "had", "has", "is", "do", "no", "so", "can", "the", "a", "in", "it", "you", "we",
        "i", "very", "really",
    ];
    let words = Regex::new(r"\b[\w'-]{2,}\b").unwrap();
    let matches: Vec<_> = words.find_iter(text).collect();
    let mut edits = vec![];
    let mut i = 0;
    while i < matches.len() {
        let first = matches[i];
        let lower = first.as_str().to_lowercase();
        let mut last = i;
        while last + 1 < matches.len()
            && matches[last + 1].as_str().to_lowercase() == lower
            && !text[matches[last].end()..matches[last + 1].start()].is_empty()
            && text[matches[last].end()..matches[last + 1].start()]
                .chars()
                .all(char::is_whitespace)
        {
            last += 1;
        }
        if last > i && !KEEP.contains(&lower.as_str()) {
            edits.push((first.end()..matches[last].end(), ""));
        }
        i = last + 1;
    }
    let mut result = text.to_owned();
    for (range, replacement) in edits.into_iter().rev() {
        result.replace_range(range, replacement);
    }
    result
}

fn scratch_that(text: &str) -> String {
    let marker = Regex::new("(?i)scratch that").unwrap();
    let Some(found) = marker.find_iter(text).last() else {
        return text.into();
    };
    let (prefix, suffix) = (&text[..found.start()], &text[found.end()..]);
    if let Some((i, c)) = prefix
        .char_indices()
        .rev()
        .find(|(_, c)| ".!?;\n".contains(*c))
    {
        return format!("{}{}", &prefix[..i + c.len_utf8()], suffix);
    }
    if let Some(connector) = Regex::new(r"(?i)\b(and|but|then)\b")
        .unwrap()
        .find_iter(prefix)
        .last()
    {
        let first = |s: &str| {
            s.split(|c: char| !c.is_alphanumeric())
                .find(|s| !s.is_empty())
                .map(str::to_lowercase)
        };
        if first(&prefix[connector.end()..]) == first(suffix) {
            return format!("{} {}", &prefix[..connector.end()], suffix);
        }
    }
    if !protected_tokens(prefix, &[]).is_empty() {
        text.into()
    } else {
        suffix.into()
    }
}

pub fn protected_tokens(text: &str, vocabulary: &[String]) -> Vec<String> {
    let mut tokens: HashSet<String> = vocabulary
        .iter()
        .filter(|term| folded(text).contains(&folded(term)))
        .cloned()
        .collect();
    for pattern in [
        r"https?://[^\s]+",
        r"\b\d+(?:[.,:]\d+)*(?:%|ms|s|GB|MB|KB|B)?\b",
        r"\b[A-Za-z]+(?:[_-][A-Za-z0-9]+)+\b",
        r"\b[a-z]+[A-Z][A-Za-z0-9]*\b",
        r"\b[A-Z]{2,}[A-Z0-9]*\b",
        r"\b[A-Z]\d+\b",
        r"(?i)\b(no|not|never|without|don't|doesn't|didn't|can't|cannot|won't|shouldn't|mustn't)\b",
    ] {
        tokens.extend(
            Regex::new(pattern)
                .unwrap()
                .find_iter(text)
                .map(|m| {
                    m.as_str()
                        .trim_matches(|c: char| !c.is_alphanumeric() && c != '\'')
                        .to_owned()
                })
                .filter(|s| !s.is_empty()),
        );
    }
    let mut tokens: Vec<_> = tokens.into_iter().collect();
    tokens.sort();
    tokens
}

fn folded(text: &str) -> String {
    text.nfd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
        .collect()
}

pub fn phonetic_key(phrase: &str) -> String {
    phrase
        .split(|c: char| !c.is_alphabetic())
        .filter(|w| !w.is_empty())
        .map(|word| {
            let letters: Vec<_> = word.to_lowercase().chars().collect();
            let mut out = letters[0].to_uppercase().to_string();
            let mut i = 1;
            while i < letters.len() {
                let pair: String = letters[i..(i + 2).min(letters.len())].iter().collect();
                let digraph = match pair.as_str() {
                    "ph" => Some('F'),
                    "th" => Some('T'),
                    "sh" => Some('X'),
                    "ch" | "ck" => Some('K'),
                    _ => None,
                };
                if let Some(c) = digraph {
                    out.push(c);
                    i += 2;
                    continue;
                }
                match letters[i] {
                    'a' | 'e' | 'i' | 'o' | 'u' | 'y' | 'w' | 'h' => {}
                    'x' => out.push_str("KS"),
                    'z' => out.push('S'),
                    'q' | 'g' | 'c' => out.push('K'),
                    'd' => out.push('T'),
                    'v' => out.push('F'),
                    c => out.extend(c.to_uppercase()),
                }
                i += 1;
            }
            let mut dedup = String::new();
            for c in out.chars() {
                if !dedup.ends_with(c) {
                    dedup.push(c);
                }
            }
            dedup
        })
        .collect()
}
fn distance(a: &str, b: &str) -> usize {
    let b: Vec<_> = b.chars().collect();
    let mut row: Vec<_> = (0..=b.len()).collect();
    for (i, x) in a.chars().enumerate() {
        let mut old = row[0];
        row[0] = i + 1;
        for (j, y) in b.iter().enumerate() {
            let prev = row[j + 1];
            row[j + 1] = (old + usize::from(x != *y)).min(row[j] + 1).min(prev + 1);
            old = prev;
        }
    }
    row[b.len()]
}
fn english_word(word: &str) -> bool {
    static WORDS: OnceLock<HashSet<&'static str>> = OnceLock::new();
    let words = WORDS.get_or_init(|| include_str!("english-words.txt").lines().collect());
    words.contains(word)
        || ["'s", "es", "s", "ing", "ed"].iter().any(|suffix| {
            word.strip_suffix(suffix)
                .is_some_and(|stem| words.contains(stem))
        })
}
fn suffix_stem(word: &str) -> bool {
    for suffix in ["s", "es", "d", "ed", "ing", "er", "est", "ly"] {
        if let Some(stem) = word.strip_suffix(suffix).filter(|s| s.chars().count() >= 3) {
            if english_word(stem) || english_word(&format!("{stem}e")) {
                return true;
            }
            let mut chars = stem.chars().rev();
            let last = chars.next();
            if stem.chars().count() >= 4
                && last == chars.next()
                && english_word(&stem[..stem.len() - last.unwrap().len_utf8()])
            {
                return true;
            }
        }
    }
    ["ies", "ied"].iter().any(|suffix| {
        word.strip_suffix(suffix)
            .filter(|s| s.chars().count() >= 2)
            .is_some_and(|stem| english_word(&format!("{stem}y")))
    })
}
fn candidate(word: &str) -> bool {
    !english_word(word)
        && !suffix_stem(word)
        && ![
            "re", "un", "pre", "mis", "over", "under", "sub", "non", "de",
        ]
        .iter()
        .any(|prefix| {
            word.strip_prefix(prefix)
                .filter(|s| s.chars().count() >= 3)
                .is_some_and(|s| english_word(s) || suffix_stem(s))
        })
}
fn letters(text: &str) -> String {
    text.chars()
        .flat_map(char::to_lowercase)
        .filter(|c| c.is_alphabetic())
        .collect()
}
fn onset(text: &str) -> String {
    let mut chars: Vec<_> = text.chars().collect();
    if chars.len() > 2 && chars[..2] == ['w', 'h'] {
        chars.remove(1);
    }
    if chars.is_empty() {
        return String::new();
    }
    format!(
        "{}{}",
        if "aeiou".contains(chars[0]) {
            '*'
        } else {
            chars[0]
        },
        chars.get(1).map(char::to_string).unwrap_or_default()
    )
}
pub fn phonetic_correct(text: &str, entries: &[Entry]) -> String {
    let known: HashSet<_> = entries
        .iter()
        .flat_map(|e| e.aliases.iter().chain(std::iter::once(&e.preferred)))
        .map(|s| s.to_lowercase())
        .collect();
    let mut seen = HashSet::new();
    let anchors: Vec<_> = entries
        .iter()
        .filter_map(|e| {
            if e.preferred.contains(['.', ';', '/']) || !seen.insert(e.preferred.to_lowercase()) {
                return None;
            }
            let key = phonetic_key(&letters(&e.preferred));
            if key.chars().count() < 4 {
                return None;
            }
            let exact = e.preferred.contains(' ')
                || e.preferred
                    .split(|c: char| !c.is_alphabetic())
                    .any(|w| w.chars().count() > 1 && w == w.to_uppercase());
            Some((&e.preferred, key, exact))
        })
        .collect();
    let words = Regex::new(r"\p{L}{3,}").unwrap();
    let mut result = text.to_owned();
    for m in words.find_iter(text).collect::<Vec<_>>().into_iter().rev() {
        let boundary =
            |c: char| c.is_alphanumeric() || is_combining_mark(c) || "_/@'’-".contains(c);
        if text[..m.start()]
            .chars()
            .next_back()
            .is_some_and(|c| boundary(c) || c == '.')
            || text[m.end()..].chars().next().is_some_and(boundary)
            || text[m.end()..]
                .strip_prefix('.')
                .is_some_and(|s| s.chars().next().is_some_and(char::is_alphabetic))
        {
            continue;
        }
        let word = m.as_str();
        let lower = word.to_lowercase();
        if known.contains(&lower) || word == word.to_uppercase() || !candidate(&lower) {
            continue;
        }
        let key = phonetic_key(word);
        if key.chars().count() < 4 {
            continue;
        }
        let heard = letters(word);
        let mut best: Option<(&String, usize)> = None;
        let mut tied = false;
        for (term, anchor_key, exact) in &anchors {
            let anchor = letters(term);
            if onset(&heard) != onset(&anchor)
                || heard.chars().count().abs_diff(anchor.chars().count()) > 2
            {
                continue;
            }
            let d = distance(&key, anchor_key);
            if d > usize::from(!exact) {
                continue;
            }
            match best {
                Some((_, old)) if d > old => {}
                Some((_, old)) if d == old => tied = true,
                _ => {
                    best = Some((term, d));
                    tied = false;
                }
            }
        }
        if let Some((term, d)) = best.filter(|_| !tied) {
            let replacement = if lower.ends_with('s')
                && !term.to_lowercase().ends_with(['s', 'x', 'z'])
                && distance(
                    &phonetic_key(&word[..word.len() - 1]),
                    &phonetic_key(&letters(term)),
                ) < d
            {
                format!("{term}s")
            } else {
                term.clone()
            };
            result.replace_range(m.range(), &replacement);
        }
    }
    result
}

#[cfg(test)]
mod tests;
