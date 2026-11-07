//! Targeted post-meeting corrections and evidence-backed speaker naming.
use super::{notes::NotesModel, prompts, AiError, AiService, Connection};
use crate::vocabulary::Entry;
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    time::Duration,
};
use tokio_util::sync::CancellationToken;
use unicode_normalization::{char::is_combining_mark, UnicodeNormalization};
pub const SYSTEM: &str = include_str!("prompts/review.txt");
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ReviewLine {
    pub text: String,
    pub voice: Option<u32>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ReviewInput {
    /// Plain transcript with original Speaker N labels, before user name substitutions.
    pub transcript: String,
    pub lines: Vec<ReviewLine>,
    pub participants: Vec<String>,
    pub duration_seconds: f64,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Fix {
    pub from: String,
    pub to: String,
}
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ReviewResult {
    pub names: BTreeMap<u32, String>,
    pub fixes: Vec<Fix>,
}
pub fn system(vocabulary: &[Entry]) -> String {
    SYSTEM.replace("{vocab}", &prompts::vocabulary_block(vocabulary))
}
pub fn user(input: &ReviewInput) -> String {
    let prefix = if input.participants.is_empty() {
        String::new()
    } else {
        format!(
            "The user says these people were on the call (their spelling): {}.\n\n",
            input.participants.join(", ")
        )
    };
    format!("{prefix}<transcript>\n{}\n</transcript>", input.transcript)
}
fn folded(text: &str) -> String {
    text.nfd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(char::to_lowercase)
        .collect()
}
fn occurrences(text: &str, phrase: &str) -> Vec<std::ops::Range<usize>> {
    if phrase.is_empty() {
        return vec![];
    }
    text.match_indices(phrase)
        .map(|(start, m)| start..start + m.len())
        .filter(|range| {
            let inside = |c: char| c.is_alphabetic() || c.is_numeric() || c == '\'';
            !text[..range.start].chars().next_back().is_some_and(inside)
                && !text[range.end..].chars().next().is_some_and(inside)
        })
        .collect()
}
/// Invalid or unsupported suggestions are omitted; malformed JSON is a no-op.
pub fn parse(reply: &str, lines: &[ReviewLine], participants: &[String]) -> ReviewResult {
    let mut result = ReviewResult::default();
    if reply.len() > 1024 * 1024 {
        return result;
    }
    let (Some(open), Some(close)) = (reply.find('{'), reply.rfind('}')) else {
        return result;
    };
    if open >= close {
        return result;
    }
    let Ok(object) = serde_json::from_str::<serde_json::Value>(&reply[open..=close]) else {
        return result;
    };
    let heard = lines
        .iter()
        .map(|line| line.text.as_str())
        .collect::<Vec<_>>()
        .join(" ");
    let heard_folded = folded(&heard);
    let voices: HashSet<_> = lines.iter().filter_map(|line| line.voice).collect();
    if let Some(names) = object["speakers"].as_object() {
        for (key, value) in names {
            let (Ok(number), Some(raw)) = (key.parse::<u32>(), value.as_str()) else {
                continue;
            };
            let name = raw.trim();
            if !voices.contains(&number) || name.is_empty() || name.chars().count() > 40 {
                continue;
            }
            if participants
                .iter()
                .any(|p| p.to_lowercase() == name.to_lowercase())
                || name
                    .split(' ')
                    .filter(|s| !s.is_empty())
                    .all(|part| heard_folded.contains(&folded(part)))
            {
                result.names.insert(number, name.into());
            }
        }
    }
    let mut counts = HashMap::new();
    for name in result.names.values() {
        *counts.entry(name.to_lowercase()).or_insert(0) += 1;
    }
    result
        .names
        .retain(|_, name| counts[&name.to_lowercase()] == 1);
    if let Some(fixes) = object["fixes"].as_array() {
        for fix in fixes.iter().take(40) {
            let (Some(from), Some(to)) = (fix["from"].as_str(), fix["to"].as_str()) else {
                continue;
            };
            let from = from.trim_matches(|c: char| c.is_whitespace() && c != '\n' && c != '\r');
            let to = to.trim_matches(|c: char| c.is_whitespace() && c != '\n' && c != '\r');
            if from.chars().count() < 2
                || to.is_empty()
                || from == to
                || to.chars().count() > from.chars().count() * 3 + 10
                || occurrences(&heard, from).is_empty()
            {
                continue;
            }
            result.fixes.push(Fix {
                from: from.into(),
                to: to.into(),
            });
        }
    }
    result
}
pub fn apply_fixes(text: &str, fixes: &[Fix]) -> String {
    let mut result = text.to_owned();
    for fix in fixes {
        for range in occurrences(&result, &fix.from).into_iter().rev() {
            result.replace_range(range, &fix.to);
        }
    }
    result
}
impl AiService {
    pub async fn review_transcript(
        &self,
        input: &ReviewInput,
        vocabulary: &[Entry],
        model: &NotesModel,
        connection: Connection,
        cancel: &CancellationToken,
    ) -> Result<ReviewResult, AiError> {
        if !input.duration_seconds.is_finite() || input.duration_seconds < 0.0 {
            return Err(AiError::BadResponse);
        }
        let timeout = Duration::try_from_secs_f64(60.0 + input.duration_seconds / 120.0)
            .map_err(|_| AiError::BadResponse)?;
        let reply = self
            .complete(
                &system(vocabulary),
                &user(input),
                model,
                connection,
                timeout,
                cancel,
            )
            .await?;
        Ok(parse(&reply, &input.lines, &input.participants))
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn review_only_names_existing_supported_unique_voices_and_exact_whole_words() {
        let lines = vec![
            ReviewLine {
                text: "Hi I'm Priya. Ask Sam about Kubernetis and Kubernetis2; also al.".into(),
                voice: Some(1),
            },
            ReviewLine {
                text: "Hello José".into(),
                voice: Some(2),
            },
        ];
        let reply = r#"```json
{"speakers":{"1":"Priya","2":"Jose","3":"Sam"},"fixes":[{"from":"Kubernetis","to":"Kubernetes"},{"from":"invented","to":"removed"},{"from":"al","to":"Al"}]}
```"#;
        let result = parse(reply, &lines, &[]);
        assert_eq!(result.names.get(&1).unwrap(), "Priya");
        assert_eq!(result.names.get(&2).unwrap(), "Jose");
        assert_eq!(result.names.len(), 2);
        assert_eq!(result.fixes.len(), 2);
        assert_eq!(
            apply_fixes(&lines[0].text, &result.fixes),
            "Hi I'm Priya. Ask Sam about Kubernetes and Kubernetis2; also Al."
        );
        assert!(
            parse(r#"{"speakers":{"1":"Priya","2":"Priya"}}"#, &lines, &[])
                .names
                .is_empty()
        );
        assert!(parse("not JSON", &lines, &[]).fixes.is_empty());
        let long = "word ".repeat(100_000);
        assert_eq!(occurrences(&long, long.trim_end()).len(), 1);
    }
}
