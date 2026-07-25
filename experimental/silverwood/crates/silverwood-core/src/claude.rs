//! Claude Code integration that lives *outside* the workstream document — locating
//! Claude's on-disk conversation history for a session. That transcript, not the
//! silverwood session record, is the ground truth for whether a claude-code session
//! can be `--resume`d: Claude writes it only after the first user message, so a
//! session that was created but never prompted has none, and resuming it fails.

use std::path::Path;

/// Whether Claude Code has ever persisted a conversation transcript for
/// `session_id` under `config_dir` (Claude's config dir, e.g. `~/.claude`).
///
/// Claude stores each session at
/// `<config_dir>/projects/<escaped-cwd>/<session_id>.jsonl` and only after its
/// first user message. We look by session id across *every* project dir rather
/// than reconstruct Claude's cwd→dir escaping: the id is a unique UUID, so a match
/// is unambiguous and version-independent, and this never reports "absent" for a
/// session that has any transcript on disk — so a caller that removes a session on
/// absence can never destroy real history. A missing `projects` dir reads as absent.
pub fn claude_conversation_exists(config_dir: &Path, session_id: &str) -> bool {
    let file = format!("{session_id}.jsonl");
    let Ok(entries) = std::fs::read_dir(config_dir.join("projects")) else {
        return false;
    };
    entries
        .flatten()
        .any(|entry| entry.path().join(&file).is_file())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_when_no_projects_dir() {
        let dir = tempfile::tempdir().unwrap();
        assert!(!claude_conversation_exists(dir.path(), "sess-1"));
    }

    #[test]
    fn absent_when_no_matching_transcript() {
        let dir = tempfile::tempdir().unwrap();
        let proj = dir.path().join("projects").join("-w-abc");
        std::fs::create_dir_all(&proj).unwrap();
        std::fs::write(proj.join("other.jsonl"), "").unwrap();
        assert!(!claude_conversation_exists(dir.path(), "sess-1"));
    }

    #[test]
    fn present_when_transcript_exists_in_any_project_dir() {
        let dir = tempfile::tempdir().unwrap();
        // A transcript filed under an unrelated escaped-cwd dir still matches:
        // glob-by-id doesn't depend on which project dir Claude chose.
        let proj = dir.path().join("projects").join("-somewhere-else");
        std::fs::create_dir_all(&proj).unwrap();
        std::fs::write(proj.join("sess-1.jsonl"), "{}\n").unwrap();
        assert!(claude_conversation_exists(dir.path(), "sess-1"));
    }
}
