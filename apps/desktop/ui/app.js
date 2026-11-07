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
    heroKey = "";
    historyKey = "";
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
  // Older entry points (tray, notifications) still name the retired pages.
  if (page === "general" || page === "ai") {
    openSettings(page === "ai" ? "ai" : "dictation");
    return;
  }
  if (page === "history") page = "dictation";
  if ($("settings-dialog").open) $("settings-dialog").close();
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
$("readiness").onclick = () => openSetup();
// The first-run tour lives in onboarding.js and its own window.
function openSetup() {
  return call("open_onboarding").catch(() => {});
}
$("cancel").onclick = () => call("cancel").catch(() => {});
$("hero-copy").onclick = async () => {
  const record = current?.view.history[0];
  if (!record) return;
  try {
    await call("copy_text", { text: record.correction || record.text });
    flashHeroStatus("Copied");
  } catch {}
};
$("hero-paste").onclick = async () => {
  const record = current?.view.history[0];
  if (!record) return;
  flashHeroStatus("Returning to the original app…", 0);
  try {
    flashHeroStatus(await call("retry_dictation", { id: record.id }));
  } catch (e) {
    flashHeroStatus(String(e));
  }
};
let heroStatusTimer;
function flashHeroStatus(text, ms = 2400) {
  clearTimeout(heroStatusTimer);
  $("hero-status").textContent = text || "";
  if (ms) heroStatusTimer = setTimeout(() => ($("hero-status").textContent = ""), ms);
}
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
let editingWord = null;
function drawDictionary() {
  const chips = $("dictionary-rows");
  chips.replaceChildren();
  const rows = dictionaryRows.filter((row) => row.word.trim() || row === editingWord);
  $("dictionary-empty").hidden = rows.length !== 0;
  for (const row of rows) {
    const chip = element("button", undefined, "word-chip");
    chip.type = "button";
    chip.append(
      element("b", row.word || "New word"),
      element(
        "span",
        row.aliases.trim() ? `sounds like ${row.aliases.trim()}` : "spelled as written",
      ),
    );
    chip.classList.toggle("editing", row === editingWord);
    chip.setAttribute("aria-label", `Edit ${row.word || "new word"}`);
    chip.onclick = () => openWordEditor(row, chip);
    chips.append(chip);
  }
}
function openWordEditor(row, chip) {
  editingWord = row;
  const editor = $("word-editor"),
    page = editor.parentElement;
  $("word-editor-word").value = row.word;
  $("word-editor-aliases").value = row.aliases;
  editor.hidden = false;
  for (const other of $("dictionary-rows").children)
    other.classList.toggle("editing", other === chip);
  const box = chip.getBoundingClientRect(),
    frame = page.getBoundingClientRect();
  editor.style.left = `${Math.min(box.left - frame.left, frame.width - 320)}px`;
  editor.style.top = `${box.bottom - frame.top + 8}px`;
  $("word-editor-word").focus();
}
function closeWordEditor() {
  if (!editingWord) return;
  const row = editingWord;
  editingWord = null;
  $("word-editor").hidden = true;
  if (!row.word.trim())
    dictionaryRows = dictionaryRows.filter((candidate) => candidate !== row);
  drawDictionary();
  queueDictionarySave();
}
$("word-editor-word").oninput = () => {
  if (!editingWord) return;
  editingWord.word = $("word-editor-word").value;
  queueDictionarySave();
};
$("word-editor-aliases").oninput = () => {
  if (!editingWord) return;
  editingWord.aliases = $("word-editor-aliases").value;
  queueDictionarySave();
};
$("word-editor-done").onclick = closeWordEditor;
$("word-editor-remove").onclick = () => {
  if (!editingWord) return;
  editingWord.word = "";
  closeWordEditor();
};
$("word-editor").onkeydown = (event) => {
  if (event.key === "Enter" || event.key === "Escape") {
    event.preventDefault();
    closeWordEditor();
  }
};
document.addEventListener("pointerdown", (event) => {
  if (
    editingWord &&
    !$("word-editor").contains(event.target) &&
    !event.target.closest?.(".word-chip")
  )
    closeWordEditor();
});
function syncDictionary(source) {
  if (
    editingWord ||
    dictionaryDirty ||
    dictionarySaving ||
    dictionarySaved === source
  )
    return;
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
$("dictionary-add-form").onsubmit = (event) => {
  event.preventDefault();
  const word = $("dictionary-add").value.trim();
  if (!word) return;
  const existing = dictionaryRows.find(
    (row) => row.word.trim().toLocaleLowerCase() === word.toLocaleLowerCase(),
  );
  if (!existing) dictionaryRows.push({ word, aliases: "" });
  $("dictionary-add").value = "";
  drawDictionary();
  queueDictionarySave();
  const chip = [...$("dictionary-rows").children].find(
    (chip) => chip.querySelector("b").textContent === (existing?.word || word),
  );
  chip?.scrollIntoView({ block: "nearest" });
  chip?.classList.add("added");
  setTimeout(() => chip?.classList.remove("added"), 900);
};
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
  const ready =
    s.model_ready &&
    data.permissions.microphone === "granted" &&
    data.permissions.shortcut === "granted" &&
    data.permissions.insertion === "granted";
  const preparing = ["preparing", "loading"].includes(s.stage);
  $("readiness").hidden = ready;
  $("readiness").classList.toggle("preparing", preparing);
  $("readiness-label").textContent = preparing
    ? "Preparing model…"
    : "Finish setup";
  renderToast(s);
  renderHero(s, data, ready);
  $("prepare").disabled = busy;
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
  syncDictionary(s.settings.vocabulary || "");
  if (!initialized) {
    initialized = true;
    populateModels("model");
    $("model").value = s.settings.asrModel;
    $("model-size").textContent = size($("model").value);
    refreshInputDevices().catch(() => {});
  }
}
// Problems you need to act on stay in the title bar (readiness). Everything
// else is news: it shows once as a toast and then gets out of the way.
let toastShown = "",
  toastTimer;
