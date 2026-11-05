use regex::Regex;
use serde::{Deserialize, Serialize};
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub preferred: String,
    pub aliases: Vec<String>,
}
pub fn parse(source: &str) -> Vec<Entry> {
    source
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            let (preferred, aliases) = line.split_once("<=").unwrap_or((line, ""));
            let preferred = preferred.trim();
            if preferred.is_empty() {
                return None;
            }
            Some(Entry {
                preferred: preferred.into(),
                aliases: aliases
                    .split(',')
                    .map(str::trim)
                    .filter(|a| !a.is_empty())
                    .map(str::to_owned)
                    .collect(),
            })
        })
        .collect()
}
fn word(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}
/// Literal, Unicode-aware whole-term matching, preserving the shipping ordered
/// replacement policy. No stock vocabulary, fuzzy substitutions or learned guesses.
pub fn normalize(text: &str, entries: &[Entry]) -> String {
    let mut text = text.to_owned();
    for entry in entries {
        for candidate in entry
            .aliases
            .iter()
            .chain(std::iter::once(&entry.preferred))
        {
            if candidate.is_empty() {
                continue;
            }
            let regex =
                Regex::new(&format!("(?i){}", regex::escape(candidate))).expect("escaped term");
            let mut result = String::new();
            let mut end = 0;
            for m in regex.find_iter(&text) {
                if text[..m.start()].chars().next_back().is_some_and(word)
                    || text[m.end()..].chars().next().is_some_and(word)
                {
                    continue;
                }
                result.push_str(&text[end..m.start()]);
                result.push_str(&entry.preferred);
                end = m.end();
            }
            result.push_str(&text[end..]);
            text = result;
        }
    }
    text
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn manual_terms_are_literal_and_whole_words() {
        let e = parse("# comment\nSupabase <= super base\n$Repo <= repo\nC++ <= c plus plus\n");
        assert_eq!(
            normalize("super base repository repo c plus plus", &e),
            "Supabase repository $Repo C++"
        );
        assert_eq!(
            normalize("supabases _supabase supersupabase", &e),
            "supabases _supabase supersupabase"
        );
        assert_eq!(
            normalize("Some kind of plan, maybe.", &[]),
            "Some kind of plan, maybe."
        );
    }
}
