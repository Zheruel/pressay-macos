"use strict";
// First-run tour, modeled on Hex's: the speech model downloads from the first
// moment, a short demo plays while it does, one screen asks for the
// permissions, then an optional practice and a ready page. Runs only in the
// dedicated onboarding window (index.html?onboarding).
(() => {
  if (!setupWindow) return;
  const tour = $("onboarding");
  const SCENES = ["setup", "demo", "permissions", "waiting", "try", "ready"];
  const OPTIONAL = new Set(["demo", "try"]);
  let scene = null,
    data = null,
    started = false,
    setupTimer = null,
    setupHeld = false,
    downloadRequested = null,
    demoRun = 0,
    advanceTimer = null;
  // Accessibility: asked, and whether we've seen the person leave for System
  // Settings and come back still untrusted ("Still grey? Fix it").
  const access = { asked: false, left: false, returnedAt: 0, grantedAt: 0 };
  const failure = (e) => ($("setup-error").textContent = String(e));
  const clearFailure = () => ($("setup-error").textContent = "");

  // --- State helpers -------------------------------------------------------
  const mac = () => data?.platform === "macos";
  const modelReady = () =>
    !!(
      data?.view.model_ready &&
      $("tour-model").value === data.view.settings.asrModel
    );
  const downloading = () =>
    !!data && ["preparing", "loading"].includes(data.view.stage);
  const progress = () => {
    const p = data?.view.progress;
    return p && p.total ? p.downloaded / p.total : null;
  };
  function rowsNeeded() {
    if (!data) return [];
    const p = data.permissions;
    if (mac()) return ["microphone", "accessibility"];
    // Windows/X11 grant nothing to ask; Wayland asks for keyboard control.
    return p.wayland ? ["accessibility"] : [];
  }
  function permissionState(kind) {
    const p = data.permissions;
    if (kind === "microphone") {
      return p.microphone === "granted"
        ? "ready"
        : p.microphone === "denied"
          ? "denied"
          : "todo";
    }
    if (!mac()) return p.insertion === "granted" ? "ready" : "todo";
    if (p.insertion !== "granted") {
      access.grantedAt = 0;
      return access.asked &&
        access.left &&
        access.returnedAt &&
        Date.now() - access.returnedAt > 2000
        ? "stale"
        : "todo";
    }
    // Trusted: the shortcut tap follows within a poll. If it still has not
    // started after a few seconds, macOS wants a fresh process.
    if (p.shortcut === "granted") return "ready";
    if (!access.grantedAt) access.grantedAt = Date.now();
    return Date.now() - access.grantedAt > 4000 ? "restart" : "ready-pending";
  }
  const permissionsReady = () =>
    rowsNeeded().every((kind) => permissionState(kind) === "ready");

  // --- Navigation ----------------------------------------------------------
  function next(from) {
    const order = SCENES.slice(SCENES.indexOf(from) + 1);
    for (const s of order) {
      if (s === "permissions" && permissionsReady()) continue;
      if (s === "waiting" && modelReady()) continue;
      return s;
    }
    return "ready";
  }
  function show(name) {
    if (scene === name) return;
    scene = name;
    clearTimeout(advanceTimer);
    clearFailure();
    for (const section of tour.querySelectorAll("[data-scene]"))
      section.hidden = section.dataset.scene !== name;
    if (name === "setup") enterSetup();
    if (name === "demo") playDemo();
    else demoRun++;
    if (name === "try") enterTry();
    render();
    tour
      .querySelector(`[data-scene="${name}"] h1`)
      ?.focus?.({ preventScroll: true });
  }
  function advance() {
    show(next(scene));
  }

  // --- Setting up: the download starts by itself ---------------------------
  function startDownload() {
    const id = $("tour-model").value;
    if (!data || modelReady() || downloading() || downloadRequested === id)
      return;
    if (data.view.stage !== "idle") return;
    downloadRequested = id;
    call("prepare_model", { id }).catch((e) => {
      downloadRequested = null;
      failure(e);
    });
  }
  function enterSetup() {
    setupHeld = false;
    clearTimeout(setupTimer);
    startDownload();
    // Like Hex, the page moves on by itself unless the person reaches for
    // the model picker.
    setupTimer = setTimeout(() => {
      if (scene === "setup" && !setupHeld) advance();
    }, 2600);
  }
  $("tour-model").addEventListener("focus", () => {
    setupHeld = true;
    render();
  });
  $("tour-model").onchange = () => {
    setupHeld = true;
    downloadRequested = null;
    startDownload();
    render();
  };
  $("tour-setup-continue").onclick = advance;

  // --- Demo: typing vs speaking --------------------------------------------
  const KEYS = ["`1234567890-=", "qwertyuiop[]", "asdfghjkl;'", "zxcvbnm,./"];
  const keyboard = $("tour-keyboard");
  for (const line of KEYS) {
    const row = document.createElement("div");
    for (const k of line) {
      const key = document.createElement("i");
      key.textContent = k;
      key.dataset.key = k;
      row.append(key);
    }
    keyboard.append(row);
  }
  const space = document.createElement("div");
  const bar = document.createElement("i");
  bar.className = "tour-space";
  bar.dataset.key = " ";
  space.append(bar);
  keyboard.append(space);
  const REPLY = "Every test is green and prod is warm. Ship it right now.";
  // Two typos, each noticed and fixed, the way people actually type.
  const TYPED = [
    ..."Every tets",
    "⌫",
    "⌫",
    ..."st is green and prid",
    "⌫",
    "⌫",
    ..."od is warm. Ship it",
  ];
  const wait = (ms, run) =>
    new Promise((resolve, reject) =>
      setTimeout(() => (run === demoRun ? resolve() : reject()), ms),
    );
  function press(key) {
    const el = keyboard.querySelector(
      `[data-key="${CSS.escape(key.toLowerCase())}"]`,
    );
    if (!el) return;
    el.classList.add("down");
    setTimeout(() => el.classList.remove("down"), 110);
  }
  async function playDemo() {
    const run = ++demoRun;
    const text = $("tour-demo-text");
    const reply = $("tour-demo-reply");
    $("tour-demo-continue").hidden = true;
    $("tour-versus").hidden = true;
    $("tour-hud").hidden = true;
    $("tour-demo-sent").hidden = true;
    keyboard.hidden = false;
    reply.classList.remove("spoken");
    text.textContent = "";
    $("tour-demo-title").textContent = "Typing it out";
    $("tour-demo-lead").textContent = "The usual way: one key at a time.";
    try {
      await wait(700, run);
      for (const ch of TYPED) {
        if (ch === "⌫") text.textContent = text.textContent.slice(0, -1);
        else text.textContent += ch;
        press(ch === "⌫" ? "" : ch);
        await wait(
          ch === " " ? 150 : ch === "⌫" ? 230 : 85 + Math.random() * 60,
          run,
        );
      }
      await wait(600, run);
      text.textContent = "";
      keyboard.hidden = true;
      $("tour-demo-title").textContent = "Now say it";
      $("tour-demo-lead").textContent = "Hold your key, talk, let go.";
      $("tour-hud").hidden = false;
      await wait(1900, run);
      $("tour-hud").hidden = true;
      reply.classList.add("spoken");
      text.textContent = REPLY;
      await wait(450, run);
      $("tour-demo-sent").hidden = false;
      $("tour-demo-title").textContent = "Five times faster";
      $("tour-demo-lead").textContent =
        "Typed with two typos. Spoken without any.";
      $("tour-versus").hidden = false;
      $("tour-demo-continue").hidden = false;
      $("tour-demo-continue").focus();
    } catch {}
  }
  $("tour-demo-continue").onclick = advance;

  // --- Permissions ---------------------------------------------------------
  async function grant(kind, state) {
    clearFailure();
    try {
      if (kind === "accessibility" && data.permissions.wayland) {
        await call("save_settings", { patch: { waylandCurrentCursor: true } });
        await call("request_permission", { kind: "accessibility" });
        return;
      }
      if (kind === "accessibility") {
        access.asked = true;
        access.left = false;
        access.returnedAt = 0;
      }
      await call("request_permission", {
        kind: state === "stale" ? "accessibility-reset" : kind,
      });
    } catch (e) {
      failure(e);
    }
  }
  for (const row of tour.querySelectorAll("[data-permission]")) {
    row.querySelector("button").onclick = () => {
      const kind = row.dataset.permission;
      grant(kind, permissionState(kind));
    };
  }
  window.addEventListener("blur", () => {
    if (access.asked) access.left = true;
  });
  window.addEventListener("focus", () => {
    if (access.asked && access.left) access.returnedAt = Date.now();
  });
  const restart = () => call("restart_app").catch(failure);
  $("tour-restart").onclick = restart;
  $("tour-reopen-button").onclick = restart;

  // --- Practice: answer the lit message ------------------------------------
  const INBOX = [
    ["Sam next door", "hey are you near the shop? could you grab some milk"],
    ["Priya · Design", "Can you send me your notes from today’s review?"],
    ["Mom", "Are you still coming for dinner on Sunday?"],
  ];
  let lit = 0,
    sent = 0,
    practiceReady = false,
    practiceEpoch = 0,
    completed = false;
  function buildInbox() {
    const inbox = $("tour-inbox");
    inbox.replaceChildren();
    INBOX.forEach(([from, body], index) => {
      const card = document.createElement("article");
      card.className = "tour-message";
      card.innerHTML = `<header><span class="tour-app-icon" aria-hidden="true"></span><div><small>Messages</small><strong></strong></div><small>now</small></header><p></p><textarea rows="2" spellcheck="false" placeholder="iMessage"></textarea>`;
      card.querySelector("strong").textContent = from;
      card.querySelector("p").textContent = body;
      const field = card.querySelector("textarea");
      field.setAttribute("aria-label", `Reply to ${from}`);
      field.addEventListener("keydown", (event) => {
        if (event.key === "Escape") call("cancel").catch(() => {});
      });
      field.addEventListener("focus", () => {
        if (index !== lit && !card.classList.contains("sent")) light(index);
      });
      inbox.append(card);
    });
  }
  async function light(index) {
    lit = index;
    const epoch = ++practiceEpoch;
    practiceReady = false;
    const cards = [...$("tour-inbox").children];
    cards.forEach((card, i) => card.classList.toggle("lit", i === index));
    const field = cards[index]?.querySelector("textarea");
    try {
      await call("begin_practice");
      if (epoch !== practiceEpoch || scene !== "try") return;
      practiceReady = true;
      field?.focus();
    } catch (e) {
      failure(e);
    }
  }
  function enterTry() {
    sent = 0;
    buildInbox();
    light(0);
  }
  async function checkPractice() {
    const p = data.view.practice;
    const card = $("tour-inbox").children[lit];
    if (!practiceReady || !card || card.classList.contains("sent")) return;
    const field = card.querySelector("textarea");
    const recognized = p?.recognized_text?.trim();
    if (
      !(p?.received_audio && p?.inserted && p?.in_app && recognized) ||
      field.value.trim() !== recognized
    )
      return;
    practiceReady = false;
    card.classList.add("sent");
    field.readOnly = true;
    sent++;
    if (!completed) {
      try {
        await call("complete_onboarding", { observed: field.value });
        completed = true;
      } catch (e) {
        failure(e);
      }
    }
    const nextCard = [...$("tour-inbox").children].findIndex(
      (c) => !c.classList.contains("sent"),
    );
    if (nextCard < 0) setTimeout(() => scene === "try" && show("ready"), 900);
    else setTimeout(() => scene === "try" && light(nextCard), 700);
    render();
  }
  $("tour-done").onclick = () => show("ready");

  // --- Skip, ready, close --------------------------------------------------
  async function finishSkipped() {
    if (completed) return true;
    try {
      await call("complete_onboarding", { observed: "", skipped: true });
      completed = true;
      return true;
    } catch (e) {
      failure(e);
      return false;
    }
  }
  $("tour-skip").onclick = async () => {
    if (scene === "try") {
      if (await finishSkipped()) show("ready");
    } else advance();
  };
  $("tour-try-again").onclick = () => show("try");
  $("tour-finish").onclick = async () => {
    if (!(await finishSkipped())) return;
    close();
  };
  async function close() {
    try {
      await call("close_onboarding");
      setupWindowVisible = false;
      tour.hidden = true;
    } catch (e) {
      failure(e);
    }
  }

  // --- Render --------------------------------------------------------------
  function keycaps(label) {
    return label
      .split(/\s*\+\s*/)
      .filter(Boolean)
      .map((part) => {
        const key = document.createElement("kbd");
        key.textContent = part;
        return key;
      });
  }
  function renderPill(pill, withModel) {
    const fraction = progress();
    pill.querySelector(".tour-pill-percent").textContent = modelReady()
      ? "Ready"
      : fraction == null
        ? data.view.stage === "loading"
          ? "Loading…"
          : "Starting…"
        : `${Math.round(fraction * 100)}%`;
    pill.classList.toggle("done", modelReady());
    pill.style.setProperty("--progress", modelReady() ? 1 : (fraction ?? 0.08));
    if (withModel) {
      const model = data.models.find((m) => m.id === $("tour-model").value);
      pill.querySelector(".tour-pill-model").textContent = model?.name || "";
    }
  }
  function renderRows() {
    const rows = rowsNeeded();
    for (const row of tour.querySelectorAll("[data-permission]")) {
      const kind = row.dataset.permission;
      row.hidden = !rows.includes(kind);
      if (row.hidden) continue;
      const state = permissionState(kind);
      const detail = row.querySelector(".tour-row-detail");
      const status = row.querySelector(".tour-row-state");
      const button = row.querySelector("button");
      if (kind === "accessibility")
        row.querySelector(".tour-row-title").textContent = mac()
          ? "Accessibility"
          : "Keyboard control";
      detail.textContent =
        kind === "microphone"
          ? state === "denied"
            ? "Switch on Pressay in System Settings"
            : "Opens only while you hold your key, then closes"
          : state === "stale"
            ? "An older Pressay entry can keep this off"
            : state === "restart"
              ? "Turns on when Pressay restarts"
              : mac()
                ? "Notices your key and types your words in any app"
                : "Types your words at the current cursor";
      const done = state === "ready" || state === "ready-pending";
      status.replaceChildren();
      if (done) {
        status.innerHTML =
          '<svg aria-hidden="true"><use href="#tour-check" /></svg>';
        status.append("Allowed");
      } else if (state === "restart") status.textContent = "Needs a restart";
      status.className = `tour-row-state${done ? " allowed" : ""}`;
      button.hidden = done || state === "restart";
      button.textContent =
        state === "denied"
          ? "Open System Settings"
          : state === "stale"
            ? "Still grey? Fix it"
            : !mac()
              ? "Enable"
              : "Allow";
    }
    // The first row still to do carries the accent, as in Hex.
    const first = [...tour.querySelectorAll("[data-permission]")].find(
      (row) => !row.hidden && !row.querySelector("button").hidden,
    );
    tour
      .querySelectorAll("[data-permission] button")
      .forEach((b) =>
        b.classList.toggle("tour-primary", b.parentElement === first),
      );
    $("tour-restart").hidden = !rows.some(
      (k) => permissionState(k) === "restart",
    );
  }
  function render() {
    if (!data || !scene) return;
    const shortcut = data.shortcut;
    tour
      .querySelectorAll(".tour-keys")
      .forEach((el) => el.replaceChildren(...keycaps(shortcut)));
    // Top bar: the download follows the whole tour, except on the pages that
    // are about it.
    const showTop =
      !["setup", "waiting", "ready"].includes(scene) && downloading();
    $("tour-top-pill").hidden = !showTop || modelReady();
    if (showTop) renderPill($("tour-top-pill"), true);
    $("tour-skip").hidden = !OPTIONAL.has(scene);
    $("tour-reopen").hidden =
      scene !== "try" ||
      data.permissions.shortcut === "granted" ||
      !permissionsReady();
    if (scene === "setup") {
      renderPill($("tour-setup-pill"));
      $("tour-download-verb").textContent = modelReady()
        ? "Your"
        : data.view.stage === "loading"
          ? "Loading"
          : "Downloading";
      $("tour-setup-continue").hidden = !setupHeld;
    }
    if (scene === "permissions") {
      renderRows();
      if (permissionsReady() && !advanceTimer) {
        // Hold the last check a beat so it is seen.
        advanceTimer = setTimeout(() => {
          advanceTimer = null;
          if (scene === "permissions" && permissionsReady()) advance();
        }, 900);
      }
    }
    if (scene === "waiting") {
      renderPill($("tour-waiting-pill"));
      const failed = !downloading() && !modelReady() && data.view.error;
      $("tour-retry-model").hidden = !failed;
      if (failed) failure(data.view.error);
      if (modelReady()) advance();
    }
    if (scene === "try") {
      checkPractice();
      const stage = data.view.stage;
      $("tour-try-hint").textContent = stage.startsWith("meeting")
        ? "Stop the Notetaker to practice."
        : stage === "recording"
          ? "Listening…"
          : stage === "starting"
            ? "Opening your microphone…"
            : ["processing", "polishing"].includes(stage)
              ? "Typing…"
              : "";
      $("tour-done").disabled = !completed;
    }
    // Losing a permission or the model mid-tour returns to the step that
    // needs it, the way Hex waits at setup.
    if (["try", "ready"].includes(scene) && !completed && !permissionsReady())
      show("permissions");
    else if (scene === "try" && !modelReady()) show("waiting");
  }
  $("tour-retry-model").onclick = () => {
    downloadRequested = null;
    clearFailure();
    startDownload();
  };

  // --- Window lifecycle ----------------------------------------------------
  function open() {
    tour.hidden = false;
    setupWindowVisible = true;
    completed = !!data?.view.settings.onboardingComplete;
    scene = null;
    show("setup");
  }
  window.pressayOnboarding = {
    show,
    render(next) {
      data = next;
      if (!started) {
        started = true;
        populateModels("tour-model");
        // Plain names, as in Hex's capsule; the ranking lives in Settings.
        for (const option of $("tour-model").options)
          option.textContent =
            data.models.find((m) => m.id === option.value)?.name ||
            option.textContent;
        $("tour-model").value = data.view.settings.asrModel;
        if (setupWindowVisible) open();
        return;
      }
      render();
    },
  };
  window.__TAURI__.event.listen("pressay-onboarding-open", () => {
    setupWindowVisible = true;
    refresh().then(() => started && open());
  });
  window.__TAURI__.event.listen("pressay-onboarding-hidden", () => {
    setupWindowVisible = false;
    ++practiceEpoch;
    ++demoRun;
    tour.hidden = true;
  });
})();