function renderToast(s) {
  const latest = s.history[0];
  const message =
    commandError && Date.now() < commandError.until
      ? commandError.text
      : s.error || s.shortcut_error || "";
  // A warning saved on the newest dictation is already shown on the hero.
  const onRecord =
    latest && dictationWarning(latest) &&
    message.startsWith(dictationWarning(latest));
  if (!message || onRecord) {
    if (!message) toastShown = "";
    return;
  }
  if (message === toastShown) return;
  toastShown = message;
  showToast(message);
}
function showToast(message) {
  const toast = $("error");
  toast.textContent = message;
  toast.hidden = false;
  toast.classList.remove("leaving");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    toast.classList.add("leaving");
    toastTimer = setTimeout(() => (toast.hidden = true), 300);
  }, 6000);
}
$("error").onclick = () => ($("error").hidden = true);
function keyParts(label = "") {
  const mac = current?.platform === "macos";
  const symbols = mac
    ? { option: "⌥", alt: "⌥", command: "⌘", cmd: "⌘", shift: "⇧", control: "⌃", ctrl: "⌃", fn: "fn", space: "␣" }
    : { option: "Alt", alt: "Alt", control: "Ctrl", ctrl: "Ctrl", shift: "Shift", space: "Space", command: "Win", super: "Win" };
  const parts = label.split("+").map((part) => part.trim()).filter(Boolean);
  if (parts.length > 1)
    return {
      glyph: parts.map((part) => symbols[part.toLowerCase()] || part).join(mac ? "" : "+"),
      name: "",
    };
  const word = (parts[0] || "").replace(/^(Left|Right)\s+/u, "");
  const symbol = symbols[word.toLowerCase()];
  return symbol
    ? { glyph: symbol, name: symbol === word ? "" : word.toLowerCase() }
    : { glyph: word, name: "" };
}
let heroLevels = [];
window.__TAURI__.event.listen("pressay-levels", ({ payload }) => {
  const values = Array.isArray(payload)
    ? payload
    : payload?.audio_levels || payload?.levels || [];
  heroLevels = values.map((value) => Math.max(0, Math.min(1, Number(value) || 0)));
});
function drawHeroWave() {
  const bars = $("hero-wave").children;
  const time = performance.now() / 1000;
  for (let i = 0; i < bars.length; i++) {
    const level = heroLevels.length
      ? heroLevels[Math.floor((i / bars.length) * heroLevels.length)]
      : 0;
    const idle = 0.12 + 0.08 * Math.sin(time * 3 + i * 0.7);
    const shape = 0.55 + 0.45 * Math.sin((i / (bars.length - 1)) * Math.PI);
    bars[i].style.height = `${Math.round(6 + 58 * Math.max(idle, level) * shape)}px`;
  }
}
setInterval(() => {
  if (!$("hero-wave").hidden) drawHeroWave();
}, 90);
let recordingSince = 0,
  heroKey = "";
