//! Persistent meeting content and task semantics shared by all desktop hosts.
use crate::{storage, Error, Result};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, HashSet},
    sync::OnceLock,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Speaker {
    Me,
    Others,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TranscriptLine {
    pub speaker: Speaker,
    pub start: f64,
    pub text: String,
    #[serde(default)]
    pub end: Option<f64>,
    #[serde(default)]
    pub voice: Option<u32>,
}
impl TranscriptLine {
    pub fn label(&self, names: &[String]) -> String {
        if self.speaker == Speaker::Me {
            return "Me".into();
        }
        if let Some(voice) = self.voice.filter(|v| *v > 0) {
            if let Some(name) = names
                .get(voice as usize - 1)
                .filter(|s| !s.trim().is_empty())
            {
                return name.clone();
            }
            return format!("Speaker {voice}");
        }
        "Others".into()
    }
    pub fn plain(&self, names: &[String]) -> String {
        format!(
            "[{}] {}: {}",
            timestamp(self.start),
            self.label(names),
            self.text
        )
    }
}
pub fn timestamp(seconds: f64) -> String {
    let seconds = seconds.max(0.) as u64;
    if seconds >= 3600 {
        format!(
            "{}:{:02}:{:02}",
            seconds / 3600,
            seconds / 60 % 60,
            seconds % 60
        )
    } else {
        format!("{}:{:02}", seconds / 60, seconds % 60)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Note {
    pub id: String,
    #[serde(default = "voice_kind")]
    pub kind: String,
    #[serde(default)]
    pub created_at: f64,
    #[serde(default)]
    pub updated_at: f64,
    pub title: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub transcripts: Vec<String>,
    #[serde(default)]
    pub edited: bool,
    #[serde(default)]
    pub lines: Vec<TranscriptLine>,
    #[serde(default)]
    pub duration: f64,
    #[serde(default, rename = "myNotes")]
    pub my_notes: String,
    #[serde(default, rename = "needsWriteUp")]
    pub needs_write_up: bool,
    #[serde(default)]
    pub participants: Vec<String>,
    #[serde(default, rename = "speakerNames")]
    pub speaker_names: Vec<String>,
    #[serde(default, rename = "sentToReminders")]
    pub sent_to_reminders: Vec<String>,
    #[serde(default)]
    pub interrupted: bool,
    #[serde(default)]
    pub notice: Option<String>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, Value>,
}
/// Matches the Swift decoder: notes saved without a kind are voice notes.
fn voice_kind() -> String {
    "voice".into()
}
impl Note {
    pub fn new(kind: &str) -> Self {
        let now = storage::now();
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            kind: kind.into(),
            created_at: now,
            updated_at: now,
            title: if kind == "voice" {
                "Voice note"
            } else {
                "New meeting"
            }
            .into(),
            body: String::new(),
            transcripts: vec![],
            edited: false,
            lines: vec![],
            duration: 0.,
            my_notes: String::new(),
            needs_write_up: false,
            participants: vec![],
            speaker_names: vec![],
            sent_to_reminders: vec![],
            interrupted: false,
            notice: None,
            extra: BTreeMap::new(),
        }
    }
    pub fn transcript(&self) -> String {
        if self.lines.is_empty() {
            self.transcripts.join("\n\n")
        } else {
            self.lines
                .iter()
                .map(|l| l.plain(&self.speaker_names))
                .collect::<Vec<_>>()
                .join("\n")
        }
    }
    pub fn add_line(&mut self, line: TranscriptLine) -> Result<()> {
        if !line.start.is_finite()
            || line.start < 0.
            || line.end.is_some_and(|e| !e.is_finite() || e < line.start)
            || line.text.trim().is_empty()
        {
            return Err(Error::Message("Invalid transcript segment".into()));
        }
        let i = self.lines.partition_point(|l| l.start <= line.start);
        self.lines.insert(i, line);
        self.updated_at = storage::now();
        self.needs_write_up = true;
        Ok(())
    }
    pub fn validate(&self) -> Result<()> {
        if self.id.is_empty()
            || !self.created_at.is_finite()
            || !self.updated_at.is_finite()
            || !self.duration.is_finite()
            || self.duration < 0.
            || !["voice", "meeting"].contains(&self.kind.as_str())
        {
            return Err(Error::Message("Invalid meeting data".into()));
        }
        for line in &self.lines {
            if !line.start.is_finite()
                || line.start < 0.
                || line.end.is_some_and(|e| !e.is_finite() || e < line.start)
            {
                return Err(Error::Message("Invalid transcript timing".into()));
            }
        }
        Ok(())
    }
    pub fn assign_voices(&mut self, segments: &[crate::analysis::SpeakerSegment]) {
        let owners: Vec<_> = self
            .lines
            .iter()
            .map(|line| {
                if line.speaker != Speaker::Others {
                    return None;
                }
                let end = line.end.unwrap_or(line.start + 3.).max(line.start + 0.5);
                let mut overlaps = BTreeMap::<u32, f64>::new();
                for segment in segments {
                    let length = end.min(segment.end) - line.start.max(segment.start);
                    if length > 0. {
                        *overlaps.entry(segment.speaker).or_default() += length;
                    }
                }
                overlaps
                    .into_iter()
                    .max_by(|(a, x), (b, y)| x.total_cmp(y).then_with(|| b.cmp(a)))
                    .map(|(voice, _)| voice)
            })
            .collect();
        let mut numbers = BTreeMap::new();
        for owner in owners.iter().flatten() {
            if !numbers.contains_key(owner) {
                numbers.insert(*owner, numbers.len() as u32 + 1);
            }
        }
        if numbers.len() < 2 {
            return;
        }
        for (line, owner) in self.lines.iter_mut().zip(owners) {
            line.voice = owner.and_then(|v| numbers.get(&v).copied());
        }
    }
    pub fn apply_patch(&mut self, patch: &Value) -> Result<()> {
        let object = patch
            .as_object()
            .ok_or_else(|| Error::Message("Invalid note edit".into()))?;
        for (key, value) in object {
            match key.as_str() {
                "title" => self.title = bounded_string(value, 200)?,
                "body" => {
                    self.body = bounded_string(value, 2_000_000)?;
                    self.edited = true;
                }
                "myNotes" => self.my_notes = bounded_string(value, 500_000)?,
                "participants" => self.participants = string_list(value, 100, 100)?,
                "speakerNames" => self.speaker_names = string_list(value, 4, 100)?,
                _ => return Err(Error::Message(format!("Unsupported note field: {key}"))),
            }
        }
        self.updated_at = storage::now();
        self.validate()
    }
    pub fn apply_write_up(
        &mut self,
        title: String,
        body: String,
        expected_body: &str,
    ) -> Result<()> {
        // A slow AI response cannot overwrite a hand edit made during the request.
        if self.body != expected_body {
            return Err(Error::Message(
                "The note changed during write-up; your edits were kept. Retry when ready.".into(),
            ));
        }
        self.title = title;
        self.body = ActionItem::carry_ticks(&self.body, &body);
        self.updated_at = storage::now();
        self.needs_write_up = false;
        self.edited = false;
        Ok(())
    }
}
fn bounded_string(value: &Value, max: usize) -> Result<String> {
    value
        .as_str()
        .filter(|s| s.len() <= max)
        .map(str::to_owned)
        .ok_or_else(|| Error::Message("Text is invalid or too long".into()))
}
fn string_list(value: &Value, max: usize, width: usize) -> Result<Vec<String>> {
    let list = value
        .as_array()
        .filter(|a| a.len() <= max)
        .ok_or_else(|| Error::Message("Invalid list".into()))?;
    list.iter().map(|s| bounded_string(s, width)).collect()
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ActionItem {
    pub line: usize,
    pub text: String,
    pub owner: Option<String>,
    pub done: bool,
}
fn task_pattern() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^(\s*[-*]\s+\[)([ xX])(\]\s+)(.+?)\s*$").unwrap())
}
fn owner_pattern() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\s*\(([^()]+)\)$").unwrap())
}
impl ActionItem {
    pub fn is_mine(&self) -> bool {
        self.owner
            .as_ref()
            .is_some_and(|v| v.eq_ignore_ascii_case("me"))
    }
    pub fn parse(markdown: &str) -> Vec<Self> {
        markdown
            .lines()
            .enumerate()
            .filter_map(|(line, raw)| {
                let c = task_pattern().captures(raw)?;
                let mut text = c[4].to_owned();
                let mut owner = None;
                if let Some(found) = owner_pattern().captures(&text) {
                    if is_owner(&found[1]) {
                        let name = found[1].to_owned();
                        let start = found.get(0).unwrap().start();
                        text.truncate(start);
                        if !name.eq_ignore_ascii_case("owner unclear") {
                            owner = Some(name);
                        }
                    }
                }
                Some(Self {
                    line,
                    text,
                    owner,
                    done: &c[2] != " ",
                })
            })
            .collect()
    }
    pub fn toggle(&self, markdown: &str) -> Result<String> {
        let current = Self::parse(markdown);
        let target = current
            .iter()
            .find(|t| t.line == self.line && t.text == self.text && t.owner == self.owner)
            .or_else(|| {
                current
                    .iter()
                    .find(|t| t.text == self.text && t.owner == self.owner)
            })
            .ok_or_else(|| {
                Error::Message("This action item changed. Refresh the note and try again.".into())
            })?;
        let mut lines: Vec<_> = markdown.split('\n').map(str::to_owned).collect();
        let c = task_pattern().captures(&lines[target.line]).unwrap();
        lines[target.line] = format!(
            "{}{}{}{}",
            &c[1],
            if target.done { " " } else { "x" },
            &c[3],
            &c[4]
        );
        Ok(lines.join("\n"))
    }
    pub fn carry_ticks(old: &str, new: &str) -> String {
        let done: HashSet<_> = Self::parse(old)
            .into_iter()
            .filter(|a| a.done)
            .map(|a| (words_key(&a.text), a.owner.map(|s| s.to_lowercase())))
            .collect();
        let mut result = new.to_owned();
        for item in Self::parse(new) {
            if !item.done
                && done.contains(&(
                    words_key(&item.text),
                    item.owner.as_ref().map(|s| s.to_lowercase()),
                ))
            {
                if let Ok(v) = item.toggle(&result) {
                    result = v;
                }
            }
        }
        result
    }
    pub fn was_sent(&self, sent: &[String]) -> bool {
        let mine = significant_words(&self.text);
        sent.iter().any(|s| {
            let other = significant_words(s);
            let total = mine.union(&other).count();
            total > 0 && mine.intersection(&other).count() as f64 / total as f64 >= 0.7
        })
    }
}
fn words_key(text: &str) -> String {
    text.to_lowercase()
        .split(|c: char| !c.is_alphanumeric())
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}
fn significant_words(text: &str) -> HashSet<String> {
    words_key(text)
        .split_whitespace()
        .filter(|s| {
            ![
                "the", "a", "an", "to", "and", "of", "for", "on", "in", "with", "by",
            ]
            .contains(s)
        })
        .map(str::to_owned)
        .collect()
}
fn is_owner(text: &str) -> bool {
    let lower = text.to_lowercase();
    if ["me", "owner unclear"].contains(&lower.as_str()) {
        return true;
    }
    let not_names = [
        "monday",
        "tuesday",
        "wednesday",
        "thursday",
        "friday",
        "saturday",
        "sunday",
        "today",
        "tomorrow",
        "january",
        "february",
        "march",
        "april",
        "may",
        "june",
        "july",
        "august",
        "september",
        "october",
        "november",
        "december",
        "eod",
        "asap",
        "optional",
        "tentative",
        "draft",
    ];
    text.chars().count() <= 40
        && text.split_whitespace().count() <= 4
        && text.chars().next().is_some_and(char::is_uppercase)
        && !text.chars().any(char::is_numeric)
        && !lower.split_whitespace().any(|w| not_names.contains(&w))
}
/// A portable calendar-task export. Platforms with native Reminders additionally
/// use their native adapter. UTF-8 bytes are folded without splitting codepoints.
pub fn calendar_tasks(note: &Note, items: &[ActionItem]) -> String {
    fn escape(s: &str) -> String {
        s.replace('\\', "\\\\")
            .replace('\r', "")
            .replace('\n', "\\n")
            .replace(';', "\\;")
            .replace(',', "\\,")
    }
    let mut lines = vec![
        "BEGIN:VCALENDAR".into(),
        "VERSION:2.0".into(),
        "PRODID:-//Pressay//Action Items//EN".into(),
    ];
    let timestamp = chrono::Utc::now().format("%Y%m%dT%H%M%SZ").to_string();
    for item in items {
        lines.extend([
            "BEGIN:VTODO".into(),
            format!("UID:{}-{}@pressay", note.id, item.line),
            format!("DTSTAMP:{timestamp}"),
            format!("SUMMARY:{}", escape(&item.text)),
            format!("DESCRIPTION:{}", escape(&format!("From {}", note.title))),
            format!(
                "STATUS:{}",
                if item.done {
                    "COMPLETED"
                } else {
                    "NEEDS-ACTION"
                }
            ),
            "END:VTODO".into(),
        ]);
    }
    lines.push("END:VCALENDAR".into());
    lines
        .into_iter()
        .map(|line| {
            let mut out = String::new();
            let mut count = 0;
            for c in line.chars() {
                if count + c.len_utf8() > 74 {
                    out.push_str("\r\n ");
                    count = 1;
                }
                out.push(c);
                count += c.len_utf8();
            }
            out
        })
        .collect::<Vec<_>>()
        .join("\r\n")
        + "\r\n"
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn action_owners_and_safe_toggles() {
        let source="- [ ] Ship patch (me)\n- [x] Review the patch (Sam)\n- [ ] Share report (Friday)\n- [ ] Keep draft (draft)";
        let items = ActionItem::parse(source);
        assert!(items[0].is_mine());
        assert_eq!(items[1].owner.as_deref(), Some("Sam"));
        assert_eq!(items[2].owner, None);
        assert!(items[0].toggle(source).unwrap().starts_with("- [x]"));
        assert_eq!(
            ActionItem::carry_ticks(source, "- [ ] Review the patch (me)"),
            "- [ ] Review the patch (me)"
        );
    }
    #[test]
    fn old_import_fields_survive_edits() {
        let value = serde_json::json!({"id":"old","title":"Original","createdAt":"2026-10-01T12:00:00Z","created_at":1234.,"unknown":{"keep":true},"speakerNames":["Sam"]});
        let mut n: Note = serde_json::from_value(value).unwrap();
        n.apply_patch(&serde_json::json!({"myNotes":"a detail"}))
            .unwrap();
        let v = serde_json::to_value(n).unwrap();
        assert_eq!(v["unknown"]["keep"], true);
        assert_eq!(v["createdAt"], "2026-10-01T12:00:00Z");
        assert_eq!(v["kind"], "voice", "Swift decodes a missing kind as voice");
    }
    #[test]
    fn slow_ai_cannot_overwrite_manual_edits() {
        let mut note = Note::new("meeting");
        note.body = "hand edited".into();
        assert!(note
            .apply_write_up("AI".into(), "rewrite".into(), "")
            .is_err());
        assert_eq!(note.body, "hand edited");
    }
    #[test]
    fn transcripts_sort_and_keep_roles() {
        let mut note = Note::new("meeting");
        for (start, speaker) in [(3., Speaker::Others), (1., Speaker::Me)] {
            note.add_line(TranscriptLine {
                speaker,
                start,
                end: Some(start + 1.),
                text: "Words".into(),
                voice: None,
            })
            .unwrap();
        }
        assert!(note.transcript().starts_with("[0:01] Me:"));
        assert!(note.transcript().contains("[0:03] Others:"));
    }
    fn remote(start: f64, end: Option<f64>) -> TranscriptLine {
        TranscriptLine {
            speaker: Speaker::Others,
            start,
            end,
            text: format!("Words at {start}"),
            voice: None,
        }
    }
    fn turn(start: f64, end: f64, speaker: u32) -> crate::analysis::SpeakerSegment {
        crate::analysis::SpeakerSegment {
            start,
            end,
            speaker,
            confidence: None,
        }
    }
    #[test]
    fn voice_numbers_follow_first_transcribed_appearance_and_preserve_me() {
        let mut n = Note::new("meeting");
        n.add_line(remote(0., Some(2.))).unwrap();
        n.add_line(TranscriptLine {
            speaker: Speaker::Me,
            start: 1.,
            end: Some(2.),
            text: "My words".into(),
            voice: None,
        })
        .unwrap();
        n.add_line(remote(3., Some(5.))).unwrap();
        n.add_line(remote(6., Some(7.))).unwrap();
        n.add_line(remote(10., Some(11.))).unwrap();
        n.assign_voices(&[
            turn(0., 2., 4),
            turn(3., 5., 2),
            turn(6., 6.5, 4),
            turn(6.5, 7., 2),
        ]);
        assert_eq!(
            n.lines.iter().map(|l| l.voice).collect::<Vec<_>>(),
            vec![Some(1), None, Some(2), Some(2), None]
        );
        assert_eq!(n.lines[1].label(&[]), "Me");
        assert_eq!(n.lines[0].label(&["Sam".into(), "Pat".into()]), "Sam");
        assert_eq!(n.lines[2].label(&["Sam".into(), "Pat".into()]), "Pat");
    }
    #[test]
    fn a_second_voice_without_transcript_lines_does_not_number_a_lone_speaker() {
        let mut n = Note::new("meeting");
        n.add_line(remote(0., Some(2.))).unwrap();
        n.assign_voices(&[turn(0., 2., 4), turn(100., 101., 2)]);
        assert_eq!(n.lines[0].voice, None);
        assert_eq!(n.lines[0].label(&[]), "Others");
    }
    #[test]
    fn legacy_missing_end_and_short_lines_use_shipping_overlap_window() {
        let mut n = Note::new("meeting");
        n.add_line(remote(0., None)).unwrap();
        n.add_line(remote(4., Some(4.1))).unwrap();
        n.assign_voices(&[turn(1.5, 2.5, 4), turn(4.2, 4.4, 2)]);
        assert_eq!(n.lines[0].voice, Some(1));
        assert_eq!(n.lines[1].voice, Some(2));
    }
    #[test]
    fn majority_voice_sums_multiple_turns_and_does_not_change_transcript_content() {
        let mut n = Note::new("meeting");
        n.add_line(remote(0., Some(5.))).unwrap();
        n.add_line(remote(6., Some(7.))).unwrap();
        let original: Vec<_> = n
            .lines
            .iter()
            .map(|line| (line.start, line.end, line.text.clone()))
            .collect();
        n.assign_voices(&[
            turn(0., 1.5, 4),
            turn(1.5, 3.5, 2),
            turn(3.5, 5., 4),
            turn(6., 7., 2),
        ]);
        assert_eq!(
            n.lines.iter().map(|line| line.voice).collect::<Vec<_>>(),
            vec![Some(1), Some(2)]
        );
        assert_eq!(
            n.lines
                .iter()
                .map(|line| (line.start, line.end, line.text.clone()))
                .collect::<Vec<_>>(),
            original
        );
    }
}
