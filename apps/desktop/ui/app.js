"use strict";
const { invoke } = window.__TAURI__.core;
const $ = (id) => document.getElementById(id);
let current,
  step = 0,
  historyVersion = "",
  meetingsVersion = "",
  recentVersion = "",
  initialized = false;
const dialog = $("onboarding");
function error(message) {
  $("error").textContent = String(message);
  $("error").hidden = false;
  $("setup-error").textContent = String(message);
}
async function call(command, args = {}) {
  try {
    return await invoke(command, args);
  } catch (e) {
    error(e);
    throw e;
  }
}
function navigate(page) {
  const changed =
    document.querySelector("[data-page].active")?.dataset.page !== page;
  document
    .querySelectorAll("[data-panel]")
    .forEach((p) => (p.hidden = p.dataset.panel !== page));
  document.querySelectorAll("[data-page]").forEach((b) => {
    b.classList.toggle("active", b.dataset.page === page);
    b.setAttribute("aria-current", b.dataset.page === page ? "page" : "false");
  });
  if (changed) document.querySelector("main").scrollTop = 0;
}
document
  .querySelectorAll("[data-page]")
  .forEach((b) => b.addEventListener("click", () => navigate(b.dataset.page)));
$("view-history").onclick = () => navigate("history");
$("home-record-meeting").onclick = () => {
  navigate("meetings");
  $("start-meeting").click();
};
function setStep(value) {
  step = value;
  document
    .querySelectorAll("[data-setup]")
    .forEach((p) => (p.hidden = Number(p.dataset.setup) !== step));
  document.querySelectorAll("[data-step]").forEach((p) => {
    p.classList.toggle("current", Number(p.dataset.step) === step);
    p.setAttribute(
      "aria-current",
      Number(p.dataset.step) === step ? "step" : "false",
    );
  });
  $("setup-back").hidden = step === 0;
  $("setup-title").textContent = [
    "A few permissions. Then it’s your turn.",
    "Your voice, recognized locally.",
    "Make your first words appear.",
  ][step];
  $("setup-description").textContent = [
    "You stay in control. Allow Pressay to hear you and type where you’re working.",
    "Choose a speech model. We’ll show you its download and preparation progress.",
    "Click the field below. Hold your shortcut, speak naturally, then release.",
  ][step];
  $("setup-error").textContent = "";
  if (step === 2) $("practice").focus();
}
function microphoneCanPractice(p) {
  return current?.platform === "macos"
    ? p.microphone === "granted"
    : p.microphone !== "denied";
}
function openSetup() {
  if (!dialog.open) {
    $("setup-model").value = current.view.settings.asrModel;
    $("setup-model-size").textContent = size($("setup-model").value);
    dialog.showModal();
  }
  const p = current?.permissions;
  const granted =
    p &&
    p.shortcut === "granted" &&
    p.insertion === "granted" &&
    microphoneCanPractice(p);
  setStep(granted ? (selectedModelReady() ? 2 : 1) : 0);
}
$("setup-again").onclick = openSetup;
$("close-setup").onclick = () => dialog.close();
$("setup-back").onclick = () => setStep(Math.max(0, step - 1));
$("permissions-next").onclick = () => setStep(1);
$("model-next").onclick = () => {
  if (selectedModelReady()) setStep(2);
};
$("cancel").onclick = () => call("cancel").catch(() => {});
$("quit").onclick = () => call("quit").catch(() => {});
let dictionaryRows = [],
  dictionarySaved = null,
  dictionaryDirty = false,
  dictionarySaving = false;
