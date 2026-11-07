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
  step = 0,
  recentVersion = "",
  initialized = false,
  modelSelectionPending = null;
const dialog = $("onboarding");
// Command failures stay visible briefly; the 1 s status poll would otherwise
// replace them with the engine's own error state almost immediately.
let commandError = null;
function error(message) {
  commandError = { text: String(message), until: Date.now() + 8000 };
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
let setupPracticeEpoch = 0,
  setupPracticeReady = false,
  setupPracticeAttempt = false,
  setupShortcutActive = false,
  setupShortcutSaving = false,
  setupShortcutEpoch = 0,
  setupShortcutTimer,
  setupPreparationRequested = null,
  setupOperationError = "";
const setupPermissionKinds = ["microphone", "accessibility", "shortcut"];
const SETUP_PERMISSIONS = 1,
  SETUP_MODEL = 2,
  SETUP_PRACTICE = 3;
function setupFailure(error) {
  setupOperationError = String(error);
  $("setup-error").textContent = setupOperationError;
}
function setupPermissionAllowed(index, p = current?.permissions) {
  if (!p) return false;
  return index === 0
    ? microphoneCanPractice(p)
    : p[index === 1 ? "insertion" : "shortcut"] === "granted";
}
function permissionsReady() {
  return setupPermissionKinds.every((_, index) =>
    setupPermissionAllowed(index),
  );
}
async function setStep(value) {
  if (setupShortcutActive) await stopSetupShortcut();
  step = Math.max(0, Math.min(SETUP_PRACTICE, value));
  const epoch = ++setupPracticeEpoch;
  document.querySelectorAll("[data-setup]").forEach((panel) => {
    panel.hidden = Number(panel.dataset.setup) !== step;
  });
  document
    .querySelectorAll("[data-step]")
    .forEach((bar) =>
      bar.classList.toggle("complete", Number(bar.dataset.step) <= step),
    );
  $("setup-back").hidden = step === 0;
  $("setup-welcome-next").hidden = step !== 0;
  $("permissions-next").hidden = step !== SETUP_PERMISSIONS;
  $("model-next").hidden = step !== SETUP_MODEL;
  $("finish-setup").hidden = step !== SETUP_PRACTICE;
  setupOperationError = "";
  $("setup-error").textContent = "";
  $("onboarding").querySelector(".setup-scroll").scrollTop = 0;
  if (step === SETUP_PRACTICE) {
    setupPracticeReady = false;
    setupPracticeAttempt = false;
    $("practice").value = "";
    $("practice").disabled = true;
    renderSetup();
    try {
      await call("begin_practice");
      if (
        step === SETUP_PRACTICE &&
        epoch === setupPracticeEpoch &&
        dialog.open
      ) {
        setupPracticeReady = true;
        $("practice").disabled = false;
        $("practice").focus();
      }
    } catch (error) {
      setupFailure(error);
    }
  }
  renderSetup();
  if (step !== SETUP_PRACTICE && dialog.open)
    $("setup-title").focus({ preventScroll: true });
  if (
    step === SETUP_MODEL &&
    !selectedModelReady() &&
    current?.view.stage === "idle" &&
    setupPreparationRequested !== $("setup-model").value
  ) {
    setupPreparationRequested = $("setup-model").value;
    call("prepare_model", { id: setupPreparationRequested }).catch(
      setupFailure,
    );
  }
}
function microphoneCanPractice(p) {
  return current?.platform === "macos"
    ? p.microphone === "granted"
    : p.microphone !== "denied";
}
function openSetup() {
  if (!setupWindow) return call("open_onboarding").catch(() => {});
  setupWindowVisible = true;
  if (!dialog.open) {
    $("setup-model").value = current.view.settings.asrModel;
    $("setup-model-size").textContent = size($("setup-model").value);
    dialog.showModal();
    call("autostart_status")
      .then((enabled) => {
        $("setup-login").checked = enabled;
      })
      .catch(() => {});
  }
  setStep(0);
}
async function closeSetup() {
  await stopSetupShortcut();
  try {
    if (setupWindow) await call("close_onboarding");
    setupWindowVisible = false;
    dialog.close();
  } catch (error) {
    setupFailure(error);
  }
}
$("close-setup").onclick = closeSetup;
dialog.addEventListener("cancel", (event) => {
  event.preventDefault();
  closeSetup();
});
window.__TAURI__.event.listen("pressay-onboarding-open", () => {
  if (!setupWindow) return;
  setupWindowVisible = true;
  refresh().then(openSetup);
});
window.__TAURI__.event.listen("pressay-onboarding-hidden", () => {
  if (!setupWindow) return;
  setupWindowVisible = false;
  ++setupPracticeEpoch;
  stopSetupShortcut();
  dialog.close();
});
window.addEventListener("pagehide", stopSetupShortcut);
dialog.addEventListener("close", () => {
  ++setupPracticeEpoch;
  stopSetupShortcut();
});
dialog.addEventListener("keydown", (event) => {
  if (
    event.key !== "Enter" ||
    event.defaultPrevented ||
    setupShortcutActive ||
    ["INPUT", "TEXTAREA", "SELECT", "BUTTON"].includes(event.target.tagName)
  )
    return;
  const primary = [...dialog.querySelectorAll(".setup-footer .primary")].find(
    (button) => !button.hidden && !button.disabled,
  );
  if (primary) {
    event.preventDefault();
    primary.click();
  }
});
$("setup-back").onclick = () => setStep(step - 1);
$("setup-welcome-next").onclick = () =>
  setStep(permissionsReady() ? SETUP_MODEL : SETUP_PERMISSIONS);
$("permissions-next").onclick = () => {
  if (permissionsReady()) setStep(SETUP_MODEL);
};
$("model-next").onclick = () => {
  if (selectedModelReady() && permissionsReady()) setStep(SETUP_PRACTICE);
};
$("setup-practice-retry").onclick = () => setStep(SETUP_PRACTICE);
// Each Allow asks once, then opens the matching System Settings pane. The
// 1 s status poll picks up the change; macOS sends no callback.
const setupPermissionsRequested = new Set();
async function requestSetupPermission(index) {
  const kind = setupPermissionKinds[index];
  if (!kind) return;
  setupPermissionsRequested.add(index);
  try {
    if (kind === "accessibility" && current.permissions.wayland)
      await call("save_settings", { patch: { waylandCurrentCursor: true } });
    if (kind === "shortcut" && current.platform !== "macos")
      await call("change_shortcut", {
        binding: savedShortcut(current.view.settings),
      });
    else await call("request_permission", { kind });
  } catch (error) {
    setupFailure(error);
  }
}
document.querySelectorAll(".setup-permission-row").forEach((row) => {
  row.querySelector("button").onclick = () =>
    requestSetupPermission(Number(row.dataset.permission));
});
$("setup-restart").onclick = () => call("restart_app").catch(setupFailure);
$("setup-login").onchange = async () => {
  const enabled = $("setup-login").checked;
  try {
    await call("launch_at_login", { enabled });
  } catch (error) {
    $("setup-login").checked = !enabled;
    setupFailure(error);
  }
};
async function stopSetupShortcut() {
  if (!setupShortcutActive) return;
  setupShortcutActive = false;
  ++setupShortcutEpoch;
  setupShortcutCandidate = null;
  $("setup-shortcut-status").textContent = "";
  clearTimeout(setupShortcutTimer);
  try {
    await call("set_shortcut_capture", {
      active: false,
      kind: savedShortcut(current.view.settings).kind,
    });
  } catch {}
  renderSetup();
}
async function saveSetupShortcut(binding) {
  if (!setupShortcutActive) return;
  setupShortcutSaving = true;
  await stopSetupShortcut();
  try {
    await call("change_shortcut", { binding });
    $("setup-shortcut-status").textContent = "";
  } catch {
    $("setup-shortcut-status").textContent =
      "Shortcut was not saved. Try recording it again.";
  } finally {
    setupShortcutSaving = false;
    renderSetup();
  }
}
$("setup-shortcut").onclick = async () => {
  if (setupShortcutActive) return stopSetupShortcut();
  setupShortcutActive = true;
  const epoch = ++setupShortcutEpoch;
  const kind = savedShortcut(current.view.settings).kind;
  renderSetup();
  try {
    await call("set_shortcut_capture", { active: true, kind });
    if (
      !setupShortcutActive ||
      epoch !== setupShortcutEpoch ||
      !dialog.open ||
      step !== 4
    ) {
      await call("set_shortcut_capture", { active: false, kind });
      return;
    }
    $("setup-shortcut-status").textContent =
      "Press a key or key combination, then release. Escape cancels.";
    setupShortcutTimer = setTimeout(stopSetupShortcut, 30000);
  } catch (error) {
    setupShortcutActive = false;
    setupFailure(error);
    renderSetup();
  }
};
let setupShortcutCandidate = null;
document.addEventListener(
  "keydown",
  (event) => {
    if (!setupShortcutActive) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (event.key === "Escape") {
      stopSetupShortcut();
      return;
    }
    if (savedShortcut(current.view.settings).kind === "chord") {
      const binding = chordForEvent(event);
      if (binding) setupShortcutCandidate = { binding, code: event.code };
    }
  },
  true,
);
document.addEventListener(
  "keyup",
  (event) => {
    if (!setupShortcutActive) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (setupShortcutCandidate?.code === event.code) {
      const binding = setupShortcutCandidate.binding;
      setupShortcutCandidate = null;
      saveSetupShortcut(binding);
    }
  },
  true,
);
window.__TAURI__.event.listen("pressay-shortcut-captured", ({ payload }) => {
  if (!setupShortcutActive) return;
  if (payload.cancelled) stopSetupShortcut();
  else if (payload.binding) saveSetupShortcut(payload.binding);
});
window.addEventListener("blur", stopSetupShortcut);
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
    renderSetup();
    if (id === "model") {
      modelSelectionPending = $(id).value;
      call("prepare_model", { id: $(id).value }).catch(() => {});
    }
  };
