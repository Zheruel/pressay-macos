"use strict";
const { invoke } = window.__TAURI__.core;
const $ = (id) => document.getElementById(id);
let current,
  step = 0,
  historyVersion = "",
  meetingsVersion = "",
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
  document
    .querySelectorAll("[data-panel]")
    .forEach((p) => (p.hidden = p.dataset.panel !== page));
  document.querySelectorAll("[data-page]").forEach((b) => {
    b.classList.toggle("active", b.dataset.page === page);
    b.setAttribute("aria-current", b.dataset.page === page ? "page" : "false");
  });
}
document
  .querySelectorAll("[data-page]")
  .forEach((b) => b.addEventListener("click", () => navigate(b.dataset.page)));
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
  if (!dialog.open) dialog.showModal();
  const p = current?.permissions;
  const granted =
    p &&
    p.shortcut === "granted" &&
    p.insertion === "granted" &&
    microphoneCanPractice(p);
  setStep(granted ? (current.view.model_ready ? 2 : 1) : 0);
}
$("setup-again").onclick = openSetup;
$("close-setup").onclick = () => dialog.close();
$("setup-back").onclick = () => setStep(Math.max(0, step - 1));
$("permissions-next").onclick = () => setStep(1);
$("model-next").onclick = () => setStep(2);
$("cancel").onclick = () => call("cancel").catch(() => {});
$("quit").onclick = () => call("quit").catch(() => {});
$("save-vocabulary").onclick = async () => {
  try {
    await call("save_settings", {
      patch: { vocabulary: $("vocabulary").value },
    });
    $("dictionary-result").textContent = "Dictionary saved.";
  } catch {}
};
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
for (const id of ["model", "setup-model"])
  $(id).onchange = () => ($(id + "-size").textContent = size($(id).value));
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
  const ready =
    s.model_ready &&
    data.permissions.microphone === "granted" &&
    data.permissions.shortcut === "granted" &&
    data.permissions.insertion === "granted";
  $("readiness").classList.toggle("ready", ready);
  $("readiness-label").textContent = ready
    ? "Ready to dictate"
    : "Setup needed";
  $("error").hidden = !s.error;
  if (s.error) {
    $("error").textContent = s.error;
    $("setup-error").textContent = s.error;
  }
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
  $("model-next").disabled = !s.model_ready;
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
  if (document.activeElement !== $("vocabulary"))
    $("vocabulary").value = s.settings.vocabulary || "";
  renderPermissions(data.permissions);
  if (
    dialog.open &&
    step > 0 &&
    (data.permissions.insertion !== "granted" ||
      data.permissions.shortcut !== "granted" ||
      !microphoneCanPractice(data.permissions))
  )
    setStep(0);
  else if (dialog.open && step === 2 && !s.model_ready) setStep(1);
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
    call("input_devices")
      .then((devices) => {
        for (const d of devices) {
          const o = element("option", d);
          o.value = d;
          $("input-device").append(o);
        }
        $("input-device").value = s.settings.inputDevice || "";
      })
      .catch(() => {});
    if (!s.settings.onboardingComplete) openSetup();
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
setInterval(refresh, 1000);
refresh();
