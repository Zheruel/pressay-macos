"use strict";
let selectedNote = null,
  noteTab = "summary",
  noteEditing = false,
  noteVersion = "",
  historyKey = "",
  historyEditing = null,
  notesKey = "",
  workspaceReady = false,
  accountInfo = null;
const pendingNotes = new Set();
const writeUpErrors = new Map();
let accountChecked = false;
let shortcutDirty = false,
  shortcutSaved = null,
  shortcutCapturing = false,
  shortcutStarting = false,
  shortcutSaving = false,
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
  $("shortcut-kind").disabled =
    shortcutCapturing || shortcutStarting || shortcutSaving;
  $("shortcut-mac-key").disabled =
    shortcutCapturing || shortcutStarting || shortcutSaving;
  $("shortcut-value").disabled =
    shortcutCapturing || shortcutStarting || shortcutSaving;
  $("record-shortcut").textContent = shortcutCapturing
    ? "Press a key…"
    : mac
      ? $("shortcut-mac-key").selectedOptions[0]?.textContent ||
        current.shortcut
      : $("shortcut-value").value.replaceAll("+", " + ") || "Record shortcut…";
  $("record-shortcut").disabled = shortcutStarting || shortcutSaving;
  $("save-shortcut").disabled =
    !shortcutDirty || shortcutCapturing || shortcutStarting || shortcutSaving;
  $("reset-shortcut").hidden =
    !shortcutDirty || shortcutCapturing || shortcutStarting || shortcutSaving;
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
  await saveShortcut();
}
async function saveShortcut() {
  if (shortcutSaving) return;
  const binding = shortcutBinding();
  shortcutSaving = true;
  renderShortcutControls();
  try {
    await call("change_shortcut", { binding });
    shortcutSaved = JSON.stringify(binding);
    $("shortcut-status").textContent = "Shortcut saved.";
    syncShortcut(current.view.settings);
    await refresh();
  } catch (error) {
    shortcutDirty = true;
    $("shortcut-options").open = true;
    $("shortcut-status").textContent =
      `Shortcut was not saved: ${String(error)}. Your changes are kept; edit or retry.`;
  } finally {
    shortcutSaving = false;
    renderShortcutControls();
  }
}
async function startShortcutCapture() {
  if (shortcutSaving) return;
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
      const system = element("option", "System Default");
      system.value = "";
      select.append(system);
      const options =
        info.deviceOptions || info.devices.map((name) => ({ id: name, name }));
      const repeated = new Map();
      for (const { id, name } of options) {
        const number = (repeated.get(name) || 0) + 1;
        repeated.set(name, number);
        const duplicate =
          options.filter((option) => option.name === name).length > 1;
        const option = element(
          "option",
          duplicate ? `${name} (${number})` : name,
        );
        option.value = id;
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
        if (
          info.selected &&
          !options.some((option) => option.id === info.selected)
        ) {
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
const settingsTabs = ["dictation", "ai", "notetaker", "general"];
function showGeneralTab(tab) {
  if (!settingsTabs.includes(tab)) return;
  if (generalTab !== tab) stopShortcutCapture();
  generalTab = tab;
  for (const button of document.querySelectorAll("[data-settings-tab]")) {
    const selected = button.dataset.settingsTab === tab;
    button.setAttribute("aria-selected", String(selected));
    button.tabIndex = selected ? 0 : -1;
  }
  for (const pane of document.querySelectorAll("[data-settings-pane]"))
    pane.hidden = pane.dataset.settingsPane !== tab;
  if (tab === "ai" || tab === "notetaker") refreshAccount();
}
function openSettings(tab = generalTab) {
  showGeneralTab(tab);
  const dialog = $("settings-dialog");
  if (!dialog.open) dialog.showModal();
  dialog.querySelector(".settings-body").scrollTop = 0;
}
function renderGeneralPermissions() {
  const permissions = current.permissions,
    mac = current.platform === "macos";
  const key = JSON.stringify([permissions, mac]);
  if (key === generalPermissionKey) return;
  generalPermissionKey = key;
  const group = $("general-permissions");
  group.replaceChildren();
  // On Mac the talk-key tap needs only Accessibility (as in Hex), so there
  // is no Input Monitoring row; the shortcut is its result, not a grant.
  const kinds = [
    ["microphone", "microphone", "Microphone"],
    ["accessibility", "insertion", mac ? "Accessibility" : "Text insertion"],
    ...(mac ? [] : [["shortcut", "shortcut", "Global shortcut"]]),
  ];
  if (
    mac &&
    permissions.insertion === "granted" &&
    permissions.shortcut !== "granted"
  ) {
    const row = element("div", undefined, "setting-row");
    row.append(
      element("span", "Talk key needs a restart"),
      button("Restart Pressay", () => call("restart_app")),
    );
    group.append(row);
  }
  if (kinds.every(([, field]) => permissions[field] === "granted")) {
    const row = element("div", undefined, "setting-row");
    row.append(
      element(
        "span",
        mac
          ? "Microphone & Accessibility"
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
  $("dictation-language").hidden = !model?.supportsLanguageHint;
  $("dictation-language-automatic").hidden = !!model?.supportsLanguageHint;
  $("dictation-language-caption").textContent =
    model?.languageCaption?.replace(" European languages", " languages") ||
    "Automatic detection";
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
  $("prepare").hidden = ready || busy;
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
  $("week").hidden = !history.length;
  $("weekly-words").textContent = words.toLocaleString();
  const unit = (value, label) => {
    const small = element("small", label);
    return [String(value), small];
  };
  $("saved-time").replaceChildren(
    ...unit(Math.max(0, Math.round(words / 40 - speaking / 60)), "min"),
  );
  renderWeekChart(history);
  let cursor = new Date(today.getFullYear(), today.getMonth(), today.getDate()),
    streak = 0;
  if (!days.has(localDay(cursor))) cursor.setDate(cursor.getDate() - 1);
  while (days.has(localDay(cursor))) {
    streak++;
    cursor.setDate(cursor.getDate() - 1);
  }
  $("streak").replaceChildren(
    ...unit(streak, streak === 1 ? "day" : "days"),
  );
}
let weekChartKey = "";
function renderWeekChart(history) {
  const today = new Date(),
    start = new Date(today.getFullYear(), today.getMonth(), today.getDate());
  // Monday-first week, so the chart reads like a calendar row.
  start.setDate(start.getDate() - ((start.getDay() + 6) % 7));
  const counts = Array(7).fill(0);
  for (const r of history) {
    const day = Math.floor(
      (localDay(new Date(r.created_at * 1000)) - start.getTime()) / 864e5,
    );
    if (day >= 0 && day < 7)
      counts[day] += (r.correction || r.text)
        .trim()
        .split(/\s+/u)
        .filter(Boolean).length;
  }
  const todayIndex = (today.getDay() + 6) % 7,
    key = JSON.stringify([counts, todayIndex]);
  if (key === weekChartKey) return;
  weekChartKey = key;
  const peak = Math.max(1, ...counts),
    formatter = new Intl.DateTimeFormat(formattingLocale(), {
      weekday: "narrow",
    });
  $("week-chart").replaceChildren(
    ...counts.map((count, index) => {
      const day = new Date(start);
      day.setDate(start.getDate() + index);
      const column = element(
        "div",
        undefined,
        index === todayIndex ? "today" : index > todayIndex ? "future" : "",
      );
      const bar = element("i");
      bar.style.height = `${Math.max(3, Math.round((count / peak) * 48))}px`;
      column.title = `${count.toLocaleString()} words`;
      column.append(bar, element("span", formatter.format(day)));
      return column;
    }),
  );
}
function historyAppName(record) {
  const metadata =
    typeof appMetadata === "undefined" ? null : appMetadata[record.target];
  if (metadata?.name) return metadata.name;
  const name =
    record.legacy?.targetAppName || record.legacy?.targetName || record.target;
  if (!name) return "";
  return name.split(".").at(-1).replace(/[-_]/g, " ");
}
function historyDay(timestamp) {
  const date = new Date(timestamp * 1000),
    today = new Date();
  const yesterday = new Date(
    today.getFullYear(),
    today.getMonth(),
    today.getDate() - 1,
  );
  if (localDay(date) === localDay(today)) return "Today";
  if (localDay(date) === localDay(yesterday)) return "Yesterday";
  if (
    date < today &&
    date >= new Date(today.getFullYear(), today.getMonth(), today.getDate() - 6)
  )
    return date.toLocaleDateString(formattingLocale(), { weekday: "long" });
  return date.toLocaleDateString(formattingLocale(), {
    month: "long",
    day: "numeric",
  });
}
function historyIcon(kind) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24");
  svg.setAttribute("fill", "none");
  svg.setAttribute("stroke", "currentColor");
  svg.setAttribute("stroke-width", "1.5");
  svg.setAttribute("aria-hidden", "true");
  const path = document.createElementNS(svg.namespaceURI, "path");
  path.setAttribute(
    "d",
    kind === "copy"
      ? "M9 8h10v13H9z M15 8V3H5v13h4"
      : kind === "app"
        ? "M7 3h10a4 4 0 0 1 4 4v10a4 4 0 0 1-4 4H7a4 4 0 0 1-4-4V7a4 4 0 0 1 4-4Z"
        : "M12 7v6l4 2 M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0",
  );
  svg.append(path);
  return svg;
}
// Search folds case and accents, and every word must match somewhere in the
// text or the app name. The folded text is cached per record, so typing only
// scans strings, and the list renders in pages so long histories stay fast.
const historyIndex = new Map();
const HISTORY_PAGE = 100;
let historyLimit = HISTORY_PAGE,
  historyQuery = "",
  // What the list shows. It only follows the field after the debounce, so
  // the background status refresh can't apply a half-typed query early.
  appliedHistoryQuery = "";
function foldText(text) {
  return text
    .normalize("NFD")
    .replace(/\p{M}/gu, "")
    .toLocaleLowerCase();
}
function searchTokens(query) {
  return foldText(query).split(/\s+/u).filter(Boolean);
}
function historyHaystack(record) {
  const app = historyAppName(record),
    source = `${record.correction || ""}\u0000${record.text}\u0000${app}`;
  let entry = historyIndex.get(record.id);
  if (!entry || entry.source !== source) {
    entry = {
      source,
      folded: foldText(
        `${record.correction || record.text} ${record.raw} ${app}`,
      ),
    };
    historyIndex.set(record.id, entry);
  }
  return entry.folded;
}
function historySignature(history) {
  let signature = String(history.length);
  for (const r of history)
    signature += `|${r.id}:${(r.correction || "").length}:${r.legacy?.warning ? 1 : 0}`;
  return signature;
}
function highlightInto(container, text, tokens) {
  if (!tokens.length) {
    container.textContent = text;
    return;
  }
  const escaped = tokens
    .map((token) => token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    .sort((a, b) => b.length - a.length);
  const pattern = new RegExp(`(${escaped.join("|")})`, "giu");
  const parts = text.split(pattern);
  container.replaceChildren(
    ...parts.map((part, index) =>
      index % 2 ? element("mark", part) : document.createTextNode(part),
    ),
  );
}
function setHistoryQuery(value) {
  $("history-search").value = value;
  appliedHistoryQuery = value.trim();
  historyLimit = HISTORY_PAGE;
  renderHistory(current.view);
}
function renderHistory(s) {
  if (
    historyEditing &&
    s.history.some((record) => record.id === historyEditing)
  )
    return;
  historyEditing = null;
  const query = appliedHistoryQuery;
  if (query !== historyQuery) {
    historyQuery = query;
    historyLimit = HISTORY_PAGE;
  }
  const key = [
    historySignature(s.history),
    query,
    historyLimit,
    localDay(new Date()),
    typeof appMetadata === "undefined" ? 0 : Object.keys(appMetadata).length,
  ].join("\u0001");
  if (key === historyKey) return;
  historyKey = key;
  const searching = !!query,
    tokens = searchTokens(query);
  $("clear-history").disabled = !s.history.length;
  $("clear-history-search").hidden = !searching;
  document
    .querySelector('[data-panel="dictation"]')
    .classList.toggle("searching", searching);
  // The newest dictation is the Home hero; the list starts after it unless
  // the person is searching.
  document.querySelector(".history-filters").hidden =
    !searching && s.history.length < 2;
  $("history-retention").hidden = searching || s.history.length < 2;
  const matches = searching
    ? s.history.filter((r) => {
        const haystack = historyHaystack(r);
        return tokens.every((token) => haystack.includes(token));
      })
    : s.history.slice(1);
  const records = matches.slice(0, historyLimit);
  $("history-heading").textContent = searching
    ? matches.length
      ? `${matches.length.toLocaleString()} ${matches.length === 1 ? "result" : "results"}`
      : "No results"
    : records.length
      ? historyDay(records[0].created_at)
      : "Earlier";
  $("history").replaceChildren();
  if (!matches.length && (searching || !s.history.length)) {
    const empty = element("div", undefined, "native-history-empty");
    empty.append(
      element(
        "h2",
        searching ? `Nothing matches “${query}”` : "No dictations yet",
      ),
      element(
        "p",
        searching
          ? "Try fewer words, or search for an app name."
          : `Hold ${current.shortcut || "your talk key"} in any app to get started.`,
      ),
    );
    $("history").append(empty);
  }
  let groupTitle = null,
    group;
  for (const r of records) {
    const title = historyDay(r.created_at);
    if (title !== groupTitle) {
      const section = element("section", undefined, "history-day");
      group = element("div", undefined, "history-day-rows");
      // The first day's title sits in the header row beside search.
      if (groupTitle !== null || searching)
        section.append(element("h3", title));
      section.append(group);
      $("history").append(section);
      groupTitle = title;
    }
    const article = element("article", undefined, "native-history-row");
    const time = element(
      "time",
      new Date(r.created_at * 1000).toLocaleTimeString(formattingLocale(), {
        hour: "numeric",
        minute: "2-digit",
      }),
      "history-time",
    );
    const appName = historyAppName(r);
    const icon = element("div", undefined, "history-app-icon");
    icon.setAttribute("aria-hidden", "true");
    if (appName)
      icon.append(element("span", appName.trim()[0].toLocaleUpperCase(), "app-initial"));
    else icon.append(historyIcon("app"));
    const appIcon =
      typeof appMetadata === "undefined" ? null : appMetadata[r.target]?.icon;
    if (appIcon?.startsWith("data:image/")) {
      const image = element("img");
      image.src = appIcon;
      image.alt = "";
      icon.replaceChildren(image);
    }
    const content = element("div", undefined, "history-row-content");
    const text = element("p", undefined, "history-row-text");
    highlightInto(text, r.correction || r.text, tokens);
    content.append(text);
    if (searching) {
      const meta = element("p", undefined, "history-row-meta");
      highlightInto(meta, appName, tokens);
      content.append(meta);
    }
    const warning = dictationWarning(r);
    if (warning) content.append(warningNote(warning));
    const copy = button(
      "",
      async () => {
        await call("copy_text", { text: r.correction || r.text });
        copy.textContent = "✓";
        setTimeout(() => copy.replaceChildren(historyIcon("copy")), 1200);
      },
      "history-copy quiet",
    );
    copy.setAttribute("aria-label", "Copy dictation");
    copy.title = "Copy dictation";
    copy.append(historyIcon("copy"));
    const menu = element("details", undefined, "history-row-menu");
    const summary = element("summary", "•••");
    summary.setAttribute("aria-label", "More dictation actions");
    const actions = element("div", undefined, "history-row-actions");
    menu.append(summary, actions);
    const act = (name, handler) =>
      button(name, async () => {
        menu.open = false;
        await handler();
      });
    actions.append(
      act("Copy", () => call("copy_text", { text: r.correction || r.text })),
      act("Correct", () => {
        if (historyEditing) return;
        historyEditing = r.id;
        const edit = element("textarea");
        edit.value = r.correction || r.text;
        edit.rows = 4;
        edit.setAttribute("aria-label", "Correct dictation");
        text.replaceWith(edit);
        const editActions = element("div", undefined, "button-group");
        editActions.append(
          button(
            "Save correction",
            async () => {
              await call("edit_dictation", {
                id: r.id,
                correction: edit.value,
                pinned: null,
              });
              historyEditing = null;
              historyKey = "";
              await refresh();
            },
            "primary",
          ),
          button("Cancel", () => {
            historyEditing = null;
            historyKey = "";
            renderHistory(current.view);
          }),
        );
        content.append(editActions);
        edit.focus();
      }),
    );
    if (r.legacy?.managedAudio)
      actions.append(
        act("Listen", async () => {
          const previous = content.querySelector("audio");
          if (previous) {
            URL.revokeObjectURL(previous.src);
            previous.remove();
          }
          const base64 = await call("recording", { id: r.id });
          const data = Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
          const url = URL.createObjectURL(
            new Blob([data], { type: "audio/wav" }),
          );
          const audio = document.createElement("audio");
          audio.controls = true;
          audio.src = url;
          const revoke = () => URL.revokeObjectURL(url);
          audio.onended = revoke;
          audio.onerror = revoke;
          content.append(audio);
          try {
            await audio.play();
          } catch (e) {
            revoke();
            throw e;
          }
        }),
      );
    if (r.correction || r.raw !== r.text)
      actions.append(
        act("Original transcription", () => {
          if (!content.querySelector(".history-original")) {
            const original = element("div", undefined, "history-original");
            original.append(
              element("small", "Original transcription"),
              element("p", r.raw),
            );
            content.append(original);
          }
        }),
      );
    actions.append(act("Delete", () => call("delete_dictation", { id: r.id })));
    menu.onkeydown = (event) => {
      if (event.key === "Escape") {
        menu.open = false;
        summary.focus();
      }
    };
    article.oncontextmenu = (event) => {
      event.preventDefault();
      menu.open = true;
      summary.focus();
    };
    if (!searching) icon.title = appName;
    article.append(time, icon, content, copy, menu);
    group.append(article);
  }
  if (matches.length > records.length) {
    const more = button(
      `Show ${Math.min(HISTORY_PAGE, matches.length - records.length)} more`,
      () => {
        historyLimit += HISTORY_PAGE;
        renderHistory(current.view);
      },
      "history-more",
    );
    $("history").append(more);
  }
}
function dictationWarning(record) {
  const warning = record.legacy?.warning;
  return typeof warning === "string" ? warning.replace(/\.$/u, "") : "";
}
function warningNote(text) {
  const note = element("p", undefined, "history-row-note");
  note.innerHTML =
    '<svg viewBox="0 0 20 20" width="12" height="12" aria-hidden="true"><path d="M10 3 18 16.5H2L10 3Z" fill="currentColor"/><path d="M10 8v4" stroke="var(--base)" stroke-width="1.8" stroke-linecap="round"/><circle cx="10" cy="14.3" r="1" fill="var(--base)"/></svg>';
  note.append(element("span", text + "."));
  return note;
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
let notesActionMode = false;
function noteDuration(seconds) {
  if (seconds < 60) return "under 1 min";
  const minutes = Math.floor(seconds / 60);
  return minutes < 60
    ? `${minutes} min`
    : `${Math.floor(minutes / 60)} hr ${minutes % 60} min`;
}
function formattingLocale() {
  try {
    const locale = current?.locale || undefined;
    // WebKit drops this regional override to US English. European English
    // retains the selected Croatian region's day-first, 24-hour convention.
    return locale === "en-HR" &&
      new Intl.DateTimeFormat(locale).resolvedOptions().locale === "en"
      ? "en-150"
      : locale;
  } catch {
    return undefined;
  }
}
function noteDate(note) {
  return new Date((note.created_at || 0) * 1000).toLocaleString(
    formattingLocale(),
    { dateStyle: "medium", timeStyle: "short" },
  );
}
function notePeople(note) {
  const people = (note.lines || []).some((l) => l.speaker === "me")
    ? ["You"]
    : [];
  const voices = [
    ...new Set((note.lines || []).map((l) => l.voice).filter(Boolean)),
  ].sort();
  if (voices.length)
    people.push(
      ...voices.map((v) => note.speakerNames?.[v - 1] || `Speaker ${v}`),
    );
  else if (note.participants?.length) people.push(...note.participants);
  else if ((note.lines || []).some((l) => l.speaker === "others"))
    people.push("Others");
  return [...new Set(people)].join(", ");
}
function noteGlyph() {
  const span = element("span", undefined, "note-row-icon");
  span.setAttribute("aria-hidden", "true");
  span.innerHTML =
    '<svg viewBox="0 0 28 24" fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round"><circle cx="7" cy="8" r="3"/><circle cx="17" cy="8" r="3"/><path d="M2 20v-2a5 5 0 0 1 9-3M11 20v-2a6 6 0 0 1 12 0v2H2M23 3a9 9 0 0 1 0 10m3-13a14 14 0 0 1 0 16"/></svg>';
  return span;
}
function selectNote(id) {
  // Edits save as you type, so switching meetings just sends what's pending.
  flushNoteSave();
  selectedNote = id;
  notesActionMode = false;
  noteEditing = false;
  noteVersion = "";
  notesKey = "";
  noteTab = "summary";
  document.querySelector("main").scrollTop = 0;
  renderNotes(current.view);
}
function renderNotes(s) {
  const recording = s.stage.startsWith("meeting");
  if (s.active_note && recording) selectedNote = s.active_note;
  let n = s.notes.find((n) => n.id === selectedNote);
  if (!n && selectedNote) selectedNote = null;
  // Split view: with nothing chosen, open the newest meeting on the right.
  if (!n && !recording && !notesActionMode && !$("notes-search").value) {
    n = s.notes.reduce(
      (newest, note) =>
        !newest || note.created_at > newest.created_at ? note : newest,
      null,
    );
    if (n) {
      selectedNote = n.id;
      noteVersion = "";
      notesKey = "";
    }
  }
  const panel = document.querySelector('[data-panel="meetings"]');
  panel.dataset.noteView = recording
    ? "live"
    : n || notesActionMode
      ? "detail"
      : "home";
  $("note-detail").hidden = recording || (!n && !notesActionMode);
  $("notes-placeholder").hidden = recording || !!n || notesActionMode;
  $("notes-placeholder-title").textContent = s.notes.length
    ? "Pick a meeting"
    : "No meetings yet";
  $("notes-placeholder-text").textContent = s.notes.length
    ? "Its summary and transcript open here."
    : "Start Notetaker for a call or an in-person meeting. Your notes appear here.";
  window.pressayAsk.sync({
    meeting: recording ? null : n,
    recording,
    hasNotes: s.notes.some(
      (note) => note.lines?.length || note.plainTranscript || note.body,
    ),
    // Until the first account check finishes, assume Ask works rather than
    // flashing a setup prompt.
    canAsk:
      s.settings.notesUseAI !== false &&
      (!accountChecked || notesProviderAvailable()),
  });
  if (!accountChecked && !document.querySelector('[data-panel="meetings"]').hidden)
    refreshAccount();
  if (recording) {
    $("meeting-title").textContent = n?.title || "Preparing meeting";
    const finishing = ["meeting_finishing", "meeting_speakers"].includes(
      s.stage,
    );
    $("meeting-live").classList.toggle(
      "finishing",
      finishing || s.stage === "meeting_starting",
    );
    $("meeting-listening-title").textContent = finishing
      ? "Saving your notes…"
      : s.stage === "meeting_starting"
        ? "Preparing meeting"
        : "Taking notes";
    $("meeting-listening-detail").textContent = finishing
      ? "Your summary will be ready in a moment."
      : s.stage === "meeting_starting"
        ? "Getting everything ready for your meeting."
        : "Stop the meeting when you’re done to get your summary.";
    $("live-meeting-menu").hidden = finishing || !s.active_note;
    $("live-meeting-notice").hidden = !n?.notice || n.interrupted;
    $("live-meeting-notice").textContent = n?.notice || "";
  }
  const query = $("notes-search").value.toLocaleLowerCase();
  const key = JSON.stringify([
    s.notes,
    selectedNote,
    query,
    current.jobs,
    [...pendingNotes],
  ]);
  if (key !== notesKey) {
    notesKey = key;
    $("meetings").replaceChildren();
    const notes = s.notes
      .filter((note) =>
        `${note.title} ${note.body} ${note.myNotes || ""} ${note.plainTranscript || ""}`
          .toLocaleLowerCase()
          .includes(query),
      )
      .sort((a, b) => b.created_at - a.created_at);
    $("recent-meetings-heading").hidden = !notes.length;
    $("meetings").classList.toggle("is-empty", !notes.length);
    if (!notes.length) {
      const empty = element("div", undefined, "notes-empty");
      empty.append(
        noteGlyph(),
        element("h2", query ? "No matching meetings" : "No meetings yet"),
        element(
          "p",
          query
            ? "Try another search."
            : "Your meetings will appear here.",
        ),
      );
      $("meetings").append(empty);
    }
    let groupTitle = null;
    for (const note of notes) {
      const title = historyDay(note.created_at);
      if (title !== groupTitle) {
        $("meetings").append(element("h3", title, "notes-day"));
        groupTitle = title;
      }
      const row = button(
        "",
        () => selectNote(note.id),
        "note-card" + (note.id === selectedNote ? " active" : ""),
      );
      if (note.id === selectedNote) row.setAttribute("aria-current", "true");
      const copy = element("span", undefined, "note-row-copy");
      copy.append(
        element("strong", note.title || "Untitled"),
        element(
          "small",
          [
            new Date((note.created_at || 0) * 1000).toLocaleTimeString(
              formattingLocale(),
              { hour: "numeric", minute: "2-digit" },
            ),
            noteDuration(note.duration),
          ]
            .filter(Boolean)
            .join(", "),
        ),
      );
      const writing =
        pendingNotes.has(note.id) || current.jobs?.includes(note.id);
      row.append(
        noteGlyph(),
        copy,
        element(
          "span",
          writing ? "Writing up…" : note.body ? "" : "Transcript only",
          "note-write-status" + (note.body ? " written" : ""),
        ),
      );
      $("meetings").append(row);
    }
    const open = s.notes.flatMap((note) =>
      (note.actions || []).filter(
        (a) => !a.done && a.owner?.toLowerCase() === "me",
      ),
    );
    $("notes-open-actions").hidden = !open.length;
    const actionIcon = element("span", undefined, "notes-actions-icon");
    actionIcon.setAttribute("aria-hidden", "true");
    actionIcon.innerHTML =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="5" cy="6" r="3"/><path d="m3.5 6 1 1 2-2M12 6h10M12 17h10"/><circle cx="5" cy="17" r="3"/></svg>';
    const chevron = element("span", "›", "notes-actions-chevron");
    chevron.setAttribute("aria-hidden", "true");
    $("notes-open-actions").replaceChildren(
      actionIcon,
      element(
        "span",
        `${open.length} open action ${open.length === 1 ? "item" : "items"} for you`,
      ),
      chevron,
    );
  }
  if (recording) return;
  if (notesActionMode) {
    renderNotesActions(s);
    return;
  }
  if (!n) return;
  if (!accountChecked) refreshAccount();
  const version = JSON.stringify([
    n,
    noteTab,
    pendingNotes.has(n.id) || current.jobs?.includes(n.id),
    writeUpErrors.get(n.id),
    s.settings.notesUseAI,
    accountInfo && notesProviderAvailable(),
  ]);
  if (version === noteVersion || noteEditing) return;
  noteVersion = version;
  const detail = $("note-detail");
  detail.replaceChildren();
  const writing = pendingNotes.has(n.id) || current.jobs?.includes(n.id);
  const head = element("header", undefined, "note-head");
  const actions = element("div", undefined, "note-head-actions");
  const status = element("span", "", "note-save-status");
  status.id = "note-save-status";
  status.setAttribute("role", "status");
  actions.append(status);
  const myOpen = n.actions?.some(
    (a) => a.owner?.toLowerCase() === "me" && !a.done,
  );
  if (myOpen && current.platform === "macos")
    actions.append(
      button(
        "Add to Reminders",
        () => call("export_reminders", { id: n.id }),
        "note-head-button",
      ),
    );
  const copy = button(
    "",
    async () => {
      await call("copy_text", {
        text:
          noteTab === "transcript"
            ? n.plainTranscript || ""
            : noteTab === "personal"
              ? n.myNotes || ""
              : `# ${n.title}\n\n${n.body || ""}`,
      });
      copy.lastChild.textContent = "Copied";
      setTimeout(() => (copy.lastChild.textContent = "Copy"), 1400);
    },
    "note-head-button",
  );
  copy.append(historyIcon("copy"), element("span", "Copy"));
  copy.title =
    noteTab === "transcript" ? "Copy the transcript" : "Copy as Markdown";
  const exportButton = button(
    "Export",
    () => call("export_data", { kind: "note", id: n.id }),
    "note-head-button",
  );
  exportButton.title = "Save as a Markdown file";
  const remove = button(
    "",
    async () => {
      if (
        confirm(
          `Delete “${n.title}”? Its notes and transcript are deleted. You can’t undo this.`,
        )
      )
        await call("delete_note", { id: n.id });
    },
    "note-head-button icon-only",
  );
  remove.innerHTML =
    '<svg viewBox="0 0 20 20" width="15" height="15" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 6h12M8 6V4.5h4V6M6 6l.7 10h6.6L14 6"/></svg>';
  remove.setAttribute("aria-label", "Delete meeting");
  remove.title = "Delete meeting";
  actions.append(copy, exportButton, remove);
  const title = element("h1", n.title || "Untitled", "note-title");
  title.contentEditable = "plaintext-only";
  title.spellcheck = false;
  title.setAttribute("aria-label", "Meeting title");
  title.onfocus = () => (noteEditing = true);
  title.onblur = () => {
    if (!title.textContent.trim()) title.textContent = n.title || "Untitled";
    finishNoteEditing();
  };
  title.onkeydown = (event) => {
    if (event.key === "Enter" || event.key === "Escape") {
      event.preventDefault();
      if (event.key === "Escape") title.textContent = n.title || "Untitled";
      title.blur();
    }
  };
  title.oninput = () => {
    const value = title.textContent.trim();
    if (value) queueNoteSave(n.id, { title: value.slice(0, 200) });
  };
  const meta = element("div", undefined, "note-meta");
  meta.append(
    element(
      "span",
      [
        noteDate(n),
        n.duration >= 60 ? noteDuration(n.duration) : "",
        n.kind === "meeting" ? notePeople(n) : "",
      ]
        .filter(Boolean)
        .join(" · "),
    ),
  );
  if (n.kind === "meeting")
    meta.append(
      button(
        n.participants?.length || n.speakerNames?.some(Boolean)
          ? "Edit names"
          : "Add names",
        () => editNoteNames(n),
        "note-link",
      ),
    );
  const tabs = element("div", undefined, "note-tabs");
  tabs.setAttribute("role", "tablist");
  for (const [id, label] of [
    ["summary", "Summary"],
    ["personal", "My notes"],
    ["transcript", "Transcript"],
  ]) {
    const tab = button(
      label,
      async () => {
        await flushNoteSave();
        noteEditing = false;
        noteTab = id;
        noteVersion = "";
        renderNotes(current.view);
      },
      noteTab === id ? "active" : "",
    );
    tab.setAttribute("role", "tab");
    tab.setAttribute("aria-selected", String(noteTab === id));
    tabs.append(tab);
  }
  head.append(actions, title, meta, tabs);
  detail.append(head);
  const body = element("div", undefined, "note-body note-tab-" + noteTab);
  detail.append(body);
  if (noteTab === "summary") {
    if (n.notice) body.append(element("p", n.notice, "notice"));
    const failure = !writing && writeUpErrors.get(n.id);
    if (failure) {
      const banner = element("div", undefined, "notice row");
      banner.append(
        element("span", failure),
        button("Try again", () => writeUp(n, true)),
      );
      body.append(banner);
    }
    if (n.body || writing) {
      const editor = createNoteEditor({
        value: n.body || "",
        label: "Meeting notes",
        placeholder: "Write your notes…",
        readOnly: writing,
        onChange: (markdown) => queueNoteSave(n.id, { body: markdown }),
        onFocusChange: (focused) =>
          focused ? (noteEditing = true) : finishNoteEditing(),
      });
      body.append(editor.element);
      if (writing) {
        const row = element("div", undefined, "note-writing");
        row.append(
          element("span", "Writing up your notes…"),
          button("Cancel", () => call("cancel_note_job", { id: n.id })),
        );
        body.prepend(row);
      } else if (
        n.kind === "meeting" &&
        s.settings.notesUseAI !== false &&
        notesProviderAvailable()
      ) {
        const again = button("", () => writeUp(n), "note-rewrite");
        again.innerHTML =
          '<svg viewBox="0 0 20 20" width="13" height="13" aria-hidden="true"><path d="m10 3 1.7 4.6L16.5 9l-4.8 1.6L10 15.5l-1.7-4.9L3.5 9l4.8-1.4L10 3Z" fill="currentColor"/></svg>';
        again.append(element("span", "Write up again"));
        again.title = n.edited
          ? "Replaces your edits with a fresh write-up"
          : "Write a fresh summary from the transcript";
        body.append(again);
      }
    } else {
      const building = s.active_note === n.id;
      const aiOff = s.settings.notesUseAI === false;
      const noProvider = accountInfo && !notesProviderAvailable();
      const empty = element("div", undefined, "note-empty");
      empty.append(
        element(
          "p",
          building
            ? "Your transcript is building. Notes will be ready after the recording ends."
            : noProvider
              ? "Connect AI Cleanup to get a summary, decisions and action items. The full transcript is in the Transcript tab."
              : aiOff
                ? "AI notes are off. The full transcript is in the Transcript tab."
                : "This meeting hasn’t been written up yet.",
        ),
      );
      if (!building)
        empty.append(
          noProvider
            ? button("Set up AI Cleanup", () => openSettings("ai"), "primary")
            : aiOff
              ? button(
                  "Turn on AI notes",
                  async () => {
                    await setting({ notesUseAI: true });
                    writeUp(n);
                  },
                  "primary",
                )
              : button("Write up notes", () => writeUp(n), "primary"),
        );
      body.append(empty);
    }
  } else if (noteTab === "transcript") {
    const transcriptTools = element(
      "div",
      undefined,
      "native-transcript-tools",
    );
    transcriptTools.append(
      element(
        "span",
        [notePeople(n), clockText(n.duration)].filter(Boolean).join(" · "),
      ),
    );
    const search = element("input");
    search.type = "search";
    search.placeholder = "Search transcript";
    search.setAttribute("aria-label", "Search transcript");
    transcriptTools.append(
      search,
      button("Copy", () =>
        call("copy_text", { text: n.plainTranscript || "" }),
      ),
    );
    body.append(transcriptTools);
    const turns = [];
    for (const line of n.lines || []) {
      const previous = turns.at(-1);
      if (
        previous &&
        previous.speaker === line.speaker &&
        previous.voice === line.voice &&
        line.start - previous.start < 45
      )
        previous.text += " " + line.text;
      else turns.push({ ...line });
    }
    const transcript = element("div", undefined, "native-transcript-lines");
    const draw = () => {
      transcript.replaceChildren();
      const query = search.value.toLocaleLowerCase();
      for (const line of turns.filter((line) =>
        line.text.toLocaleLowerCase().includes(query),
      )) {
        const mine = line.speaker === "me";
        const row = element(
          "div",
          undefined,
          "transcript-line" +
            (mine ? " mine" : "") +
            (n.kind === "voice" ? " voice-transcript" : ""),
        );
        const label = mine
          ? "You"
          : line.voice
            ? n.speakerNames?.[line.voice - 1] || `Speaker ${line.voice}`
            : "Others";
        const metadata = element("div", undefined, "transcript-turn-label");
        if (n.kind !== "voice") metadata.append(element("strong", label));
        metadata.append(element("small", clockText(line.start)));
        const text = element("p");
        let offset = 0,
          index;
        while (
          query &&
          (index = line.text.toLocaleLowerCase().indexOf(query, offset)) >= 0
        ) {
          text.append(
            document.createTextNode(line.text.slice(offset, index)),
            element("mark", line.text.slice(index, index + query.length)),
          );
          offset = index + query.length;
        }
        text.append(document.createTextNode(line.text.slice(offset)));
        row.append(metadata, text);
        transcript.append(row);
      }
      if (!transcript.children.length)
        transcript.append(
          element(
            "p",
            query
              ? `No matches for “${search.value}”.`
              : n.plainTranscript || "Nothing was transcribed in this meeting.",
            "transcript-empty",
          ),
        );
    };
    search.oninput = draw;
    draw();
    body.append(transcript);
  } else if (noteTab === "personal") {
    let update = null;
    const editor = createNoteEditor({
      value: n.myNotes || "",
      label: "My notes",
      placeholder:
        "Jot down anything. Pressay works your notes into the summary.",
      onChange: (markdown) => {
        queueNoteSave(n.id, { myNotes: markdown });
        if (update) update.hidden = markdown === (n.myNotes || "");
      },
      onFocusChange: (focused) =>
        focused ? (noteEditing = true) : finishNoteEditing(),
    });
    body.append(editor.element);
    if (
      n.kind === "meeting" &&
      n.body &&
      s.settings.notesUseAI !== false &&
      notesProviderAvailable()
    ) {
      update = button(
        "",
        async () => {
          await flushNoteSave();
          noteEditing = false;
          noteTab = "summary";
          writeUp(n);
        },
        "note-rewrite",
      );
      update.innerHTML =
        '<svg viewBox="0 0 20 20" width="13" height="13" aria-hidden="true"><path d="m10 3 1.7 4.6L16.5 9l-4.8 1.6L10 15.5l-1.7-4.9L3.5 9l4.8-1.4L10 3Z" fill="currentColor"/></svg>';
      update.append(element("span", "Update the summary with my notes"));
      update.hidden = true;
      body.append(update);
    }
  }
}
// Notes save as you type: edits collect for a moment, then go out together.
let noteSave = null;
function setNoteStatus(text) {
  const status = $("note-save-status");
  if (status) status.textContent = text;
}
function queueNoteSave(id, patch) {
  if (noteSave && noteSave.id !== id) flushNoteSave();
  noteEditing = true;
  noteSave ||= { id, patch: {} };
  Object.assign(noteSave.patch, patch);
  clearTimeout(noteSave.timer);
  setNoteStatus("Editing");
  noteSave.timer = setTimeout(flushNoteSave, 700);
}
async function flushNoteSave() {
  const pending = noteSave;
  if (!pending) return;
  noteSave = null;
  clearTimeout(pending.timer);
  setNoteStatus("Saving…");
  try {
    await call("edit_note", { id: pending.id, patch: pending.patch });
    setNoteStatus("Saved");
    setTimeout(() => {
      if ($("note-save-status")?.textContent === "Saved") setNoteStatus("");
    }, 1600);
  } catch {
    setNoteStatus("Not saved");
  }
}
function finishNoteEditing() {
  flushNoteSave().finally(() => {
    const active = document.activeElement;
    if (!active?.closest?.(".note-editor-doc, .note-title")) noteEditing = false;
  });
}
function notesProviderAvailable() {
  return !!(accountInfo?.claudeApiKey || accountInfo?.chatgpt?.signed_in);
}
async function writeUp(n, confirmed = false) {
  if (pendingNotes.has(n.id)) return;
  if (
    n.edited &&
    !confirmed &&
    !window.confirm(
      "Replace your edited notes with a new AI write-up? The transcript and My notes will stay.",
    )
  )
    return;
  pendingNotes.add(n.id);
  writeUpErrors.delete(n.id);
  noteVersion = "";
  renderNotes(current.view);
  try {
    await invoke("write_note", { id: n.id, replaceEdits: n.edited === true });
  } catch (e) {
    writeUpErrors.set(n.id, String(e));
  } finally {
    pendingNotes.delete(n.id);
    noteVersion = "";
    renderNotes(current.view);
  }
}
function editNoteNames(note) {
  const dialog = element("dialog", undefined, "note-names-dialog");
  dialog.append(element("h2", "Who was on the call?"));
  const participants = element("input");
  participants.value = (note.participants || []).join(", ");
  participants.setAttribute("aria-label", "Participants, separated by commas");
  dialog.append(
    element("p", "Add names to make your notes easier to follow.", "muted"),
    element("label", "Participants"),
    participants,
  );
  const names = [];
  const voiceCount = Math.max(
    0,
    ...(note.lines || []).map((line) => line.voice || 0),
    (note.speakerNames || []).length,
  );
  for (let i = 0; i < voiceCount; i++) {
    const input = element("input");
    input.value = note.speakerNames?.[i] || "";
    input.placeholder = `Speaker ${i + 1}`;
    input.setAttribute("aria-label", `Name for speaker ${i + 1}`);
    names.push(input);
    dialog.append(input);
  }
  const actions = element("div", undefined, "row");
  actions.append(
    button("Cancel", () => dialog.close()),
    button(
      "Done",
      async () => {
        await call("edit_note", {
          id: note.id,
          patch: {
            participants: participants.value
              .split(",")
              .map((name) => name.trim())
              .filter(Boolean),
            speakerNames: names.length
              ? names.map((name) => name.value.trim())
              : note.speakerNames || [],
          },
        });
        dialog.close();
        noteVersion = "";
      },
      "primary",
    ),
  );
  dialog.append(actions);
  dialog.onclose = () => dialog.remove();
  document.body.append(dialog);
  dialog.showModal();
  participants.focus();
}
function renderNotesActions(s) {
  const version = JSON.stringify([
    "actions",
    s.notes.map((note) => [note.id, note.title, note.actions]),
  ]);
  if (version === noteVersion) return;
  noteVersion = version;
  const detail = $("note-detail");
  detail.replaceChildren();
  const toolbar = element("div", undefined, "native-note-toolbar");
  const back = button("←", () => selectNote(null), "note-back");
  back.setAttribute("aria-label", "Back to Notetaker");
  toolbar.append(back, element("strong", "Action Items"));
  detail.append(toolbar);
  const content = element("div", undefined, "note-body note-tab-summary");
  content.append(element("h1", "Your action items"));
  let count = 0;
  for (const note of s.notes) {
    const actions = (note.actions || []).filter(
      (item) => !item.done && item.owner?.toLowerCase() === "me",
    );
    if (!actions.length) continue;
    content.append(
      button(
        note.title,
        () => selectNote(note.id),
        "note-link action-note-title",
      ),
    );
    for (const item of actions) {
      count++;
      const row = element("label", undefined, "action-item");
      const check = element("input");
      check.type = "checkbox";
      check.onchange = () =>
        call("toggle_action", { id: note.id, item }).catch(
          () => (check.checked = false),
        );
      row.append(check, element("span", item.text));
      content.append(row);
    }
  }
  if (!count) content.append(element("p", "You’re all caught up.", "muted"));
  detail.append(content);
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
  $("stop-meeting").hidden = !recording || !s.active_note;
  $("stop-meeting").disabled =
    s.stage === "meeting_finishing" || s.stage === "meeting_speakers";
  $("meeting-live").hidden = !recording;
  $("meeting-clock").textContent = clockText(s.meeting_elapsed).padStart(
    5,
    "0",
  );
  $("meeting-live-label").textContent =
    s.stage === "meeting_speakers"
      ? "Separating speakers"
      : s.stage === "meeting_finishing"
        ? "Finishing…"
        : s.stage === "meeting_starting"
          ? "Preparing meeting"
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
    const ranked =
      id === "meeting-model"
        ? ["moss", "orukeet", "parakeetUltra", "qwen3ASR17", "megaASR"]
        : ["orukeet", "moss", "parakeetUltra", "qwen3ASR17", "megaASR"];
    const models = current.models.filter((m) => !!m.secondary === secondary);
    if (!secondary)
      models.sort((a, b) => ranked.indexOf(a.id) - ranked.indexOf(b.id));
    for (const model of models) {
      const rank = ranked.indexOf(model.id);
      const option = element(
        "option",
        secondary
          ? model.name
          : `${rank + 1}. ${model.name}${rank === 0 ? " · Recommended" : ""}`,
      );
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
  if (!modelSelectionPending || s.asrModel === modelSelectionPending) {
    modelSelectionPending = null;
    $("model").value = s.asrModel;
  }
  languageOptions("dictation-language", s.asrModel, s.language);
  languageOptions(
    "meeting-language",
    s.meetingASRModel || "moss",
    s.meetingLanguage,
  );
  $("ai-enabled").checked = s.claudeCleanup === true;
  if (
    !document.activeElement?.closest("#settings-ai") &&
    !accountSaving &&
    !accountVerifying &&
    !accountSigningIn
  ) {
    $("ai-provider").value = s.cleanupProvider || "claude";
    $("ai-connection").value =
      s[
        $("ai-provider").value === "claude"
          ? "claudeConnection"
          : "openAIConnection"
      ] || "apiKey";
  }
  $("notes-ai").checked = s.notesUseAI !== false;
  renderNotesSettings(s);
  $("meeting-hours").value = s.maxMeetingHours || 3;
  $("meeting-model").value = s.meetingASRModel || "moss";
  $("detect-calls").checked = s.detectCalls !== false;
  $("detect-calls-quick").checked = s.detectCalls !== false;
  $("wayland-cursor").checked = s.waylandCurrentCursor === true;
  $("wayland-option").hidden = !current.permissions.wayland;
  $("wayland-help").hidden = !current.permissions.wayland;
  syncShortcut(s);
  renderAccount();
}
let accountFeedback = null,
  accountVerifying = false,
  accountSigningIn = false,
  accountSaving = false,
  accountSelectionEpoch = 0;
function accountSelection() {
  return JSON.stringify([$("ai-provider").value, $("ai-connection").value]);
}
function accountRequest() {
  return {
    provider: $("ai-provider").value,
    selection: accountSelection(),
    epoch: accountSelectionEpoch,
  };
}
function accountRequestIsCurrent(request) {
  return (
    request.selection === accountSelection() &&
    request.epoch === accountSelectionEpoch
  );
}
function renderAccount() {
  const claude = $("ai-provider").value === "claude";
  const subscription = $("ai-connection").value === "subscription";
  const selection = accountSelection();
  if (credentialSelection !== null && credentialSelection !== selection) {
    $("api-key").value = "";
    accountFeedback = null;
    accountSelectionEpoch++;
  }
  credentialSelection = selection;
  const busy = accountSaving || accountVerifying || accountSigningIn;
  $("ai-provider").disabled = busy;
  $("ai-connection").disabled = busy;
  $("ai-enabled").disabled = busy;
  $("import-mac-keys").disabled = busy;
  $("refresh-claude").disabled = busy;
  for (const option of document.querySelectorAll("[data-ai-provider]")) {
    option.setAttribute(
      "aria-pressed",
      String(option.dataset.aiProvider === $("ai-provider").value),
    );
    option.disabled = busy;
  }
  for (const option of document.querySelectorAll("[data-ai-connection]")) {
    option.setAttribute(
      "aria-pressed",
      String(option.dataset.aiConnection === $("ai-connection").value),
    );
    option.disabled = busy;
  }
  const configured = Boolean(
    accountInfo?.[claude ? "claudeApiKey" : "openaiApiKey"],
  );
  const signedIn = Boolean(
    claude
      ? accountInfo?.claudeCode?.uses_subscription
      : accountInfo?.chatgpt?.signed_in,
  );
  $("api-key-row").hidden = subscription;
  $("subscription-row").hidden = !subscription;
  $("api-key-help").textContent = configured
    ? "Connected · Stored securely on this device."
    : "Uses your API account.";
  $("api-key").hidden = configured;
  $("api-key").disabled = busy;
  $("api-key").placeholder = claude ? "sk-ant-…" : "sk-…";
  $("save-api-key").hidden = configured;
  $("save-api-key").disabled = busy || !$("api-key").value.trim();
  $("remove-api-key").hidden = !configured;
  $("remove-api-key").disabled = busy;
  $("verify-api-key").hidden = !configured;
  $("verify-api-key").disabled = busy;
  $("verify-api-key").textContent = accountVerifying ? "Verifying…" : "Verify";
  $("subscription-title").textContent = claude ? "Claude Code" : "Account";
  $("subscription-help").textContent = claude
    ? signedIn
      ? "Connected through Claude Code. Uses your plan’s limits."
      : "Sign in through Claude Code with your Claude subscription."
    : signedIn
      ? accountInfo.chatgpt.email || "Connected through ChatGPT."
      : "Use an eligible ChatGPT plan. Cleanup uses plan limits or credits.";
  $("sign-in").hidden = accountSigningIn || (!claude && signedIn);
  $("sign-in").disabled =
    busy || (claude && accountInfo?.claudeCode?.available === false);
  $("sign-in").textContent = claude
    ? signedIn
      ? "Refresh status"
      : "Continue with Claude"
    : "Continue with ChatGPT";
  $("sign-in").classList.toggle("primary", !claude);
  $("sign-out").hidden = claude || !signedIn || accountSigningIn;
  $("sign-out").disabled = busy;
  $("cancel-sign-in").hidden = !accountSigningIn;
  $("claude-install-row").hidden =
    !subscription || !claude || accountInfo?.claudeCode?.available !== false;
  const error = subscription
    ? claude
      ? accountInfo?.claudeCodeError
      : accountInfo?.chatgpt?.error
    : accountInfo?.error;
  $("account-status").textContent = accountFeedback?.text || error || "";
  $("account-status").classList.toggle(
    "is-error",
    Boolean(accountFeedback ? accountFeedback.error : error),
  );
}
async function verifyAccountKey(request = accountRequest()) {
  if (accountVerifying || !accountRequestIsCurrent(request)) return;
  accountVerifying = true;
  accountFeedback = null;
  renderAccount();
  try {
    await invoke("verify_api_key", {
      provider: request.provider === "claude" ? "claude" : "openai",
    });
    if (accountRequestIsCurrent(request))
      accountFeedback = { text: "Connection verified.", error: false };
  } catch (e) {
    if (accountRequestIsCurrent(request))
      accountFeedback = { text: String(e), error: true };
  } finally {
    accountVerifying = false;
    renderAccount();
  }
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
    accountChecked = true;
    renderNotesSettings(current.view.settings);
    renderNotes(current.view);
  })().finally(() => {
    accountRefresh = null;
  });
  return accountRefresh;
}
function setupWorkspace() {
  workspaceReady = true;
  $("general-dictation").append(document.querySelector(".dictation-limit"));
  for (const tab of document.querySelectorAll("[data-settings-tab]")) {
    tab.onclick = () => showGeneralTab(tab.dataset.settingsTab);
    tab.onkeydown = (event) => {
      if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key))
        return;
      event.preventDefault();
      const index = settingsTabs.indexOf(generalTab),
        next =
          event.key === "Home"
            ? settingsTabs[0]
            : event.key === "End"
              ? settingsTabs.at(-1)
              : settingsTabs[
                  (index + (event.key === "ArrowRight" ? 1 : -1) + 4) % 4
                ];
      showGeneralTab(next);
      $("settings-tab-" + next).focus();
    };
  }
  $("open-settings").onclick = () => openSettings();
  $("close-settings").onclick = () => $("settings-dialog").close();
  $("settings-dialog").addEventListener("cancel", (event) => {
    // Esc belongs to the shortcut recorder while it is listening.
    if (shortcutCapturing) event.preventDefault();
  });
  $("settings-dialog").addEventListener("close", () => stopShortcutCapture());
  $("settings-dialog").addEventListener("click", (event) => {
    if (event.target === $("settings-dialog")) $("settings-dialog").close();
  });
  $("notes-connect-ai").onclick = () => {
    openSettings("ai");
    document.querySelector("[data-ai-provider][aria-pressed=true]").focus();
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
  // Wait for a short pause in typing before searching; clearing the field
  // and pressing Enter apply at once.
  let searchTimer = 0;
  const runSearch = () => {
    clearTimeout(searchTimer);
    appliedHistoryQuery = $("history-search").value.trim();
    historyLimit = HISTORY_PAGE;
    renderHistory(current.view);
    document.querySelector("main").scrollTop = 0;
  };
  $("history-search").addEventListener("input", () => {
    clearTimeout(searchTimer);
    if (!$("history-search").value.trim()) runSearch();
    else searchTimer = setTimeout(runSearch, 180);
  });
  $("history-search").addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      runSearch();
      return;
    }
    if (event.key !== "Escape") return;
    event.preventDefault();
    clearTimeout(searchTimer);
    if ($("history-search").value) setHistoryQuery("");
    else $("history-search").blur();
  });
  document.querySelector(".home-search").onpointerdown = (event) => {
    if (event.target.closest("input, button")) return;
    event.preventDefault();
    $("history-search").focus();
  };
  $("clear-history-search").onclick = () => {
    setHistoryQuery("");
    $("history-search").focus();
  };
  document.querySelector(".history-search-key").textContent =
    current.platform === "macos" ? "⌘F" : "Ctrl F";
  document.addEventListener("keydown", (event) => {
    if (
      !document.querySelector('[data-panel="dictation"]').hidden &&
      event.key.toLowerCase() === "f" &&
      (current.platform === "macos" ? event.metaKey : event.ctrlKey)
    ) {
      event.preventDefault();
      $("history-search").focus();
      $("history-search").select();
    }
  });
  $("notes-search").oninput = () => renderNotes(current.view);
  $("detect-calls-quick").onchange = () =>
    setting({ detectCalls: $("detect-calls-quick").checked }).catch(() => {});
  document.addEventListener("pointerdown", (event) => {
    for (const menu of document.querySelectorAll(
      "details.notes-menu[open], details.history-row-menu[open], details.history-filter-menu[open]",
    ))
      if (!menu.contains(event.target)) menu.open = false;
  });
  document.addEventListener("click", (event) => {
    const item = event.target.closest?.(".notes-menu-items button");
    if (item) item.closest("details").open = false;
  });
  document.addEventListener("keydown", (event) => {
    const menu = event.target.closest?.("details.notes-menu[open]");
    if (event.key !== "Escape" || !menu) return;
    event.preventDefault();
    menu.open = false;
    menu.querySelector("summary").focus();
  });
  $("notes-open-actions").onclick = () => {
    notesActionMode = true;
    selectedNote = null;
    renderNotes(current.view);
  };
  $("discard-meeting").onclick = () => {
    if (
      confirm(
        "Discard this recording? The recording and its transcript will be deleted.",
      )
    )
      call("cancel").catch(() => {});
  };

  for (const [id, kind] of [
    ["start-meeting", "meeting"],
    ["start-voice", "voice"],
  ])
    $(id).onclick = () => {
      selectedNote = null;
      notesActionMode = false;
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
  for (const option of document.querySelectorAll("[data-ai-provider]"))
    option.onclick = async () => {
      $("ai-provider").value = option.dataset.aiProvider;
      try {
        await $("ai-provider").onchange();
      } catch (e) {
        accountFeedback = { text: String(e), error: true };
        renderAccount();
      }
    };
  for (const option of document.querySelectorAll("[data-ai-connection]"))
    option.onclick = () => {
      $("ai-connection").value = option.dataset.aiConnection;
      $("ai-connection").onchange();
    };
  $("api-key").oninput = () => {
    $("save-api-key").disabled =
      accountSaving ||
      accountVerifying ||
      accountSigningIn ||
      !$("api-key").value.trim();
  };
  $("api-key").onkeydown = (event) => {
    if (event.key === "Enter" && !$("save-api-key").disabled)
      $("save-api-key").click();
  };
  $("verify-api-key").onclick = () => verifyAccountKey();
  $("refresh-claude").onclick = refreshAccount;
  document.querySelector("#claude-install-row a").onclick = async (event) => {
    event.preventDefault();
    try {
      await invoke("open_claude_install");
    } catch (e) {
      accountFeedback = { text: String(e), error: true };
      renderAccount();
    }
  };
  $("save-api-key").onclick = async () => {
    if (accountSaving || accountVerifying || accountSigningIn) return;
    const draft = $("api-key").value,
      key = draft.trim();
    if (!key) return;
    const request = accountRequest();
    accountSaving = true;
    accountFeedback = null;
    renderAccount();
    try {
      await invoke("save_api_key", { provider: request.provider, key });
      if (accountRequestIsCurrent(request) && $("api-key").value === draft) {
        $("api-key").value = "";
        await setting({ claudeCleanup: true });
        $("ai-enabled").checked = true;
      }
      await refreshAccount();
      if (accountRequestIsCurrent(request)) await verifyAccountKey(request);
    } catch (e) {
      if (accountRequestIsCurrent(request))
        accountFeedback = { text: String(e), error: true };
    } finally {
      accountSaving = false;
      renderAccount();
    }
  };
  $("remove-api-key").onclick = async () => {
    if (
      !confirm(
        "Remove API key? API cleanup will stop until you add another key or change the connection.",
      )
    )
      return;
    try {
      await invoke("save_api_key", {
        provider: $("ai-provider").value,
        key: "",
      });
      accountFeedback = null;
      await refreshAccount();
    } catch (e) {
      accountFeedback = { text: String(e), error: true };
      renderAccount();
    }
  };
  $("sign-in").onclick = async () => {
    const claude = $("ai-provider").value === "claude";
    if (claude && accountInfo?.claudeCode?.uses_subscription) {
      await refreshAccount();
      return;
    }
    accountSigningIn = true;
    accountFeedback = null;
    renderAccount();
    try {
      await invoke(claude ? "claude_sign_in" : "chatgpt_sign_in");
      await refreshAccount();
      if (
        claude
          ? accountInfo?.claudeCode?.uses_subscription
          : accountInfo?.chatgpt?.signed_in
      ) {
        await setting({ claudeCleanup: true });
        $("ai-enabled").checked = true;
      }
    } catch (e) {
      accountFeedback = { text: String(e), error: true };
    } finally {
      accountSigningIn = false;
      renderAccount();
    }
  };
  $("sign-out").onclick = async () => {
    if (!confirm("Sign out of ChatGPT?")) return;
    try {
      await invoke("chatgpt_sign_out");
      accountFeedback = null;
      await refreshAccount();
    } catch (e) {
      accountFeedback = { text: String(e), error: true };
      renderAccount();
    }
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
  $("record-shortcut").oncontextmenu = (event) => {
    event.preventDefault();
    $("shortcut-options").open = true;
    $("shortcut-kind").focus();
  };
  $("reset-shortcut").onclick = () => {
    shortcutDirty = false;
    shortcutSaved = null;
    syncShortcut(current.view.settings);
    $("shortcut-status").textContent = "Changes discarded.";
  };
  $("save-shortcut").onclick = saveShortcut;
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
  $("original-keys-row").hidden = current.platform !== "macos";
  $("import-mac-keys").onclick = async () => {
    $("import-mac-keys").disabled = true;
    try {
      const result = await call("import_mac_api_keys");
      await refreshAccount();
      $("key-import-status").textContent =
        `Claude: ${result.claude}. OpenAI: ${result.openai}. Original keys were kept.`;
    } catch (error) {
      $("key-import-status").textContent =
        `Could not import API keys: ${String(error)}`;
    } finally {
      $("import-mac-keys").disabled = false;
    }
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
  window.pressayAsk.setup();

  document.addEventListener("keydown", (event) => {
    if (
      !(current.platform === "macos" ? event.metaKey : event.ctrlKey) ||
      event.altKey
    )
      return;
    if (event.key === ",") {
      event.preventDefault();
      openSettings();
    }
    if (document.querySelector('[data-panel="meetings"]').hidden) return;
    if (event.key.toLowerCase() === "j") {
      event.preventDefault();
      window.pressayAsk.toggle();
    }
    if (
      event.key === "Enter" &&
      !$("stop-meeting").hidden &&
      !$("stop-meeting").disabled
    ) {
      event.preventDefault();
      $("stop-meeting").click();
    }
  });
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
}
