"use strict";
const { invoke } = window.__TAURI__.core;
const $ = (id) => document.getElementById(id);
const setupWindow = new URLSearchParams(window.location.search).has(
  "onboarding",
);
let setupWindowVisible = setupWindow;
if (setupWindow) document.body.classList.add("onboarding-window");
const appMetadata = Object.create(null),
  metadataRequested = new Set();
let metadataPending = false;
async function refreshAppMetadata(history) {
  if (metadataPending) return;
  const targets = [
    ...new Set(
      history
        .map((record) => record.target)
        .filter((target) => target && !metadataRequested.has(target)),
    ),
  ].slice(0, 128);
  if (!targets.length) return;
  metadataPending = true;
  targets.forEach((target) => metadataRequested.add(target));
  try {
    Object.assign(
      appMetadata,
      (await invoke("history_app_metadata", { targets })) || {},
    );
    renderRecent(current.view.history, current.shortcut);
    renderHistory(current.view);
  } catch {
  } finally {
    metadataPending = false;
  }
}
let current,
  recentVersion = "",
  initialized = false,
  modelSelectionPending = null;
// Command failures stay visible briefly; the 1 s status poll would otherwise
// replace them with the engine's own error state almost immediately.
let commandError = null;
function error(message) {
  commandError = { text: String(message), until: Date.now() + 8000 };
  $("error").textContent = String(message);
  $("error").hidden = false;
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
  if (changed && typeof stopShortcutCapture === "function")
    stopShortcutCapture();
  document
    .querySelectorAll("[data-panel]")
    .forEach((p) => (p.hidden = p.dataset.panel !== page));
  document.querySelectorAll("[data-page]").forEach((b) => {
    b.classList.toggle("active", b.dataset.page === page);
    b.setAttribute("aria-current", b.dataset.page === page ? "page" : "false");
  });
  if (changed) document.querySelector("main").scrollTop = 0;
  if (page !== "meetings") $("ask-dialog").close();
}
document
  .querySelectorAll("[data-page]")
  .forEach((b) => b.addEventListener("click", () => navigate(b.dataset.page)));
$("view-history").onclick = () => navigate("history");
$("home-record-meeting").onclick = () => {
  navigate("meetings");
  $("start-meeting").click();
};
// The first-run tour lives in onboarding.js and its own window.
function openSetup() {
  return call("open_onboarding").catch(() => {});
}
$("cancel").onclick = () => call("cancel").catch(() => {});
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
    $("dictionary-result").textContent = dictionaryDirty ? "Saving…" : "";
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
$("model").onchange = () => {
  $("model-size").textContent = size($("model").value);
  modelSelectionPending = $("model").value;
  call("prepare_model", { id: $("model").value }).catch(() => {});
};
$("prepare").onclick = () =>
  call("prepare_model", { id: $("model").value }).catch(() => {});
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
  } catch {
  } finally {
    $("migration").value = "";
  }
};
function element(tag, text, className) {
  const el = document.createElement(tag);
  if (text !== undefined) el.textContent = text;
  if (className) el.className = className;
  return el;
}
function render(data) {
  current = data;
  if (setupWindow) {
    document.body.dataset.platform = data.platform;
    window.pressayOnboarding?.render(data);
    return;
  }
  document.body.dataset.platform = data.platform;
  const s = data.view;
  refreshAppMetadata(s.history);
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
  const warning =
    s.error ||
    s.shortcut_error ||
    (commandError && Date.now() < commandError.until ? commandError.text : "");
  $("error").hidden = !warning;
  $("error").textContent = warning;
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
  if (!initialized) {
    initialized = true;
    populateModels("model");
    $("model").value = s.settings.asrModel;
    $("model-size").textContent = size($("model").value);
    refreshInputDevices().catch(() => {});
  }
}
function renderRecent(history, shortcut) {
  const records = history.slice(0, 6);
  const version = JSON.stringify([
    records,
    shortcut,
    appMetadata,
    Math.floor(Date.now() / 60000),
  ]);
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
    const metadata = appMetadata[record.target];
    const icon = element(
      metadata?.icon?.startsWith("data:image/") ? "img" : "span",
      undefined,
      "app-icon",
    );
    icon.setAttribute("aria-hidden", "true");
    if (icon.tagName === "IMG") {
      icon.src = metadata.icon;
      icon.alt = "";
    } else {
      icon.classList.add("placeholder");
      icon.textContent = "▢";
    }
    const content = element("div");
    const age = Math.max(
      0,
      Math.round((Date.now() / 1000 - record.created_at) / 60),
    );
    const relative = new Intl.RelativeTimeFormat(navigator.language, {
      numeric: "auto",
    }).format(
      age < 60
        ? -age
        : age < 1440
          ? -Math.round(age / 60)
          : -Math.round(age / 1440),
      age < 60 ? "minute" : age < 1440 ? "hour" : "day",
    );
    content.append(
      element("p", record.correction || record.text),
      element(
        "small",
        [historyAppName(record), relative, `${Math.round(record.duration)} sec`]
          .filter(Boolean)
          .join(" · "),
      ),
    );
    const copy = element("button", undefined, "quiet copy-icon");
    copy.append(historyIcon("copy"));
    copy.setAttribute("aria-label", "Copy dictation");
    copy.onclick = async () => {
      try {
        await call("copy_text", { text: record.correction || record.text });
        copy.textContent = "✓";
        setTimeout(() => {
          if (copy.isConnected) copy.replaceChildren(historyIcon("copy"));
        }, 1200);
      } catch {}
    };
    row.append(icon, content, copy);
    list.append(row);
  }
}
let polling = false;
async function refresh() {
  if (setupWindow && !setupWindowVisible) return;
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
window.__TAURI__.event.listen("pressay-navigate", ({ payload }) => {
  if (setupWindow) return;
  if (payload === "onboarding") openSetup();
  else if (document.querySelector(`[data-page="${payload}"]`))
    navigate(payload);
});
window.addEventListener("focus", () => {
  if (setupWindow) {
    setupWindowVisible = true;
    refresh();
  } else refreshInputDevices().catch(() => {});
});
setInterval(refresh, 1000);
refresh();
