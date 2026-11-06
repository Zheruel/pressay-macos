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
let shortcutDirty = false,
  shortcutSaved = null,
  shortcutCapturing = false,
  shortcutStarting = false,
  shortcutCaptureEpoch = 0,
  shortcutCandidate = null,
  shortcutTimer = null,
  inputDeviceKey = null,
  inputDeviceRefresh = null,
  credentialSelection = null;
function savedShortcut(settings) {
  return (
    settings.shortcut ||
    (current.platform === "macos"
      ? { kind: "macKey", keyCode: settings.holdKeyCode ?? 61 }
      : { kind: "chord", accelerator: "Control+Shift+Space" })
  );
}
function shortcutBinding() {
  return $("shortcut-kind").value === "macKey"
    ? { kind: "macKey", keyCode: Number($("shortcut-mac-key").value) }
    : { kind: "chord", accelerator: $("shortcut-value").value.trim() };
}
function renderShortcutControls() {
  const mac = $("shortcut-kind").value === "macKey";
  $("shortcut-mac-row").hidden = !mac;
  $("shortcut-chord-row").hidden = mac;
  $("shortcut-mac-key").hidden = !mac;
  $("shortcut-value").hidden = mac;
  $("shortcut-kind").disabled = shortcutCapturing || shortcutStarting;
  $("shortcut-mac-key").disabled = shortcutCapturing || shortcutStarting;
  $("shortcut-value").disabled = shortcutCapturing || shortcutStarting;
  $("record-shortcut").textContent = shortcutCapturing
    ? "Cancel recording"
    : "Record key…";
  $("record-shortcut").disabled = shortcutStarting;
  $("save-shortcut").disabled =
    !shortcutDirty || shortcutCapturing || shortcutStarting;
  $("reset-shortcut").hidden =
    !shortcutDirty || shortcutCapturing || shortcutStarting;
}
function applyShortcutDraft(binding, label) {
  $("shortcut-kind").value = binding.kind;
  if (binding.kind === "macKey") {
    const select = $("shortcut-mac-key");
    const value = String(binding.keyCode);
    if (![...select.options].some((option) => option.value === value)) {
      const option = element("option", label || "Saved key — record to change");
      option.value = value;
      select.append(option);
    }
    select.value = value;
  } else $("shortcut-value").value = binding.accelerator;
  renderShortcutControls();
}
function syncShortcut(settings) {
  const binding = savedShortcut(settings);
  if (shortcutSaved && JSON.stringify(binding) === shortcutSaved) {
    shortcutDirty = false;
    shortcutSaved = null;
  }
  if (!shortcutDirty && !shortcutCapturing && !shortcutStarting)
    applyShortcutDraft(binding, current.shortcut);
  else renderShortcutControls();
}
function dirtyShortcut() {
  shortcutDirty = true;
  shortcutSaved = null;
  $("shortcut-status").textContent = "Unsaved shortcut. Save to use it.";
  renderShortcutControls();
}
async function stopShortcutCapture(message = "Shortcut recording cancelled.") {
  const wasActive = shortcutCapturing || shortcutStarting;
  ++shortcutCaptureEpoch;
  shortcutCapturing = false;
  shortcutStarting = false;
  shortcutCandidate = null;
  clearTimeout(shortcutTimer);
  if (wasActive) {
    try {
      await call("set_shortcut_capture", {
        active: false,
        kind: $("shortcut-kind").value,
      });
    } catch {
      message =
        "Could not resume your shortcut. Try recording again or restart Pressay.";
    }
    $("shortcut-status").textContent = message;
  }
  renderShortcutControls();
}
async function acceptShortcut(binding, label) {
  await stopShortcutCapture("Key recorded. Save to use this shortcut.");
  applyShortcutDraft(binding, label);
  shortcutDirty = true;
  shortcutSaved = null;
  renderShortcutControls();
}
async function startShortcutCapture() {
  if (shortcutCapturing || shortcutStarting) return stopShortcutCapture();
  const epoch = ++shortcutCaptureEpoch;
  shortcutStarting = true;
  renderShortcutControls();
  try {
    await call("set_shortcut_capture", {
      active: true,
      kind: $("shortcut-kind").value,
    });
    if (epoch !== shortcutCaptureEpoch) {
      await call("set_shortcut_capture", {
        active: false,
        kind: $("shortcut-kind").value,
      });
      return;
    }
    shortcutStarting = false;
    shortcutCapturing = true;
    $("shortcut-status").textContent =
      $("shortcut-kind").value === "macKey"
        ? "Press a key or modifier. Escape cancels."
        : "Press your key combination, then release it. Escape cancels.";
    shortcutTimer = setTimeout(
      () => stopShortcutCapture("Shortcut recording timed out."),
      30000,
    );
    renderShortcutControls();
  } catch {
    shortcutStarting = false;
    renderShortcutControls();
  }
}
function chordForEvent(event) {
  if (
    event.repeat ||
    [
      "Control",
      "Alt",
      "Shift",
      "Meta",
      "CapsLock",
      "Fn",
      "Unidentified",
    ].includes(event.key)
  )
    return null;
  const modifiers = [];
  if (event.ctrlKey) modifiers.push("Control");
  if (event.altKey) modifiers.push("Alt");
  if (event.shiftKey) modifiers.push("Shift");
  if (event.metaKey) modifiers.push("Super");
  let key = event.code;
  if (/^Key[A-Z]$/.test(key)) key = key.slice(3);
  else if (/^Digit[0-9]$/.test(key)) key = key.slice(5);
  else if (key.startsWith("Arrow")) key = key.slice(5);
  const names = {
    Backquote: "Backquote",
    Minus: "Minus",
    Equal: "Equal",
    BracketLeft: "BracketLeft",
    BracketRight: "BracketRight",
    Backslash: "Backslash",
    Semicolon: "Semicolon",
    Quote: "Quote",
    Comma: "Comma",
    Period: "Period",
    Slash: "Slash",
  };
  if (names[key]) key = names[key];
  if (
    !/^(?:[A-Z0-9]|F(?:[1-9]|1[0-9]|2[0-4])|Space|Enter|Tab|Backspace|Delete|Insert|Home|End|PageUp|PageDown|Left|Right|Up|Down|Backquote|Minus|Equal|BracketLeft|BracketRight|Backslash|Semicolon|Quote|Comma|Period|Slash)$/.test(
      key,
    )
  )
    return null;
  if (!modifiers.length && !/^F\d+$/.test(key)) return null;
  return { kind: "chord", accelerator: [...modifiers, key].join("+") };
}
async function refreshInputDevices() {
  if (inputDeviceRefresh) return inputDeviceRefresh;
  inputDeviceRefresh = (async () => {
    try {
      const info = await call("input_device_selection");
      const select = $("input-device");
      if (document.activeElement === select) return;
      select.replaceChildren();
      const system = element("option", "System default");
      system.value = "";
      select.append(system);
      for (const name of info.devices) {
        const option = element("option", name);
        option.value = name;
        select.append(option);
      }
      if ($("input-device-status"))
        $("input-device-status").textContent = info.unavailable
          ? "Choose another microphone to record."
          : "";
      if (info.unavailable) {
        const unavailable = element("option", "Saved microphone unavailable");
        unavailable.value = "__unavailable__";
        unavailable.disabled = true;
        select.append(unavailable);
        select.value = unavailable.value;
      } else {
        if (info.selected && !info.devices.includes(info.selected)) {
          const selected = element("option", info.selected);
          selected.value = info.selected;
          select.append(selected);
        }
        select.value = info.selected || "";
      }
    } catch {}
  })().finally(() => {
    inputDeviceRefresh = null;
  });
  return inputDeviceRefresh;
}

