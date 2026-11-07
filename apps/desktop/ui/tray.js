"use strict";
const $ = (id) => document.getElementById(id);
const invoke = window.__TAURI__.core.invoke;
let state,
  recentKey = "",
  menuRecord,
  refreshing = false,
  aiSaving = false,
  updateBusy = false;
const metadata = new Map(),
  copied = new Set();
function error(value) {
  $("tray-error").textContent = String(value);
  $("tray-error").hidden = false;
}
async function call(command, args = {}) {
  try {
    return await invoke(command, args);
  } catch (e) {
    error(e);
    throw e;
  }
}
function node(tag, text, className) {
  const n = document.createElement(tag);
  if (text !== undefined) n.textContent = text;
  if (className) n.className = className;
  return n;
}
function text(record) {
  return record.correction || record.text || "";
}
async function copy(record) {
  await call("copy_text", { text: text(record) });
  copied.add(record.id);
  recentKey = "";
  render();
}
function closeMenu() {
  const menu = $("record-menu");
  menu.hidden = true;
  document.body.append(menu);
  menuRecord = null;
}
function showRecordMenu(event, record) {
  event.preventDefault();
  menuRecord = record;
  const menu = $("record-menu");
  menu.hidden = false;
  const row = event.currentTarget;
  row.append(menu);
  menu.classList.toggle(
    "above",
    row.getBoundingClientRect().bottom + menu.offsetHeight > innerHeight - 8,
  );
  menu.querySelector('[data-action="paste"]').disabled =
    state.view.stage !== "idle";
  menu.querySelector("button").focus();
}
function render() {
  if (!state) return;
  const s = state.view,
    permissions = state.permissions;
  const allowed =
    permissions.microphone === "granted" &&
    permissions.shortcut === "granted" &&
    permissions.insertion === "granted";
  $("ready-dot").classList.toggle("ready", s.model_ready && allowed);
  $("ready-dot").setAttribute(
    "aria-label",
    s.model_ready && allowed ? "Ready to dictate" : "Setup needs attention",
  );
  $("setup").hidden = s.settings.onboardingComplete === true;
  $("ready-content").hidden = !$("setup").hidden;
  $("attention").hidden = s.model_ready && allowed;
  $("attention").textContent = allowed
    ? "⚠ Speech model needs attention"
    : "⚠ A permission needs attention";
  $("attention").onclick = () =>
    call("show_workspace", { page: allowed ? "general" : "onboarding" }).catch(
      () => {},
    );
  $("talk-key").textContent =
    state.shortcut || s.shortcut_label || "Set a talk key";
  if (!aiSaving) $("cleanup").checked = s.settings.claudeCleanup === true;
  $("settings-shortcut").textContent =
    state.platform === "macos" ? "⌘," : "Ctrl+,";
  $("quit-shortcut").textContent = state.platform === "macos" ? "⌘Q" : "Ctrl+Q";
  const meeting = s.stage.startsWith("meeting");
  $("meeting-label").textContent =
    s.stage === "meeting_starting"
      ? "Cancel Notetaker setup"
      : meeting
        ? "Stop Notetaker"
        : "Start Notetaker";
  $("meeting-icon").textContent = meeting ? "■" : "＋";
  $("meeting").disabled = !["idle", "meeting", "meeting_starting"].includes(
    s.stage,
  );
  const records = s.history.slice(0, 2);
  const key = JSON.stringify([records, [...copied], [...metadata]]);
  if (key === recentKey) return;
  recentKey = key;
  closeMenu();
  $("recent").replaceChildren();
  if (!records.length)
    $("recent").append(node("p", "Your dictations appear here.", "empty"));
  for (const record of records) {
    const row = node("div", undefined, "recent-row");
    row.tabIndex = 0;
    row.setAttribute(
      "aria-label",
      "Recent dictation. Press Shift+F10 for actions.",
    );
    row.oncontextmenu = (e) => showRecordMenu(e, record);
    row.onkeydown = (e) => {
      if (e.key === "ContextMenu" || (e.shiftKey && e.key === "F10"))
        showRecordMenu(e, record);
    };
    const body = node("div", undefined, "recent-copy");
    body.append(node("p", text(record)));
    const info = metadata.get(record.target),
      line = node("div", undefined, "recent-metadata");
    if (info?.icon) {
      const img = node("img");
      img.src = info.icon;
      img.alt = "";
      line.append(img);
    } else {
      const icon = node("span", "▧", "app-placeholder");
      icon.setAttribute("aria-hidden", "true");
      line.append(icon);
    }
    const time = new Date(record.created_at * 1000).toLocaleTimeString(
      undefined,
      { hour: "numeric", minute: "2-digit" },
    );
    line.append(
      node(
        "span",
        copied.has(record.id)
          ? "Copied"
          : [info?.name, time].filter(Boolean).join(" · "),
      ),
    );
    body.append(line);
    const button = node("button", undefined, "copy");
    button.title = "Copy dictation";
    button.setAttribute("aria-label", "Copy dictation");
    button.innerHTML = copied.has(record.id)
      ? "✓"
      : '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.3"><rect x="6" y="6" width="10" height="11" rx="2"/><path d="M12 6V4a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h2"/></svg>';
    button.onclick = () => copy(record).catch(() => {});
    row.append(body, button);
    $("recent").append(row);
  }
  const missing = [
    ...new Set(
      records.map((r) => r.target).filter((id) => id && !metadata.has(id)),
    ),
  ];
  if (missing.length) {
    for (const id of missing) metadata.set(id, null);
    invoke("history_app_metadata", { targets: missing })
      .then((values) => {
        for (const [id, value] of Object.entries(values || {}))
          metadata.set(id, value);
        recentKey = "";
        render();
      })
      .catch(() => {});
  }
}
async function refresh() {
  if (refreshing) return;
  refreshing = true;
  try {
    state = await invoke("status");
    render();
  } catch (e) {
    error(e);
  } finally {
    refreshing = false;
  }
}
$("cleanup").onchange = async () => {
  aiSaving = true;
  $("cleanup").disabled = true;
  try {
    await call("save_settings", {
      patch: { claudeCleanup: $("cleanup").checked },
    });
  } catch {
  } finally {
    aiSaving = false;
    $("cleanup").disabled = false;
    refresh();
  }
};
$("continue-setup").onclick = () =>
  call("show_workspace", { page: "onboarding" }).catch(() => {});
