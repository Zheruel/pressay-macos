use crate::vocabulary::Entry;
pub const CLEANUP: &str = include_str!("prompts/cleanup.txt");
pub const MEETING: &str = include_str!("prompts/meeting.txt");
pub const USER_NOTES: &str = include_str!("prompts/user-notes.txt");
pub const ASK: &str = include_str!("prompts/ask.txt");
pub fn vocabulary_block(entries: &[Entry]) -> String {
    let mut ordered: Vec<(String, Vec<String>)> = vec![];
    for entry in entries {
        let preferred = entry.preferred.trim();
        if preferred.is_empty() {
            continue;
        }
        let index = if let Some(i) = ordered.iter().position(|(term, _)| term == preferred) {
            i
        } else {
            ordered.push((preferred.into(), vec![]));
            ordered.len() - 1
        };
        for alias in &entry.aliases {
            if !ordered[index].1.contains(alias) {
                ordered[index].1.push(alias.clone());
            }
        }
    }
    ordered
        .into_iter()
        .map(|(term, aliases)| {
            if aliases.is_empty() {
                term
            } else {
                format!("{} (may be transcribed as {})", term, aliases.join(", "))
            }
        })
        .collect::<Vec<_>>()
        .join("; ")
}
pub fn cleanup_system(entries: &[Entry]) -> String {
    let terms = vocabulary_block(entries);
    if terms.is_empty() {
        CLEANUP.into()
    } else {
        format!("{CLEANUP}\n\n<vocabulary>\nSpell these exactly when the speaker means them: {terms}\n</vocabulary>")
    }
}
pub fn cleanup_user(transcript: &str, app: Option<&str>) -> String {
    format!(
        "<app>{}</app>\n<transcript>\n{transcript}\n</transcript>",
        app_name(app)
    )
}
fn app_name(app: Option<&str>) -> String {
    let Some(id) = app else {
        return "unknown".into();
    };
    let name = match id {
        "com.anthropic.claudefordesktop" => Some("Claude"),
        "com.openai.chat" => Some("ChatGPT"),
        "com.openai.codex" => Some("Codex"),
        "com.t3tools.t3code" => Some("T3 Code (AI coding agent)"),
        "com.todesktop.230313mzl4w4u92" => Some("Cursor"),
        "com.microsoft.VSCode" => Some("VS Code"),
        "com.tinyspeck.slackmacgap" => Some("Slack"),
        "com.apple.MobileSMS" => Some("Messages"),
        "net.whatsapp.WhatsApp" => Some("WhatsApp"),
        "com.hnc.Discord" => Some("Discord"),
        "com.apple.mail" => Some("Mail"),
        "com.superhuman.electron" => Some("Superhuman (email)"),
        "com.apple.Notes" => Some("Notes"),
        "notion.id" => Some("Notion"),
        _ => None,
    };
    name.map(|name| format!("{name} ({id})"))
        .unwrap_or(id.into())
}