function renderHero(s, data, ready) {
  const listening = ["starting", "recording"].includes(s.stage);
  if (listening && !recordingSince) recordingSince = Date.now();
  if (!listening) recordingSince = 0;
  const key = keyParts(data.shortcut);
  $("keycap-glyph").textContent = key.glyph;
  $("keycap-name").textContent = key.name;
  $("keycap").classList.toggle("down", listening);
  $("keycap").classList.toggle("wide", key.glyph.length > 2);
  $("keycap-hint").textContent = listening
    ? "Release to type"
    : `Hold ${data.shortcut || "your talk key"} to talk`;
  $("cancel").hidden = !["starting", "recording", "processing", "polishing"].includes(s.stage);
  $("hero-wave").hidden = !listening;
  const record = s.history[0];
  let label, text, quiet = false;
  if (listening) {
    label = "Listening";
    const seconds = Math.floor((Date.now() - recordingSince) / 1000);
    text = "";
    setHeroMeta(null, `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`, "Your words appear where your cursor is when you let go.");
  } else if (["processing", "polishing"].includes(s.stage)) {
    label = s.stage === "polishing" ? "Cleaning up" : "Transcribing";
    text = s.stage === "polishing" ? "Polishing your words…" : "Turning your speech into text…";
    quiet = true;
    setHeroMeta(null, "", "");
  } else if (["preparing", "loading"].includes(s.stage)) {
    label = "Getting ready";
    text = s.progress
      ? `Downloading your speech model, ${Math.round((s.progress.downloaded / s.progress.total) * 100)}%`
      : "Loading your speech model…";
    quiet = true;
    setHeroMeta(null, "", "This happens once. It runs on your device after that.");
  } else if (!ready) {
    label = "Almost ready";
    text = "Pressay needs a couple of permissions before you can dictate.";
    quiet = true;
    setHeroMeta(null, "", "");
  } else if (record) {
    label = "Last dictation";
    text = record.correction || record.text;
    setHeroMeta(record, "", "");
  } else {
    label = "Ready";
    text = `Hold ${data.shortcut || "your talk key"} and start talking.`;
    quiet = true;
    setHeroMeta(null, "", "Release, and Pressay types where your cursor is.");
  }
  $("hero-label").textContent = label;
  $("hero-text").textContent = text;
  $("hero-text").hidden = !text;
  $("hero-text").classList.toggle("quiet", quiet);
  const showActions = label === "Last dictation";
  $("hero-actions").hidden = !showActions;
  const warning = showActions ? dictationWarning(record) : "";
  $("hero-note").hidden = !warning;
  if (warning) $("hero-note").replaceChildren(...warningNote(warning).childNodes);
  if (!ready && !busyStage(s.stage)) {
    if (!$("hero-setup")) {
      const setup = element("button", "Finish setup", "primary");
      setup.id = "hero-setup";
      setup.type = "button";
      setup.onclick = () => openSetup();
      $("hero-actions").before(setup);
    }
  } else $("hero-setup")?.remove();
}
function busyStage(stage) {
  return stage !== "idle";
}
function setHeroMeta(record, timer, text) {
  const key = JSON.stringify([record?.id, record?.target, timer, text, Math.floor(Date.now() / 60000), appMetadata[record?.target]?.icon?.length]);
  if (key === heroKey) return;
  heroKey = key;
  const meta = $("hero-meta");
  meta.replaceChildren();
  if (record) {
    const metadata = appMetadata[record.target];
    if (metadata?.icon?.startsWith("data:image/")) {
      const icon = element("img", undefined, "app-icon");
      icon.src = metadata.icon;
      icon.alt = "";
      meta.append(icon);
    }
    const name = historyAppName(record);
    if (name) meta.append(element("span", name));
    const age = Math.max(0, Math.round((Date.now() / 1000 - record.created_at) / 60));
    meta.append(
      element(
        "span",
        new Intl.RelativeTimeFormat(navigator.language, { numeric: "auto" }).format(
          age < 60 ? -age : age < 1440 ? -Math.round(age / 60) : -Math.round(age / 1440),
          age < 60 ? "minute" : age < 1440 ? "hour" : "day",
        ),
        "faint",
      ),
    );
  }
  if (timer) meta.append(element("strong", timer, "hero-timer"));
  if (text) meta.append(element("span", text));
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