let generalTab = "dictation",
  generalPermissionKey = null,
  accountRefresh = null;
function showGeneralTab(tab) {
  if (!["dictation", "notetaker"].includes(tab)) return;
  generalTab = tab;
  stopShortcutCapture();
  for (const button of document.querySelectorAll("[data-general-tab]")) {
    const selected = button.dataset.generalTab === tab;
    button.setAttribute("aria-selected", String(selected));
    button.tabIndex = selected ? 0 : -1;
    $("general-" + button.dataset.generalTab).hidden = !selected;
  }
  if (tab === "notetaker") refreshAccount();
}
function renderGeneralPermissions() {
  const permissions = current.permissions,
    mac = current.platform === "macos";
  const key = JSON.stringify([permissions, mac]);
  if (key === generalPermissionKey) return;
  generalPermissionKey = key;
  const group = $("general-permissions");
  group.replaceChildren();
  const kinds = [
    ["microphone", "microphone", "Microphone"],
    ["accessibility", "insertion", mac ? "Accessibility" : "Text insertion"],
    ["shortcut", "shortcut", mac ? "Input Monitoring" : "Global shortcut"],
  ];
  if (kinds.every(([, field]) => permissions[field] === "granted")) {
    const row = element("div", undefined, "setting-row");
    row.append(
      element(
        "span",
        mac
          ? "Microphone, Accessibility & Input Monitoring"
          : "Microphone, text insertion & global shortcut",
      ),
      element("span", "Allowed", "settings-allowed"),
    );
    group.append(row);
    return;
  }
  for (const [kind, field, title] of kinds) {
    const status = permissions[field],
      row = element("div", undefined, "setting-row");
    row.append(element("span", title));
    if (status === "granted")
      row.append(element("span", "Allowed", "settings-allowed"));
    else {
      const portalChoice =
        kind === "accessibility" &&
        permissions.wayland &&
        status === "unavailable";
      const control = button(
        portalChoice
          ? "Enable cursor insertion"
          : status === "denied"
            ? "Open settings"
            : "Allow",
        async () => {
          if (portalChoice) await setting({ waylandCurrentCursor: true });
          await call("request_permission", { kind });
        },
      );
      control.setAttribute("aria-label", `${control.textContent}: ${title}`);
      if (status === "unavailable" && !portalChoice) {
        control.disabled = true;
        control.textContent = "Unavailable";
      }
      row.append(control);
    }
    group.append(row);
  }
}
function renderNotesSettings(settings) {
  const claude = accountInfo?.claudeApiKey === true;
  const chatgpt = accountInfo?.chatgpt?.signed_in === true;
  const options = [];
  if (claude)
    options.push(
      ["claude:haiku55", "1. Claude Haiku 5.5 · Recommended"],
      ["claude:sonnet55", "2. Claude Sonnet 5.5"],
    );
  if (chatgpt)
    options.push(
      ["chatgpt:gpt-6.1-sol", "1. GPT-6.1 Sol · Recommended"],
      ["chatgpt:gpt-6-luna", "2. GPT-6 Luna"],
    );
  const available = options.length > 0;
  $("notes-ai").disabled = !available;
  $("notes-connect-row").hidden = available;
  $("notes-model-row").hidden = !available;
  $("notes-connection-help").textContent = accountInfo
    ? "Requires an Anthropic API key or a ChatGPT subscription."
    : accountRefresh
      ? "Checking your connected accounts…"
      : "Connect an Anthropic API key or a ChatGPT subscription to write up notes.";
  const select = $("notes-model"),
    key = JSON.stringify(options);
  if (select.dataset.options !== key) {
    select.dataset.options = key;
    select.replaceChildren();
    for (const [id, name] of options) {
      const option = element("option", name);
      option.value = id;
      select.append(option);
    }
  }
  const saved = settings.notesModel;
  const effective = options.some(([id]) => id === saved)
    ? saved
    : settings.cleanupProvider === "chatgpt" && chatgpt
      ? "chatgpt:gpt-6.1-sol"
      : claude
        ? "claude:haiku55"
        : chatgpt
          ? "chatgpt:gpt-6.1-sol"
          : "";
  if (document.activeElement !== select) select.value = effective;
  select.disabled = !available || settings.notesUseAI === false;
  $("notes-model-help").textContent =
    saved && saved !== effective && available
      ? "Your saved model is unavailable. The model shown uses your connected account; your saved choice is kept until you change it."
      : "Uses an account connected in AI Cleanup.";
}
function renderGeneralSettings(state) {
  renderGeneralPermissions();
  renderNotesSettings(state.settings);
  const busy = state.stage !== "idle",
    meeting = state.stage.startsWith("meeting");
  $("model").disabled = busy;
  $("meeting-model").disabled = meeting;
  const model = current.models.find(
    (model) => model.id === state.settings.asrModel,
  );
  const meetingModel = current.models.find(
    (model) => model.id === (state.settings.meetingASRModel || "moss"),
  );
  $("dictation-language").disabled = busy || !model?.supportsLanguageHint;
  $("meeting-language").disabled =
    meeting || !meetingModel?.supportsLanguageHint;
  const ready =
    state.model_ready && $("model").value === state.settings.asrModel;
  $("general-model-status").textContent = ["preparing", "loading"].includes(
    state.stage,
  )
    ? "Loading…"
    : ready
      ? "Ready"
      : "Not loaded";
  $("general-model-status").classList.toggle("settings-allowed", ready);
  $("prepare").hidden = ready;
  $("original-audio-row").hidden = current.platform !== "macos";
}
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
  $("weekly-words").textContent = words.toLocaleString();
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
  const microphoneKey = JSON.stringify([
    s.settings.inputDevice,
    s.settings.inputDeviceUID,
  ]);
  if (inputDeviceKey !== microphoneKey) {
    inputDeviceKey = microphoneKey;
    refreshInputDevices();
  }
  syncShortcut(s.settings);
  if (
    !document.activeElement?.closest(
      '[data-panel="general"], [data-panel="ai"]',
    )
  )
    syncPreferences(s.settings);
  renderGeneralSettings(s);
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
  renderNotesSettings(s);
  $("meeting-hours").value = s.maxMeetingHours || 3;
  $("meeting-model").value = s.meetingASRModel || "moss";
  $("detect-calls").checked = s.detectCalls !== false;
  $("wayland-cursor").checked = s.waylandCurrentCursor === true;
  $("wayland-option").hidden = !current.permissions.wayland;
  $("wayland-help").hidden = !current.permissions.wayland;
  syncShortcut(s);
  renderAccount();
}
function renderAccount() {
  const claude = $("ai-provider").value === "claude",
    subscription = $("ai-connection").value === "subscription";
  const selection = JSON.stringify([
    $("ai-provider").value,
    $("ai-connection").value,
  ]);
  if (credentialSelection !== null && credentialSelection !== selection)
    $("api-key").value = "";
  credentialSelection = selection;
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
  if (accountRefresh) return accountRefresh;
  accountRefresh = (async () => {
    try {
      accountInfo = await call("account_status");
      renderAccount();
    } catch {
      accountInfo = null;
    }
    renderNotesSettings(current.view.settings);
  })().finally(() => {
    accountRefresh = null;
  });
  return accountRefresh;
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
  for (const tab of document.querySelectorAll("[data-general-tab]")) {
    tab.onclick = () => showGeneralTab(tab.dataset.generalTab);
    tab.onkeydown = (event) => {
      if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key))
        return;
      event.preventDefault();
      const next =
        event.key === "Home"
          ? "dictation"
          : event.key === "End"
            ? "notetaker"
            : generalTab === "dictation"
              ? "notetaker"
              : "dictation";
      showGeneralTab(next);
      $("general-" + next + "-tab").focus();
    };
  }
  $("notes-connect-ai").onclick = () => {
    navigate("ai");
    $("ai-provider").focus();
    refreshAccount();
  };
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
    $("api-key").value = "";
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
    $("api-key").value = "";
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
  $("shortcut-kind").querySelector('[value="macKey"]').hidden =
    current.platform !== "macos";
  $("shortcut-kind").onchange = dirtyShortcut;
  $("shortcut-value").oninput = dirtyShortcut;
  $("shortcut-mac-key").onchange = dirtyShortcut;
  $("record-shortcut").onclick = () => startShortcutCapture();
  $("reset-shortcut").onclick = () => {
    shortcutDirty = false;
    shortcutSaved = null;
    syncShortcut(current.view.settings);
    $("shortcut-status").textContent = "Changes discarded.";
  };
  $("save-shortcut").onclick = async () => {
    const binding = shortcutBinding();
    $("save-shortcut").disabled = true;
    try {
      await call("change_shortcut", { binding });
      shortcutSaved = JSON.stringify(binding);
      $("shortcut-status").textContent = "Shortcut saved.";
      syncShortcut(current.view.settings);
      await refresh();
    } catch (error) {
      shortcutDirty = true;
      $("shortcut-status").textContent =
        `Shortcut was not saved: ${String(error)}. Your changes are kept; edit or retry.`;
    } finally {
      renderShortcutControls();
    }
  };
  document.addEventListener(
    "keydown",
    (event) => {
      if (!shortcutCapturing) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      if (event.key === "Escape") {
        stopShortcutCapture();
        return;
      }
      if ($("shortcut-kind").value !== "chord") return;
      const binding = chordForEvent(event);
      if (!binding) {
        $("shortcut-status").textContent =
          "Use a modifier with another key, or a function key. Escape cancels.";
        return;
      }
      shortcutCandidate = { binding, code: event.code };
      $("shortcut-status").textContent =
        "Release the keys to finish recording.";
    },
    true,
  );
  document.addEventListener(
    "keyup",
    (event) => {
      if (!shortcutCapturing) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      if (shortcutCandidate?.code === event.code)
        acceptShortcut(shortcutCandidate.binding);
    },
    true,
  );
  window.__TAURI__.event.listen("pressay-shortcut-captured", ({ payload }) => {
    if (!shortcutCapturing && !shortcutStarting) return;
    if (payload.cancelled) {
      stopShortcutCapture();
      return;
    }
    if (payload.waitForRelease) {
      $("shortcut-status").textContent =
        "Release the keys to finish recording.";
      return;
    }
    acceptShortcut(payload.binding, payload.label);
  });
  window.addEventListener("blur", () => stopShortcutCapture());
  window.addEventListener("pagehide", () => stopShortcutCapture());
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) stopShortcutCapture();
  });
  document.querySelectorAll("[data-page]").forEach((button) =>
    button.addEventListener("click", () => {
      stopShortcutCapture();
      if (button.dataset.page === "general") refreshInputDevices();
    }),
  );
  $("input-device").addEventListener("blur", () => refreshInputDevices());
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
  for (const page of ["general", "ai"])
    document
      .querySelector(`[data-page="${page}"]`)
      .addEventListener("click", refreshAccount);
}