$("prepare").onclick = () =>
  call("prepare_model", { id: $("model").value }).catch(() => {});
$("setup-prepare").onclick = () => {
  setupOperationError = "";
  call("prepare_model", { id: $("setup-model").value }).catch(setupFailure);
};
function practiceReady() {
  const p = current?.view.practice;
  return !!(
    setupPracticeReady &&
    setupPracticeAttempt &&
    p?.received_audio &&
    p?.inserted &&
    p?.in_app &&
    p?.recognized_text.trim() &&
    $("practice").value.trim() === p.recognized_text.trim() &&
    selectedModelReady() &&
    permissionsReady()
  );
}
$("practice").addEventListener("input", renderSetup);
$("practice").addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    event.preventDefault();
    call("cancel").catch(() => {});
  }
});
$("finish-setup").onclick = async () => {
  try {
    await call("complete_onboarding", { observed: $("practice").value });
    await closeSetup();
  } catch (error) {
    setupFailure(error);
  }
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
function renderPermissions() {
  renderSetup();
}
function renderSetup() {
  if (!current) return;
  const mac = current.platform === "macos";
  const p = current.permissions;
  const s = current.view;
  if (
    step === SETUP_PRACTICE &&
    setupPracticeReady &&
    ["starting", "recording"].includes(s.stage)
  )
    setupPracticeAttempt = true;
  const complete = practiceReady();
  $("setup-step-label").textContent =
    step === 0 ? "WELCOME TO PRESSAY" : `STEP ${step} OF 3`;
  $("setup-title").textContent =
    step === 0
      ? "Your voice. Your words."
      : step === SETUP_PERMISSIONS
        ? "Allow access"
        : step === SETUP_MODEL
          ? "Speech model"
          : complete
            ? "You’re ready"
            : "Give it a try";
  $("setup-description").textContent =
    step === 0
      ? "Hold a key, speak, release. Pressay types it at your cursor."
      : step === SETUP_PERMISSIONS
        ? "Pressay needs these to hear you and type for you."
        : step === SETUP_MODEL
          ? "Downloads once, then runs offline."
          : complete
            ? "Dictate anywhere with your talk key."
            : `Hold ${current.shortcut}, speak, then release.`;
  $("setup-private-copy").textContent =
    `Transcribed on your ${mac ? "Mac" : "device"}. No account needed.`;
  $("setup-login-detail").textContent = mac
    ? "Ready every time you open your Mac."
    : "Ready every time you sign in.";
  const titles = [
    "Microphone",
    mac ? "Accessibility" : p.wayland ? "Keyboard control" : "Text insertion",
    mac ? "Input Monitoring" : "Global shortcut",
  ];
  const details = [
    "Hears you while you hold the key",
    "Types text at your cursor",
    "Notices your talk key in any app",
  ];
  let stuck = false;
  document.querySelectorAll(".setup-permission-row").forEach((row) => {
    const index = Number(row.dataset.permission);
    const value =
      p[index === 1 ? "insertion" : index === 2 ? "shortcut" : "microphone"];
    const allowed = setupPermissionAllowed(index);
    const cursorChoice = index === 1 && p.wayland && value !== "granted";
    const deferred = index === 0 && !mac && value === "unknown";
    const unavailable = value === "unavailable" && !cursorChoice;
    row.querySelector(".setup-permission-title").textContent = titles[index];
    row.querySelector(".setup-permission-detail").textContent = details[index];
    const state = row.querySelector(".setup-permission-state");
    state.textContent = allowed
      ? "✓"
      : deferred
        ? "Checked when you try it"
        : unavailable
          ? "Unavailable"
          : "";
    state.setAttribute("aria-label", allowed ? "Allowed" : state.textContent);
    state.classList.toggle("allowed", allowed);
    const button = row.querySelector("button");
    button.hidden = allowed || deferred || unavailable;
    button.textContent = cursorChoice ? "Enable" : "Allow";
    if (!allowed && mac && index > 0 && setupPermissionsRequested.has(index))
      stuck = true;
  });
  $("platform-note").textContent = !mac && p.explanation ? p.explanation : "";
  $("platform-note").hidden = !$("platform-note").textContent;
  $("setup-permission-recovery").hidden = !stuck;
  $("permissions-next").disabled = !permissionsReady();
  $("setup-shortcut").textContent = setupShortcutActive
    ? "Press a key…"
    : current.shortcut;
  $("setup-shortcut").disabled =
    setupShortcutSaving || (s.stage !== "idle" && !setupShortcutActive);
  for (const option of $("setup-model").options) {
    const model = current.models.find((model) => model.id === option.value);
    if (model && option.textContent !== model.name)
      option.textContent = model.name;
  }
  $("setup-model-ready").hidden = !selectedModelReady();
  $("setup-model-status").textContent = selectedModelReady()
    ? "Ready"
    : s.stage === "loading"
      ? "Loading and warming the model…"
      : s.stage === "preparing"
        ? "Downloading…"
        : "Not downloaded yet";
  $("setup-prepare").hidden =
    selectedModelReady() || ["preparing", "loading"].includes(s.stage);
  $("model-next").disabled =
    !selectedModelReady() ||
    !permissionsReady() ||
    setupShortcutActive ||
    setupShortcutSaving;
  $("finish-setup").disabled = !complete;
  $("practice-status").textContent = s.stage.startsWith("meeting")
    ? "Stop the Notetaker first"
    : s.stage === "recording"
      ? "Listening…"
      : s.stage === "starting"
        ? "Opening microphone…"
        : "Microphone off";
  $("setup-practice-mic").setAttribute(
    "href",
    s.stage === "recording" ? "#setup-mic" : "#setup-mic-off",
  );
  $("practice-status").parentElement.classList.toggle(
    "is-live",
    s.stage === "recording",
  );
  $("setup-practice-evidence").textContent = complete ? "✓ It works" : "";
  $("setup-practice-evidence").classList.toggle("setup-success", complete);
  $("setup-error").textContent =
    setupOperationError ||
    (step >= SETUP_MODEL ? s.error || s.shortcut_error || "" : "");
}
function renderSetupWindow(data) {
  const s = data.view;
  if (!initialized) {
    initialized = true;
    populateModels("setup-model");
    $("setup-model").value = s.settings.asrModel;
    $("setup-model-size").textContent = size(s.settings.asrModel);
    if (setupWindowVisible) openSetup();
  }
  $("setup-prepare").disabled = s.stage !== "idle";
  const download = dialog.querySelector(".download");
  download.hidden = !s.progress && !["preparing", "loading"].includes(s.stage);
  if (s.progress) {
    download.querySelector("progress").value =
      s.progress.downloaded / s.progress.total;
    download.querySelector(".download-label").textContent =
      `${Math.round((s.progress.downloaded / s.progress.total) * 100)}%`;
  } else {
    download.querySelector("progress").removeAttribute("value");
    download.querySelector(".download-label").textContent =
      s.stage === "loading"
        ? "Loading and warming the model…"
        : "Checking existing model files…";
  }
  if (dialog.open && step >= SETUP_MODEL && !permissionsReady())
    setStep(SETUP_PERMISSIONS);
  else if (dialog.open && step === SETUP_PRACTICE && !selectedModelReady())
    setStep(SETUP_MODEL);
  renderSetup();
}
function render(data) {
  current = data;
  if (setupWindow) {
    document.body.dataset.platform = data.platform;
    renderSetupWindow(data);
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
  if (dialog.open && step >= SETUP_MODEL && !permissionsReady())
    setStep(SETUP_PERMISSIONS);
  else if (dialog.open && step === SETUP_PRACTICE && !selectedModelReady())
    setStep(SETUP_MODEL);
  renderSetup();
  if (!initialized) {
    initialized = true;
    for (const id of ["model", "setup-model"]) {
      populateModels(id);
      $(id).value = s.settings.asrModel;
      $(id + "-size").textContent = size($(id).value);
    }
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