$("open").onclick = () =>
  call("show_workspace", { page: "dictation" }).catch(() => {});
$("settings").onclick = () =>
  call("show_workspace", { page: "general" }).catch(() => {});
$("meeting").onclick = async () => {
  try {
    if (state.view.stage === "meeting_starting") await call("cancel");
    else if (state.view.stage.startsWith("meeting")) await call("stop_meeting");
    else {
      await call("start_meeting", { kind: "meeting" });
      await call("show_workspace", { page: "meetings" });
    }
    await refresh();
  } catch {}
};
$("quit").onclick = () => call("quit").catch(() => {});
$("check-update").onclick = async () => {
  if (updateBusy) return;
  updateBusy = true;
  $("check-update").disabled = true;
  $("check-update").textContent = "Checking for updates…";
  try {
    const update = await call("check_update");
    $("update-message").textContent = update.message;
    $("update-notice").hidden = false;
    $("install-update").hidden = !update.available;
  } catch {
  } finally {
    updateBusy = false;
    $("check-update").disabled = false;
    $("check-update").textContent = "Check for Updates…";
  }
};
$("install-update").onclick = () => call("install_update").catch(() => {});
$("record-menu").onclick = async (event) => {
  const action = event.target.dataset.action,
    record = menuRecord;
  if (!record || !action) return;
  closeMenu();
  try {
    if (action === "copy") await copy(record);
    else if (action === "delete") {
      await call("delete_dictation", { id: record.id });
      await refresh();
    } else if (action === "paste") {
      await call("tray_hide");
      const message = await call("retry_dictation", { id: record.id });
      if (message?.startsWith("Copied instead")) {
        error(message);
        await call("show_workspace", { page: "history" });
      }
    }
  } catch {}
};
document.addEventListener("pointerdown", (e) => {
  if (!e.target.closest("#record-menu")) closeMenu();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    e.preventDefault();
    if (!$("record-menu").hidden) closeMenu();
    else call("tray_hide").catch(() => {});
  }
  if ((e.metaKey || e.ctrlKey) && [",", "q"].includes(e.key.toLowerCase())) {
    e.preventDefault();
    if (e.key === ",") $("settings").click();
    else $("quit").click();
  }
});
let lastHeight = 0;
function resizePanel() {
  const height = Math.max(
    160,
    Math.ceil($("tray-panel").getBoundingClientRect().height),
  );
  if (height !== lastHeight) {
    lastHeight = height;
    invoke("tray_resize", { height: Math.min(1200, height) }).catch(() => {});
  }
}
new ResizeObserver(resizePanel).observe($("tray-panel"));
window.__TAURI__.event
  .listen("pressay-tray-open", () => {
    copied.clear();
    recentKey = "";
    closeMenu();
    $("tray-error").hidden = true;
    lastHeight = 0;
    resizePanel();
    refresh();
  })
  .catch(() => {});
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) refresh();
});
setInterval(() => {
  if (!document.hidden) refresh();
}, 750);
refresh();
