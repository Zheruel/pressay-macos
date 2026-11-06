"use strict";
let selectedNote = null,
  noteTab = "summary",
  noteEditing = false,
  noteVersion = "",
  historyKey = "",
  notesKey = "",
  workspaceReady = false,
  accountInfo = null,
  askIds = [],
  exchanges = [],
  askBusy = false;
const pendingNotes = new Set();
function button(text, action, className) {
  const b = element("button", text, className);
  b.onclick = () =>
    Promise.resolve()
      .then(action)
      .catch(() => {});
  return b;
}
function clockText(seconds) {
  const s = Math.max(0, Math.floor(seconds || 0));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}
function localDay(d) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}
function renderStats(history) {
  const today = new Date();
  const week = new Date(
    today.getFullYear(),
    today.getMonth(),
    today.getDate() - 6,
  ).getTime();
  let words = 0,
    speaking = 0;
  const days = new Set();
  for (const r of history) {
    const d = new Date(r.created_at * 1000);
    days.add(localDay(d));
    if (d.getTime() >= week) {
      words += (r.correction || r.text)
        .trim()
        .split(/\s+/u)
        .filter(Boolean).length;
      speaking += r.duration;
    }
  }
  $("wpm").textContent =
    speaking >= 30 ? Math.round((words * 60) / speaking) : "—";
  $("saved-time").textContent =
    `${Math.max(0, Math.round(words / 40 - speaking / 60))} min`;
  let cursor = new Date(today.getFullYear(), today.getMonth(), today.getDate()),
    streak = 0;
  if (!days.has(localDay(cursor))) cursor.setDate(cursor.getDate() - 1);
  while (days.has(localDay(cursor))) {
    streak++;
    cursor.setDate(cursor.getDate() - 1);
  }
  $("streak").textContent = `${streak} ${streak === 1 ? "day" : "days"}`;
}
function renderHistory(s) {
  const query = $("history-search").value.toLocaleLowerCase();
  const pinned = $("history-pinned").checked;
  const key = JSON.stringify([s.history, query, pinned]);
  if (key === historyKey) return;
  historyKey = key;
  $("history").replaceChildren();
  const records = s.history.filter(
    (r) =>
      (!pinned || r.pinned) &&
      `${r.text} ${r.correction || ""} ${r.raw}`
        .toLocaleLowerCase()
        .includes(query),
  );
  if (!records.length)
    $("history").append(
      element(
        "div",
        query || pinned
          ? "No dictations match these filters."
          : "Your first dictation will appear here.",
        "empty",
      ),
    );
  for (const r of records) {
    const article = element("article");
    const text = element("p", r.correction || r.text);
    article.append(text);
    if (r.correction || r.raw !== r.text) {
      const details = element("details");
      details.append(
        element("summary", "Original transcription"),
        element("p", r.raw),
      );
      article.append(details);
    }
    const row = element("div", undefined, "row");
    row.append(
      element(
        "small",
        `${new Date(r.created_at * 1000).toLocaleString()} · ${r.model} · ${clockText(r.duration)}${r.correction ? " · Corrected" : ""}`,
      ),
    );
    const actions = element("div", undefined, "button-group");
    const pasteStatus = element("small", "");
    pasteStatus.setAttribute("role", "status");
    article.append(pasteStatus);
    actions.append(
      button("Paste Again", async () => {
        pasteStatus.textContent = "Returning to the original application…";
        try {
          pasteStatus.textContent = await call("retry_dictation", { id: r.id });
        } catch (e) {
          pasteStatus.textContent = String(e);
        }
      }),
      button("Copy", () => call("copy_text", { text: r.correction || r.text })),
      button(r.pinned ? "Unpin" : "Pin", () =>
        call("edit_dictation", {
          id: r.id,
          pinned: !r.pinned,
          correction: null,
        }),
      ),
      button("Correct", () => {
        const edit = element("textarea");
        edit.value = r.correction || r.text;
        edit.rows = 4;
        edit.setAttribute("aria-label", "Correct dictation");
        text.replaceWith(edit);
        const save = button(
          "Save correction",
          () =>
            call("edit_dictation", {
              id: r.id,
              correction: edit.value,
              pinned: null,
            }),
          "primary",
        );
        actions.replaceChildren(
          save,
          button("Cancel", () => {
            historyKey = "";
            renderHistory(current.view);
          }),
        );
        edit.focus();
      }),
    );
    if (r.legacy?.managedAudio)
      actions.append(
        button("Listen", async () => {
          const base64 = await call("recording", { id: r.id });
          const data = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
          const url = URL.createObjectURL(
            new Blob([data], { type: "audio/wav" }),
          );
          const audio = document.createElement("audio");
          audio.controls = true;
          audio.src = url;
          audio.onended = () => URL.revokeObjectURL(url);
          article.append(audio);
          await audio.play();
        }),
      );
    actions.append(
      button("Delete", () => call("delete_dictation", { id: r.id })),
    );
    row.append(actions);
    article.append(row);
    $("history").append(article);
  }
}
function renderMarkdown(source, container, note) {
  container.replaceChildren();
  let code = null;
  source.split("\n").forEach((line, index) => {
    if (line.startsWith("```")) {
      if (code) code = null;
      else {
        code = element("pre");
        container.append(code);
      }
      return;
    }
    if (code) {
      code.append(document.createTextNode(line + "\n"));
      return;
    }
    const task = note?.actions?.find((t) => t.line === index);
    if (task) {
      const row = element("label", undefined, "action-item");
      const checkbox = element("input");
      checkbox.type = "checkbox";
      checkbox.checked = task.done;
      checkbox.onchange = () =>
        call("toggle_action", { id: note.id, item: task }).catch(
          () => (checkbox.checked = task.done),
        );
      row.append(checkbox, element("span", task.text));
      if (task.owner) row.append(element("small", task.owner, "owner"));
      container.append(row);
      return;
    }
    const heading = line.match(/^(#{1,4})\s+(.+)$/u);
    if (heading) {
      container.append(
        element(`h${Math.min(heading[1].length + 1, 5)}`, heading[2]),
      );
      return;
    }
    if (!line.trim()) return;
    const p = element(
      "p",
      undefined,
      /^[-*]\s/u.test(line) ? "markdown-list" : "",
    );
    // Inline strong/code are built as text nodes; provider content is never HTML.
    const parts = line.split(/(\*\*[^*]+\*\*|`[^`]+`)/gu);
    for (const part of parts) {
      if (part.startsWith("**") && part.endsWith("**"))
        p.append(element("strong", part.slice(2, -2)));
      else if (part.startsWith("`") && part.endsWith("`"))
        p.append(element("code", part.slice(1, -1)));
      else p.append(document.createTextNode(part));
    }
    container.append(p);
  });
}
function selectNote(id) {
  if (noteEditing && !window.confirm("Discard your unsaved edit?")) return;
  selectedNote = id;
  noteEditing = false;
  noteVersion = "";
  notesKey = "";
  renderNotes(current.view);
}
function renderNotes(s) {
  const query = $("notes-search").value.toLocaleLowerCase();
  const key = JSON.stringify([s.notes, selectedNote, query, s.active_note]);
  if (key !== notesKey) {
    notesKey = key;
    $("meetings").replaceChildren();
    const notes = s.notes.filter((n) =>
      `${n.title} ${n.body} ${n.myNotes || ""} ${n.plainTranscript || ""}`
        .toLocaleLowerCase()
        .includes(query),
    );
    if (!notes.length)
      $("meetings").append(
        element(
          "p",
          query ? "No matching notes." : "Your recordings will appear here.",
          "muted",
        ),
      );
    for (const n of notes) {
      const b = button(
        "",
        () => selectNote(n.id),
        "note-card" + (n.id === selectedNote ? " selected" : ""),
      );
      b.append(
        element(
          "span",
          n.kind === "voice" ? "VOICE NOTE" : "MEETING",
          "eyebrow",
        ),
        element("strong", n.title || "Untitled"),
        element(
          "small",
          `${new Date((n.created_at || 0) * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric" })} · ${clockText(n.duration)}`,
        ),
        element(
          "p",
          (
            n.body ||
            n.myNotes ||
            n.lines?.map((l) => l.text).join(" ") ||
            "Waiting for your words…"
          )
            .replace(/^#{1,6}\s+/gmu, "")
            .replace(/\*\*/gu, "")
            .slice(0, 115),
        ),
      );
      if (n.id === s.active_note)
        b.append(element("span", "Recording", "recording-label"));
      $("meetings").append(b);
    }
  }
  if (s.active_note && !selectedNote) {
    selectedNote = s.active_note;
    notesKey = "";
  }
  const n = s.notes.find((n) => n.id === selectedNote);
  if (!n) {
    if (selectedNote) {
      $("note-detail").replaceChildren(
        element("div", "Choose a meeting to read your notes.", "empty"),
      );
      selectedNote = null;
    }
    return;
  }
  const version = JSON.stringify([
    n,
    noteTab,
    pendingNotes.has(n.id) || current.jobs?.includes(n.id),
    s.active_note,
  ]);
  if (version === noteVersion || noteEditing) return;
  noteVersion = version;
  const detail = $("note-detail");
  detail.replaceChildren();
  const top = element("div", undefined, "note-top");
  top.append(
    element(
      "span",
      `${n.kind === "voice" ? "VOICE NOTE" : "MEETING"} · ${clockText(n.duration)}`,
      "eyebrow",
    ),
    element("h2", n.title),
  );
  detail.append(top);
  const tools = element("div", undefined, "note-actions");
  tools.append(
    button("Rename", () => editNoteField(n, "title", false)),
    button("Export", () => call("export_data", { kind: "note", id: n.id })),
    button("Ask", () => openAsk([n.id])),
  );
  if (s.active_note !== n.id)
    tools.append(
      button("Delete", async () => {
        if (
          window.confirm(
            `Delete “${n.title}”? This removes its notes and transcript.`,
          )
        )
          await call("delete_note", { id: n.id });
      }),
    );
  detail.append(tools);
  if (n.notice && s.active_note !== n.id)
    detail.append(element("p", n.notice, "notice"));
  const tabs = element("div", undefined, "note-tabs");
  for (const [id, title] of [
    ["summary", "Notes"],
    ["transcript", "Transcript"],
    ["personal", "My notes"],
    ["people", "People"],
  ]) {
    const b = button(
      title,
      () => {
        if (noteEditing && !window.confirm("Discard your unsaved edit?"))
          return;
        noteEditing = false;
        noteTab = id;
        noteVersion = "";
        renderNotes(current.view);
      },
      noteTab === id ? "active" : "",
    );
    b.setAttribute("aria-pressed", String(noteTab === id));
    tabs.append(b);
  }
  detail.append(tabs);
  const body = element("div", undefined, "note-body");
  detail.append(body);
  if (noteTab === "summary") {
    const row = element("div", undefined, "row");
    const writing = pendingNotes.has(n.id) || current.jobs?.includes(n.id);
    row.append(
      button(
        writing ? "Writing…" : n.body ? "Rewrite notes" : "Write notes",
        async () => {
          if (writing) return;
          if (
            n.edited &&
            !window.confirm(
              "Replace your edited notes with a new AI write-up? The transcript and My notes will stay.",
            )
          )
            return;
          pendingNotes.add(n.id);
          noteVersion = "";
          renderNotes(current.view);
          try {
            await call("write_note", {
              id: n.id,
              replaceEdits: n.edited === true,
            });
          } finally {
            pendingNotes.delete(n.id);
            noteVersion = "";
            renderNotes(current.view);
          }
        },
        "primary",
      ),
    );
    if (writing)
      row.append(button("Cancel", () => call("cancel_note_job", { id: n.id })));
    else row.append(button("Edit", () => editNoteField(n, "body", true)));
    body.append(row);
    const markdown = element("div", undefined, "markdown");
    if (n.body) renderMarkdown(n.body, markdown, n);
    else
      markdown.append(
        element(
          "div",
          s.active_note === n.id
            ? "Your transcript is building. Notes will be ready after the recording ends."
            : "Turn your transcript into clear notes, decisions and next steps. Connect an AI provider in General, or write your own.",
          "empty",
        ),
      );
    body.append(markdown);
    if (n.actions?.some((a) => a.owner?.toLowerCase() === "me" && !a.done)) {
      body.append(
        button("Export my action items", () =>
          call("export_data", { kind: "tasks", id: n.id }),
        ),
      );
      if (current.platform === "macos")
        body.append(
          button("Add to Reminders", () =>
            call("export_reminders", { id: n.id }),
          ),
        );
    }
  } else if (noteTab === "transcript") {
    body.append(
      button("Copy transcript", () =>
        call("copy_text", { text: n.plainTranscript || "" }),
      ),
    );
    if (!n.lines?.length)
      body.append(
        element(
          "p",
          n.plainTranscript || "Your transcript will appear as you speak.",
          "transcript-empty",
        ),
      );
    for (const line of n.lines || []) {
      const row = element("div", undefined, "transcript-line");
      const label =
        line.speaker === "me"
          ? "Me"
          : line.voice
            ? n.speakerNames?.[line.voice - 1] || `Speaker ${line.voice}`
            : "Others";
      row.append(
        element("small", clockText(line.start)),
        element("strong", label),
        element("p", line.text),
      );
      body.append(row);
    }
  } else if (noteTab === "personal") {
    body.append(
      element(
        "p",
        "Capture a thought while you listen. Your notes help guide the write-up.",
        "muted",
      ),
    );
    const area = element("textarea");
    area.value = n.myNotes || "";
    area.rows = 12;
    area.setAttribute("aria-label", "My meeting notes");
    area.oninput = () => {
      noteEditing = true;
    };
    body.append(
      area,
      button(
        "Save my notes",
        async () => {
          await call("edit_note", { id: n.id, patch: { myNotes: area.value } });
          noteEditing = false;
          noteVersion = "";
          renderNotes(current.view);
        },
        "primary",
      ),
    );
  } else {
    body.append(
      element(
        "p",
        "Names help the write-up attribute decisions. Speaker labels are inferred from audio; review them before sharing.",
        "muted",
      ),
    );
    const participants = element("input");
    participants.value = (n.participants || []).join(", ");
    participants.setAttribute(
      "aria-label",
      "Participants, separated by commas",
    );
    body.append(element("label", "Participants"), participants);
    const names = [];
    for (let i = 0; i < 4; i++) {
      const input = element("input");
      input.value = n.speakerNames?.[i] || "";
      input.placeholder = `Speaker ${i + 1}`;
      input.setAttribute("aria-label", `Name for speaker ${i + 1}`);
      body.append(input);
      names.push(input);
    }
    body.append(
      button(
        "Save names",
        () =>
          call("edit_note", {
            id: n.id,
            patch: {
              participants: participants.value
                .split(",")
                .map((s) => s.trim())
                .filter(Boolean),
              speakerNames: names.map((n) => n.value.trim()),
            },
          }),
        "primary",
      ),
    );
  }
}
function editNoteField(note, field, multiline) {
  noteEditing = true;
  const body = $("note-detail");
  body.replaceChildren(
    element("h2", field === "title" ? "Rename note" : "Edit notes"),
  );
  const input = element(multiline ? "textarea" : "input");
  input.value = note[field] || "";
  input.setAttribute(
    "aria-label",
    field === "title" ? "Note title" : "Note body",
  );
  if (multiline) input.rows = 18;
  body.append(
    input,
    button(
      "Save",
      async () => {
        await call("edit_note", {
          id: note.id,
          patch: { [field]: input.value },
        });
        noteEditing = false;
        noteVersion = "";
        renderNotes(current.view);
      },
      "primary",
    ),
    button("Cancel", () => {
      noteEditing = false;
      noteVersion = "";
      renderNotes(current.view);
    }),
  );
  input.focus();
}
function renderWorkspace(s) {
  if (!workspaceReady) setupWorkspace();
  renderStats(s.history);
  renderHistory(s);
  renderNotes(s);
  const recording = s.stage.startsWith("meeting");
  $("start-meeting").disabled = s.stage !== "idle";
  $("start-voice").disabled = s.stage !== "idle";
  $("start-meeting").hidden = recording;
  $("start-voice").hidden = recording;
  $("stop-meeting").hidden = !recording;
  $("stop-meeting").disabled =
    s.stage === "meeting_finishing" || s.stage === "meeting_speakers";
  $("meeting-live").hidden = !recording;
  $("meeting-clock").textContent = clockText(s.meeting_elapsed);
  $("meeting-live-label").textContent =
    s.stage === "meeting_speakers"
      ? "Separating speakers"
      : s.stage === "meeting_finishing"
        ? "Finishing transcript"
        : s.stage === "meeting_starting"
          ? "Preparing recording"
          : "Recording";
  $("cancel-meeting-work").hidden = ![
    "meeting_starting",
    "meeting_speakers",
  ].includes(s.stage);
  $("cancel-meeting-work").textContent =
    s.stage === "meeting_speakers"
      ? "Skip speaker separation"
      : "Cancel preparation";
  if (!document.activeElement?.closest('[data-panel="general"]'))
    syncPreferences(s.settings);
}
function setting(patch) {
  return call("save_settings", { patch });
}
function populateModels(id) {
  const select = $(id);
  select.replaceChildren();
  for (const secondary of [false, true]) {
    const group = element("optgroup");
    group.label = secondary ? "Other models" : "Recommended";
    for (const model of current.models.filter(
      (m) => !!m.secondary === secondary,
    )) {
      const option = element("option", model.name);
      option.value = model.id;
      group.append(option);
    }
    if (group.children.length) select.append(group);
  }
}
function languageOptions(id, modelId, saved) {
  const select = $(id),
    model = current.models.find((m) => m.id === modelId);
  if (select.dataset.model !== modelId) {
    select.dataset.model = modelId;
    select.replaceChildren();
    const automatic = element("option", "Automatic");
    automatic.value = "auto";
    select.append(automatic);
    if (model?.supportsLanguageHint) {
      const names = new Intl.DisplayNames([navigator.language || "en"], {
        type: "language",
      });
      for (const code of model.languageCodes || []) {
        const option = element("option", names.of(code) || code);
        option.value = code;
        select.append(option);
      }
    }
    select.disabled = !model?.supportsLanguageHint;
  }
  select.value =
    model?.supportsLanguageHint && model.languageCodes.includes(saved)
      ? saved
      : "auto";
}
function syncPreferences(s) {
  languageOptions("dictation-language", s.asrModel, s.language);
  languageOptions(
    "meeting-language",
    s.meetingASRModel || "moss",
    s.meetingLanguage,
  );
  $("ai-enabled").checked = s.claudeCleanup === true;
  $("ai-provider").value = s.cleanupProvider || "claude";
  $("ai-connection").value =
    s[
      $("ai-provider").value === "claude"
        ? "claudeConnection"
        : "openAIConnection"
    ] || "apiKey";
  $("notes-ai").checked = s.notesUseAI !== false;
  $("notes-model").value = s.notesModel || "claude:haiku55";
  $("meeting-hours").value = s.maxMeetingHours || 3;
  $("meeting-model").value = s.meetingASRModel || "moss";
  $("detect-calls").checked = s.detectCalls !== false;
  $("wayland-cursor").checked = s.waylandCurrentCursor === true;
  $("wayland-option").hidden = !current.permissions.wayland;
  $("wayland-help").hidden = !current.permissions.wayland;
  const binding = s.shortcut || {
    kind: current.platform === "macos" ? "macKey" : "chord",
    keyCode: 61,
    accelerator: "Control+Shift+Space",
  };
  $("shortcut-kind").value = binding.kind;
  $("shortcut-value").value =
    binding.kind === "macKey" ? String(binding.keyCode) : binding.accelerator;
  renderAccount();
}
function renderAccount() {
  const claude = $("ai-provider").value === "claude",
    subscription = $("ai-connection").value === "subscription";
  $("api-key-row").hidden = subscription;
  $("subscription-row").hidden = !subscription;
  $("sign-in").hidden = false;
  $("sign-in").textContent = claude
    ? "Sign in with Claude"
    : "Sign in with ChatGPT";
  $("sign-out").hidden = claude;
  $("subscription-help").textContent = claude
    ? "Sign in using the official Claude Code app. Pressay uses that subscription through a separate, restricted text-only process."
    : "Sign in in your browser. Pressay stores the resulting credentials in your operating system’s credential store.";
  if (accountInfo)
    $("account-status").textContent = subscription
      ? claude
        ? accountInfo.claudeCode?.uses_subscription
          ? "Claude subscription connected"
          : accountInfo.claudeCodeError ||
            "Sign in with your Claude subscription."
        : accountInfo.chatgpt.signed_in
          ? `Connected${accountInfo.chatgpt.email ? ` as ${accountInfo.chatgpt.email}` : ""}`
          : "Not connected"
      : accountInfo[claude ? "claudeApiKey" : "openaiApiKey"]
        ? "API key connected"
        : "No API key connected";
}
async function refreshAccount() {
  try {
    accountInfo = await call("account_status");
    renderAccount();
  } catch {}
}
function openAsk(ids) {
  askIds = ids;
  exchanges = [];
  $("ask-conversation").replaceChildren();
  $("ask-title").textContent =
    ids.length === 1 ? "Ask this meeting" : "Ask your meetings";
  $("ask-dialog").showModal();
  $("ask-question").focus();
}
function setupWorkspace() {
  workspaceReady = true;
  $("clear-history").onclick = async () => {
    if (
      !confirm(
        "Clear dictation history? All dictations, including pinned and corrected entries, and their audio recordings will be deleted. This can’t be undone.",
      )
    )
      return;
    await call("clear_history").catch(() => {});
  };
  for (const id of ["history-search", "history-pinned"])
    $(id).addEventListener("input", () => renderHistory(current.view));
  $("notes-search").oninput = () => renderNotes(current.view);
  for (const [id, kind] of [
    ["start-meeting", "meeting"],
    ["start-voice", "voice"],
  ])
    $(id).onclick = () => {
      selectedNote = null;
      call("start_meeting", { kind }).catch(() => {});
    };
  $("stop-meeting").onclick = () => call("stop_meeting").catch(() => {});
  populateModels("meeting-model");
  $("cancel-meeting-work").onclick = () => call("cancel").catch(() => {});
  $("ai-enabled").onchange = () =>
    setting({ claudeCleanup: $("ai-enabled").checked }).catch(() => {});
  $("ai-provider").onchange = async () => {
    await setting({ cleanupProvider: $("ai-provider").value });
    $("ai-connection").value =
      current.view.settings[
        $("ai-provider").value === "claude"
          ? "claudeConnection"
          : "openAIConnection"
      ] || "apiKey";
    renderAccount();
  };
  $("ai-connection").onchange = () => {
    setting({
      [$("ai-provider").value === "claude"
        ? "claudeConnection"
        : "openAIConnection"]: $("ai-connection").value,
    }).catch(() => {});
    renderAccount();
  };
  $("save-api-key").onclick = async () => {
    try {
      await call("save_api_key", {
        provider: $("ai-provider").value,
        key: $("api-key").value,
      });
      $("api-key").value = "";
      await refreshAccount();
    } catch {}
  };
  $("remove-api-key").onclick = async () => {
    try {
      await call("save_api_key", { provider: $("ai-provider").value, key: "" });
      await refreshAccount();
    } catch {}
  };
  $("sign-in").onclick = async () => {
    const b = $("sign-in");
    b.disabled = true;
    b.textContent = "Complete sign-in in your browser…";
    try {
      $("cancel-sign-in").hidden = false;
      await call(
        $("ai-provider").value === "claude"
          ? "claude_sign_in"
          : "chatgpt_sign_in",
      );
      await refreshAccount();
    } catch {
    } finally {
      b.disabled = false;
      $("cancel-sign-in").hidden = true;
      renderAccount();
    }
  };
  $("sign-out").onclick = async () => {
    try {
      await call("chatgpt_sign_out");
      await refreshAccount();
    } catch {}
  };
  for (const [id, key, kind] of [
    ["dictation-language", "language", "value"],
    ["meeting-language", "meetingLanguage", "value"],
    ["meeting-model", "meetingASRModel", "value"],
    ["meeting-hours", "maxMeetingHours", "number"],
    ["notes-model", "notesModel", "value"],
    ["notes-ai", "notesUseAI", "checked"],
    ["detect-calls", "detectCalls", "checked"],
    ["wayland-cursor", "waylandCurrentCursor", "checked"],
  ])
    $(id).onchange = () =>
      setting({
        [key]: kind === "number" ? Number($(id).value) : $(id)[kind],
      })
        .then(() => {
          if (id === "meeting-model")
            languageOptions(
              "meeting-language",
              $(id).value,
              current.view.settings.meetingLanguage,
            );
        })
        .catch(() => {});
  $("save-shortcut").onclick = () =>
    call("change_shortcut", {
      binding:
        $("shortcut-kind").value === "macKey"
          ? { kind: "macKey", keyCode: Number($("shortcut-value").value) }
          : { kind: "chord", accelerator: $("shortcut-value").value },
    }).catch(() => {});
  $("cancel-sign-in").onclick = () => call("cancel_sign_in").catch(() => {});
  $("import-mac-keys").hidden = current.platform !== "macos";
  $("import-mac-keys").onclick = async () => {
    try {
      const result = await call("import_mac_api_keys");
      await refreshAccount();
      $("account-status").textContent =
        `Claude: ${result.claude}. OpenAI: ${result.openai}. Original keys were kept.`;
    } catch {}
  };
  $("import-mac-audio").hidden = current.platform !== "macos";
  $("import-mac-audio").onclick = async () => {
    const b = $("import-mac-audio");
    b.disabled = true;
    $("cancel-audio-import").hidden = false;
    $("audio-import-status").textContent =
      "Importing recordings for your imported history…";
    try {
      const r = await call("import_mac_audio");
      $("audio-import-status").textContent = r.sourceMissing
        ? "No original Mac recordings were found."
        : `${r.imported} imported · ${r.alreadyPresent} already here · ${r.missing} unavailable${r.unsafeFiles + r.failed ? ` · ${r.unsafeFiles + r.failed} could not be imported` : ""}${r.cancelled ? " · Cancelled" : ""}. Original recordings were kept.`;
    } catch {
    } finally {
      b.disabled = false;
      $("cancel-audio-import").hidden = true;
    }
  };
  $("cancel-audio-import").onclick = () =>
    call("cancel_note_job", { id: "$import-mac-audio" }).catch(() => {});
  $("export-backup").onclick = () =>
    call("export_data", { kind: "backup", id: null }).catch(() => {});
  $("launch-at-login").onchange = () =>
    call("launch_at_login", { enabled: $("launch-at-login").checked }).catch(
      () => ($("launch-at-login").checked = !$("launch-at-login").checked),
    );
  call("autostart_status")
    .then((v) => ($("launch-at-login").checked = v))
    .catch(() => {});
  $("check-updates").onclick = async () => {
    try {
      const result = await call("check_update");
      $("update-status").textContent = result.message;
      if (
        result.available &&
        window.confirm(
          `Install Pressay ${result.version}? The app will restart.`,
        )
      )
        await call("install_update");
    } catch {}
  };
  $("ask-all").onclick = () => openAsk([]);
  $("close-ask").onclick = () => $("ask-dialog").close();
  $("cancel-ask").onclick = () =>
    call("cancel_note_job", { id: "ask" }).catch(() => {});
  $("ask-form").onsubmit = async (event) => {
    event.preventDefault();
    if (askBusy) return;
    const question = $("ask-question").value.trim();
    if (!question) return;
    askBusy = true;
    $("submit-ask").disabled = true;
    $("cancel-ask").hidden = false;
    $("ask-conversation").append(element("p", question, "question"));
    try {
      const answer = await call("ask_notes", {
        question,
        ids: askIds,
        history: exchanges,
      });
      const body = element("div", undefined, "answer markdown");
      renderMarkdown(answer, body);
      $("ask-conversation").append(body);
      exchanges.push({ question, answer });
      $("ask-question").value = "";
    } catch {
    } finally {
      askBusy = false;
      $("submit-ask").disabled = false;
      $("cancel-ask").hidden = true;
    }
  };
  $("call-record").onclick = () => {
    navigate("meetings");
    selectedNote = null;
    call("start_meeting", { kind: "meeting", fromCall: true }).catch(() => {});
    $("call-banner").hidden = true;
  };
  $("dismiss-call").onclick = () => ($("call-banner").hidden = true);
  window.__TAURI__.event.listen("pressay-call", (event) => {
    const c = event.payload;
    $("call-banner").hidden = !c.active;
    $("call-message").textContent = c.active
      ? `${c.application} is using your microphone. Take notes for this call?`
      : "";
  });
  document
    .querySelector('[data-page="general"]')
    .addEventListener("click", refreshAccount);
}