function dictionarySource() {
  return dictionaryRows
    .flatMap((row) => {
      const word = row.word.trim();
      if (!word) return [];
      const aliases = row.aliases
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
      return [aliases.length ? `${word} <= ${aliases.join(", ")}` : word];
    })
    .join("\n");
}
function queueDictionarySave() {
  dictionaryDirty = true;
  $("dictionary-result").textContent = "Saving…";
  queueMicrotask(saveDictionary);
}
async function saveDictionary() {
  if (dictionarySaving || !dictionaryDirty) return;
  if (
    dictionaryRows.some(
      (row) => row.word.includes("<=") || row.word.trim().startsWith("#"),
    )
  ) {
    $("dictionary-result").textContent =
      "A word cannot start with # or contain <=.";
    return;
  }
  const source = dictionarySource();
  dictionarySaving = true;
  $("retry-dictionary").hidden = true;
  let saved = false;
  try {
    await call("save_settings", { patch: { vocabulary: source } });
    dictionarySaved = source;
    dictionaryDirty = dictionarySource() !== source;
    $("dictionary-result").textContent = dictionaryDirty ? "Saving…" : "Saved";
    saved = true;
  } catch {
    $("dictionary-result").textContent =
      "Could not save. Your changes are still here.";
    $("retry-dictionary").hidden = false;
  } finally {
    dictionarySaving = false;
    if (saved && dictionaryDirty) queueDictionarySave();
  }
}
function drawDictionary() {
  $("dictionary-rows").replaceChildren();
  $("dictionary-empty").hidden = dictionaryRows.length !== 0;
  $("dictionary-table").hidden = !dictionaryRows.length;
  $("dictionary-help").hidden = !dictionaryRows.length;
  for (const row of dictionaryRows) {
    const container = element("div", undefined, "dictionary-row");
    const word = element("input"),
      aliases = element("input");
    word.value = row.word;
    word.placeholder = "Word";
    word.setAttribute("aria-label", "Word");
    word.spellcheck = false;
    aliases.value = row.aliases;
    aliases.placeholder = "Optional, comma-separated";
    aliases.setAttribute("aria-label", "Sounds like");
    aliases.spellcheck = false;
    const remove = element("button", "×", "quiet");
    remove.setAttribute(
      "aria-label",
      row.word ? `Remove ${row.word}` : "Remove word",
    );
    word.oninput = () => {
      row.word = word.value;
      remove.setAttribute(
        "aria-label",
        row.word ? `Remove ${row.word}` : "Remove word",
      );
      queueDictionarySave();
    };
    aliases.oninput = () => {
      row.aliases = aliases.value;
      queueDictionarySave();
    };
    remove.onclick = () => {
      dictionaryRows = dictionaryRows.filter((candidate) => candidate !== row);
      drawDictionary();
      queueDictionarySave();
    };
    container.append(word, aliases, remove);
    $("dictionary-rows").append(container);
  }
}
function syncDictionary(source) {
  if (dictionaryDirty || dictionarySaving || dictionarySaved === source) return;
  dictionarySaved = source;
  dictionaryRows = source.split(/\r?\n/u).flatMap((line) => {
    line = line.trim();
    if (!line || line.startsWith("#")) return [];
    const separator = line.indexOf("<=");
    const word = (separator < 0 ? line : line.slice(0, separator)).trim();
    return word
      ? [
          {
            word,
            aliases: separator < 0 ? "" : line.slice(separator + 2).trim(),
          },
        ]
      : [];
  });
  drawDictionary();
}
function addDictionaryWord() {
  let index = dictionaryRows.findIndex((row) => !row.word.trim());
  if (index < 0) {
    index = dictionaryRows.length;
    dictionaryRows.push({ word: "", aliases: "" });
    drawDictionary();
  }
  $("dictionary-rows").children[index].querySelector("input").focus();
}
$("add-word").onclick = addDictionaryWord;
$("add-first-word").onclick = addDictionaryWord;
$("retry-dictionary").onclick = saveDictionary;
$("input-device").onchange = () =>
  call("save_settings", {
    patch: { inputDevice: $("input-device").value || null },
  }).catch(() => {});
function size(id) {
  const model = current?.models.find((m) => m.id === id);
  return model
    ? `${(model.artifacts.reduce((n, a) => n + a.bytes, 0) / 1e9).toFixed(2)} GB · verified download · ${model.languageCaption || "automatic language detection"}`
    : "";
}
function selectedModelReady() {
  return !!(
    current?.view.model_ready &&
    $("setup-model").value === current.view.settings.asrModel
  );
}
for (const id of ["model", "setup-model"])
  $(id).onchange = () => {
    $(id + "-size").textContent = size($(id).value);
    $("model-next").disabled = !selectedModelReady();
  };
$("prepare").onclick = () =>
  call("prepare_model", { id: $("model").value }).catch(() => {});
$("setup-prepare").onclick = () =>
  call("prepare_model", { id: $("setup-model").value }).catch(() => {});
