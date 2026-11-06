//! Regression vectors from the shipping Swift text/phonetic test suites.
use super::*;
fn entries() -> Vec<Entry> {
    vocabulary::parse("Supabase\nGrokbot\nCodex\nScooper\nTailwind\nCognito\nDeepgram\nPolymarket\nRunPod <= rumpod\nCore ML\nClaude Code\nCLAUDE.md")
}
#[test]
fn deterministic_source_vectors_preserve_constraints_and_meaning() {
    for (source, expected) in [
        (
            "um implement the parser new paragraph bullet add tests",
            "Implement the parser\n\n• add tests",
        ),
        (
            "Keep the API stable. use JSON scratch that use SQLite",
            "Keep the API stable. use SQLite",
        ),
        (
            "Do not change the API and use JSON scratch that use SQLite",
            "Do not change the API and use SQLite",
        ),
        (
            "Do not change the API while trying JSON scratch that use SQLite",
            "Do not change the API while trying JSON scratch that use SQLite",
        ),
        (
            "WhisperKit WhisperKit with SwiftUI SwiftUI SwiftUI",
            "WhisperKit with SwiftUI",
        ),
        (
            "so that that one also gets it",
            "So that that one also gets it",
        ),
        (
            "we need some kind of plug-in system",
            "We need some kind of plug-in system",
        ),
        (
            "do you know if we should use it",
            "Do you know if we should use it",
        ),
    ] {
        assert_eq!(clean(source, &[], true, true, true), expected, "{source}");
    }
    for source in [
        "Explain the entropic force.",
        "Cloud code runs remotely.",
        "Kimmy is coming tomorrow.",
        "Send a slack message with the git hub link.",
    ] {
        assert_eq!(clean(source, &[], true, true, true), source);
    }
    assert_eq!(
        deterministic("cd superbase", &entries(), Some("cmd.exe"), Some("en")),
        "cd superbase"
    );
    let multilingual = "um nemoj promijeniti API, José: new line and scratch that remain literal";
    assert_eq!(clean(multilingual, &[], false, true, false), multilingual);
    assert!(!uses_english_rules(multilingual, Some("hr")));
    assert!(uses_english_rules("short", Some("en")));
    assert!(!uses_english_rules("", None));
}
#[test]
fn phonetic_source_vectors_correct_only_unambiguous_user_terms() {
    let entries = entries();
    for (source, expected) in [
        (
            "the data in Superbase is stale",
            "the data in Supabase is stale",
        ),
        ("I gave it to Grockpot.", "I gave it to Grokbot."),
        ("try DeepGrim instead", "try Deepgram instead"),
        ("Polymark, again", "Polymarket, again"),
        ("both PolyMarkets", "both Polymarkets"),
        ("ask codecs", "ask Codex"),
        ("ask Clotcode", "ask Claude Code"),
        ("ask Claudecode", "ask Claude Code"),
    ] {
        assert_eq!(phonetic_correct(source, &entries), expected, "{source}");
    }
    for source in [
        "search the codebase",
        "flights to Singapore",
        "caffeinate the Mac",
        "a toolkit for Trinidad",
        "the timeframe is fine",
        "Croatian food",
        "she went to Cornell",
        "Corman said",
        "SUPERBASE",
        "superbase.com",
        "me@superbase",
        "super-base",
        "superbase2",
        "src/superbase",
        "Superbase's",
        "e\u{301}Superbase and Superbase\u{301}x",
    ] {
        assert_eq!(phonetic_correct(source, &entries), source);
    }
    for word in [
        "mix",
        "mockups",
        "mockup",
        "correction",
        "colleagues",
        "darker",
        "cloned",
        "running",
        "redeploy",
        "preset",
    ] {
        assert!(!candidate(word), "{word}");
    }
    assert_eq!(
        phonetic_correct("Kimbul", &vocabulary::parse("Kimbal\nKimbel")),
        "Kimbul"
    );
    assert_eq!(
        phonetic_correct("Kimmy", &vocabulary::parse("Kimi")),
        "Kimmy"
    );
    assert_eq!(
        phonetic_correct("Superbase", &vocabulary::parse("Supabase\nsupabase")),
        "Supabase"
    );
}
