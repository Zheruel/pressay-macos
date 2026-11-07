use super::{prompts, AiError, AiService, Connection, Provider, OPENAI_NOTES_MODEL};
use crate::vocabulary::Entry;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio_util::sync::CancellationToken;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NotesModel {
    ClaudeHaiku,
    ClaudeSonnet,
    OpenAi(String),
}
impl NotesModel {
    pub fn from_id(id: &str) -> Option<Self> {
        match id {
            "claude:haiku55" => Some(Self::ClaudeHaiku),
            "claude:sonnet55" => Some(Self::ClaudeSonnet),
            _ => id
                .strip_prefix("chatgpt:")
                .filter(|s| !s.is_empty())
                .map(|s| Self::OpenAi(s.into())),
        }
    }
    pub fn id(&self) -> String {
        match self {
            Self::ClaudeHaiku => "claude:haiku55".into(),
            Self::ClaudeSonnet => "claude:sonnet55".into(),
            Self::OpenAi(slug) => format!("chatgpt:{slug}"),
        }
    }
    pub fn slug(&self) -> &str {
        match self {
            Self::ClaudeHaiku => "claude-haiku-5-5",
            Self::ClaudeSonnet => "claude-sonnet-5-5",
            Self::OpenAi(slug) => slug,
        }
    }
    pub fn effort(&self) -> &'static str {
        if matches!(self, Self::ClaudeHaiku) {
            "low"
        } else {
            "medium"
        }
    }
    pub fn provider(&self) -> Provider {
        if matches!(self, Self::OpenAi(_)) {
            Provider::OpenAi
        } else {
            Provider::Claude
        }
    }
    pub fn options(claude: bool, openai: bool) -> Vec<Self> {
        let mut out = vec![];
        if claude {
            out.extend([Self::ClaudeHaiku, Self::ClaudeSonnet]);
        }
        if openai {
            out.extend([
                Self::OpenAi(OPENAI_NOTES_MODEL.into()),
                Self::OpenAi("gpt-6-luna".into()),
            ]);
        }
        out
    }
    pub fn resolve(
        stored: Option<&str>,
        prefer_openai: bool,
        claude: bool,
        openai: bool,
    ) -> Option<Self> {
        let options = Self::options(claude, openai);
        if let Some(model) = stored
            .and_then(Self::from_id)
            .filter(|m| options.contains(m))
        {
            return Some(model);
        }
        let recommended: Vec<_> = options
            .into_iter()
            .filter(|m| {
                matches!(m, Self::ClaudeHaiku) || m == &Self::OpenAi(OPENAI_NOTES_MODEL.into())
            })
            .collect();
        recommended
            .iter()
            .find(|m| (m.provider() == Provider::OpenAi) == prefer_openai)
            .cloned()
            .or_else(|| recommended.first().cloned())
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MeetingInput {
    pub duration_seconds: f64,
    pub transcript: String,
    pub user_notes: String,
    pub participants: Vec<String>,
    pub has_separated_voices: bool,
    pub line_count: usize,
    pub has_others: bool,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NoteDraft {
    pub title: String,
    pub body: String,
}
impl NoteDraft {
    pub fn parse(reply: &str) -> Result<Self, AiError> {
        let reply = reply.trim();
        let (first, body) = reply.split_once('\n').unwrap_or((reply, ""));
        let title = first
            .trim_matches(|c: char| c.is_whitespace() || "#*\"“”".contains(c))
            .trim_matches('.');
        if title.is_empty() {
            return Err(AiError::BadResponse);
        }
        if title.chars().count() > 80 || title.split(' ').filter(|s| !s.is_empty()).count() > 12 {
            let mut fallback = title
                .split_whitespace()
                .take(6)
                .collect::<Vec<_>>()
                .join(" ")
                .trim_matches(|c: char| !c.is_alphanumeric())
                .to_owned();
            if fallback.is_empty() {
                fallback = "Untitled note".into();
            }
            if title.split_whitespace().count() > 6 {
                fallback.push('…');
            }
            return Ok(Self {
                title: fallback,
                body: reply.into(),
            });
        }
        Ok(Self {
            title: title.into(),
            body: body.trim().into(),
        })
    }
}
pub fn meeting_prompts(input: &MeetingInput, vocabulary: &[Entry]) -> (String, String) {
    let mut system = prompts::MEETING.to_owned();
    if !input.user_notes.trim().is_empty() {
        system.push_str("\n\n");
        system.push_str(prompts::USER_NOTES);
    }
    system = system.replace("{vocab}", &prompts::vocabulary_block(vocabulary));
    let mut user = String::new();
    if input.has_separated_voices {
        user.push_str("The other people's voices were told apart automatically: each \"Speaker N\" is one voice, but a line is occasionally given to the wrong voice. A name in place of \"Speaker N\" was set by the user and is reliable.\n\n");
    }
    if input.line_count >= 10 && !input.has_others {
        user.push_str("No call audio was recorded: either the other people's side is missing (the long gaps are them talking) or they were in the room and are on the \"Me\" lines. Don't assume the user owns every task. A task the user asks or tells someone else to do is that person's, or \"owner unclear\" if they aren't named.\n\n");
    }
    if input.participants.len() == 1 {
        user.push_str(&format!(
            "The only other person on the call was {}: every \"Others\" line is them.\n\n",
            input.participants[0]
        ));
    } else if !input.participants.is_empty() {
        user.push_str(&format!("Others on the call (the user's spelling): {}. Name one only when the transcript shows it was them.\n\n",input.participants.join(", ")));
    }
    user.push_str(&format!(
        "<transcript>\n{}\n</transcript>",
        input.transcript
    ));
    if !input.user_notes.trim().is_empty() {
        user.push_str(&format!(
            "\n\n<my_notes>\n{}\n</my_notes>",
            input.user_notes.trim()
        ));
    }
    (system, user)
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AskMeeting {
    pub title: String,
    pub date: String,
    pub time: String,
    pub notes: String,
    pub my_notes: String,
    pub transcript: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Exchange {
    pub question: String,
    pub answer: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AskInput {
    pub question: String,
    pub meetings: Vec<AskMeeting>,
    pub history: Vec<Exchange>,
    pub today: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Answer {
    pub text: String,
}
pub fn ask_user(input: &AskInput, mut transcript_budget: usize) -> String {
    let mut blocks = vec![];
    for meeting in &input.meetings {
        let title = meeting.title.replace('"', "'").replace('<', "(");
        let mut block = format!(
            "<meeting title=\"{title}\" date=\"{}\" time=\"{}\">",
            meeting.date, meeting.time
        );
        for (tag, text) in [("notes", &meeting.notes), ("my_notes", &meeting.my_notes)] {
            if !text.is_empty() {
                block.push_str(&format!("\n<{tag}>\n{text}\n</{tag}>"));
            }
        }
        let count = meeting.transcript.chars().count();
        if count > 0 && count <= transcript_budget {
            transcript_budget -= count;
            block.push_str(&format!(
                "\n<transcript>\n{}\n</transcript>",
                meeting.transcript
            ));
        }
        block.push_str("\n</meeting>");
        blocks.push(block);
    }
    let mut prompt = format!("<today>{}</today>\n\n{}", input.today, blocks.join("\n\n"));
    if !input.history.is_empty() {
        prompt.push_str("\n\n<conversation>\n");
        prompt.push_str(
            &input
                .history
                .iter()
                .map(|e| {
                    format!(
                        "<asked>\n{}\n</asked>\n<answered>\n{}\n</answered>",
                        e.question, e.answer
                    )
                })
                .collect::<Vec<_>>()
                .join("\n"),
        );
        prompt.push_str("\n</conversation>");
    }
    prompt.push_str(&format!("\n\n<question>\n{}\n</question>", input.question));
    prompt
}
impl AiService {
    pub async fn write_note(
        &self,
        input: &MeetingInput,
        vocabulary: &[Entry],
        model: &NotesModel,
        connection: Connection,
        cancel: &CancellationToken,
    ) -> Result<NoteDraft, AiError> {
        if !input.duration_seconds.is_finite() || input.duration_seconds < 0.0 {
            return Err(AiError::BadResponse);
        }
        let timeout = Duration::try_from_secs_f64(90.0 + input.duration_seconds / 60.0)
            .map_err(|_| AiError::BadResponse)?;
        let (system, user) = meeting_prompts(input, vocabulary);
        let reply = self
            .complete(&system, &user, model, connection, timeout, cancel)
            .await?;
        NoteDraft::parse(&reply)
    }
    pub async fn ask(
        &self,
        input: &AskInput,
        model: &NotesModel,
        connection: Connection,
        cancel: &CancellationToken,
    ) -> Result<Answer, AiError> {
        if input.meetings.is_empty() {
            return Ok(Answer {
                text: "There are no meetings to search yet.".into(),
            });
        }
        let text = self
            .complete(
                prompts::ASK,
                &ask_user(input, 120_000),
                model,
                connection,
                Duration::from_secs(90),
                cancel,
            )
            .await?;
        Ok(Answer { text })
    }
}