function practiceReady() {
  const p = current?.view.practice;
  return !!(
    p?.received_audio &&
    p?.inserted &&
    p?.recognized_text.trim() &&
    $("practice").value.includes(p.recognized_text.trim())
  );
}
$("practice").addEventListener(
  "input",
  () => ($("finish-setup").disabled = !practiceReady()),
);
$("practice").addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    event.preventDefault();
    call("cancel").catch(() => {});
  }
});
$("finish-setup").onclick = async () => {
  try {
    await call("complete_onboarding", { observed: $("practice").value });
    dialog.close();
  } catch {}
};
$("migration").onchange = async () => {
  const file = $("migration").files[0];
  if (!file) return;
  if (file.size > 32 * 1024 * 1024) {
    error("Migration export exceeds 32 MB.");
    return;
  }
  try {
    await call("import_migration", { source: await file.text() });
    $("migration-result").textContent =
      "Imported. Your original Mac data is unchanged.";
  } catch {}
};
function element(tag, text, className) {
  const el = document.createElement(tag);
  if (text !== undefined) el.textContent = text;
  if (className) el.className = className;
  return el;
}
function renderPermissions(p) {
  const list = $("permission-list");
  if (!list.children.length) {
    for (const [kind, title, detail] of [
      ["microphone", "Microphone", "To hear you while you dictate."],
      [
        "accessibility",
        "Text insertion",
        "To type your finished words at the cursor.",
      ],
      [
        "shortcut",
        "Global shortcut",
        "To notice your talk key in another app.",
      ],
    ]) {
      const row = element("div", undefined, "permission");
      row.dataset.kind = kind;
      const label = element("div");
      label.append(element("strong", title), element("p", detail));
      const button = element("button", "Allow");
      button.onclick = async () => {
        try {
          if (kind === "accessibility" && current.permissions.wayland)
            await call("save_settings", {
              patch: { waylandCurrentCursor: true },
            });
          await call("request_permission", { kind });
        } catch {}
      };
      const status = element("span", "Allowed", "allowed");
      status.hidden = true;
      row.append(label, button, status);
      list.append(row);
    }
  }
  for (const row of list.children) {
    const value =
      p[row.dataset.kind === "accessibility" ? "insertion" : row.dataset.kind];
    row.querySelector("button").hidden = value === "granted";
    row.querySelector(".allowed").hidden = value !== "granted";
    row.querySelector("button").textContent =
      value === "unavailable"
        ? "Unavailable"
        : value === "denied"
          ? "Open settings"
          : "Allow";
    const cursorChoice =
      p.wayland &&
      row.dataset.kind === "accessibility" &&
      value === "unavailable";
    if (cursorChoice)
      row.querySelector("button").textContent = "Enable cursor insertion";
    row.querySelector("button").disabled =
      value === "unavailable" && !cursorChoice;
  }
  $("platform-note").textContent =
    p.explanation ||
    (p.microphone === "unknown"
      ? "Microphone access is verified when actual audio arrives during practice."
      : "You can change these permissions in system settings at any time.");
  $("permissions-next").disabled =
    p.insertion !== "granted" ||
    p.shortcut !== "granted" ||
    !microphoneCanPractice(p);
}
function render(data) {
  current = data;
  const s = data.view;
  const busy = s.stage !== "idle";
  $("capture-hero").hidden = !busy;
  $("home-record-meeting").disabled = busy;
  const ready =
    s.model_ready &&
    data.permissions.microphone === "granted" &&
    data.permissions.shortcut === "granted" &&
    data.permissions.insertion === "granted";
  $("readiness").classList.toggle("ready", ready);
  $("readiness-label").textContent = ready
    ? "Ready to dictate"
    : ["preparing", "loading"].includes(s.stage)
      ? "Preparing model…"
      : "Setup needed";
  const activeModel = data.models.find(
    (model) => model.id === s.settings.asrModel,
  );
  $("sidebar-model").textContent =
    `On-device · ${activeModel?.name || "Speech recognition"}`;
  const warning = s.error || s.shortcut_error || "";
  $("error").hidden = !warning;
  $("error").textContent = warning;
  $("setup-error").textContent = warning;
  const labels = {
    idle: "Hold. Speak. Release.",
    starting: "Opening your microphone…",
    recording: "Listening…",
    processing: "Transcribing on your device…",
    polishing: "Polishing your words…",
    preparing: "Preparing your speech model…",
    loading: "Loading your speech model…",
    meeting_starting: "Preparing your meeting…",
    meeting: "Recording your meeting",
    meeting_finishing: "Finishing the transcript…",
    meeting_speakers: "Separating voices on your device…",
  };
  document
    .querySelectorAll(".shortcut")
    .forEach((el) => (el.textContent = data.shortcut));
  $("capture-status").textContent = labels[s.stage] || s.stage;
  $("capture-detail").textContent =
    s.stage === "starting"
      ? "Waiting for the first real audio sample."
      : "Your words appear at the cursor. Speech stays on this device.";
  $("cancel").hidden = !busy;
  $("prepare").disabled = busy;
  $("setup-prepare").disabled = busy;
  $("model-next").disabled = !selectedModelReady();
  $("latency").textContent =
    s.release_to_text_ms == null
      ? "—"
      : (s.release_to_text_ms / 1000).toFixed(2) + " s";
  $("count").textContent = s.history.length;
  $("words").textContent = s.history
    .reduce(
      (n, r) =>
        n +
        (r.correction || r.text).trim().split(/\s+/u).filter(Boolean).length,
      0,
    )
    .toLocaleString();
  for (const block of document.querySelectorAll(".download")) {
    block.hidden = !s.progress && !["preparing", "loading"].includes(s.stage);
    if (s.progress) {
      block.querySelector("progress").value =
        s.progress.downloaded / s.progress.total;
      block.querySelector(".download-label").textContent =
        `${Math.round((s.progress.downloaded / s.progress.total) * 100)}% · ${(s.progress.downloaded / 1e6).toFixed(0)} of ${(s.progress.total / 1e6).toFixed(0)} MB`;
    } else {
      block.querySelector("progress").removeAttribute("value");
      block.querySelector(".download-label").textContent =
        s.stage === "loading"
          ? "Loading and warming the model…"
          : "Checking existing model files…";
    }
  }
  renderWorkspace(s);
  renderRecent(s.history, data.shortcut);
  syncDictionary(s.settings.vocabulary || "");
  renderPermissions(data.permissions);
  if (
    dialog.open &&
    step > 0 &&
    (data.permissions.insertion !== "granted" ||
      data.permissions.shortcut !== "granted" ||
      !microphoneCanPractice(data.permissions))
  )
    setStep(0);
  else if (dialog.open && step === 2 && !selectedModelReady()) setStep(1);
  $("finish-setup").disabled = !practiceReady();
  $("practice-status").textContent = busy
    ? labels[s.stage]
    : practiceReady()
      ? "It worked. Those words traveled from your microphone to this field."
      : "Hold the shortcut, speak, then release.";
  if (!initialized) {
    initialized = true;
    for (const id of ["model", "setup-model"]) {
      populateModels(id);
      $(id).value = s.settings.asrModel;
      $(id + "-size").textContent = size($(id).value);
    }
    refreshInputDevices().catch(() => {});
    if (!s.settings.onboardingComplete) openSetup();
  }
}
function renderRecent(history, shortcut) {
  const records = history.slice(0, 6);
  const version = JSON.stringify([records, shortcut]);
  if (version === recentVersion) return;
  recentVersion = version;
  const list = $("recent-dictations");
  list.replaceChildren();
  $("view-history").hidden = !history.length;
  if (!records.length) {
    const empty = element("div", undefined, "recent-empty");
    empty.append(
      element("h2", "No dictations yet"),
      element("p", `Hold ${shortcut} in any text field to dictate.`),
    );
    list.append(empty);
  }
  for (const record of records) {
    const row = element("article", undefined, "recent-row");
    const content = element("div");
    content.append(
      element("p", record.correction || record.text),
      element("small", new Date(record.created_at * 1000).toLocaleString()),
    );
    const copy = element("button", "Copy", "quiet");
    copy.setAttribute("aria-label", "Copy dictation");
    copy.onclick = async () => {
      try {
        await call("copy_text", { text: record.correction || record.text });
        copy.textContent = "Copied";
      } catch {}
    };
    row.append(content, copy);
    list.append(row);
  }
}
let polling = false;
async function refresh() {
  if (polling) return;
  polling = true;
  try {
    render(await invoke("status"));
  } catch (e) {
    error(e);
  } finally {
    polling = false;
  }
}
window.__TAURI__.event.listen("pressay-state", refresh);
window.addEventListener("focus", () => refreshInputDevices().catch(() => {}));
setInterval(refresh, 1000);
refresh();
