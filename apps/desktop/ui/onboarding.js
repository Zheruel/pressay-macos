"use strict";
// First-run setup, modeled on Hex's: the speech model downloads from the first
// moment, one screen asks for Microphone and Accessibility, "Almost ready"
// waits for the model if needed, then Pressay is ready. Runs only in the
// dedicated onboarding window (index.html?onboarding).
(() => {
  if (!setupWindow) return;
  const tour = $("onboarding");
  const SCENES = ["setup", "permissions", "waiting", "ready"];
  let scene = null,
    data = null,
    started = false,
    setupTimer = null,
    setupHeld = false,
    downloadRequested = null,
    advanceTimer = null,
    completed = false;
  // Accessibility: asked, and whether the person left for System Settings and
  // came back still untrusted ("Still grey? Fix it").
  const access = { asked: false, left: false, returnedAt: 0, grantedAt: 0 };
  const failure = (e) => ($("setup-error").textContent = String(e));
  const clearFailure = () => ($("setup-error").textContent = "");

  // --- State ---------------------------------------------------------------
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
    if (mac()) return ["microphone", "accessibility"];
    // Windows/X11 grant nothing to ask; Wayland asks for keyboard control.
    return data.permissions.wayland ? ["accessibility"] : [];
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
    // Trusted: the talk-key tap follows within a poll. If it still has not
    // started after a few seconds, macOS wants a fresh process.
    if (p.shortcut === "granted") return "ready";
    if (!access.grantedAt) access.grantedAt = Date.now();
    return Date.now() - access.grantedAt > 4000 ? "restart" : "ready-pending";
  }
  const permissionsReady = () =>
    rowsNeeded().every((kind) => permissionState(kind) === "ready");

  // --- Navigation ----------------------------------------------------------
  function next(from) {
    for (const s of SCENES.slice(SCENES.indexOf(from) + 1)) {
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
    advanceTimer = null;
    clearFailure();
    for (const section of tour.querySelectorAll("[data-scene]"))
      section.hidden = section.dataset.scene !== name;
    if (name === "setup") enterSetup();
    if (name === "ready") finish();
    render();
  }
  const advance = () => show(next(scene));

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
  $("tour-restart").onclick = () => call("restart_app").catch(failure);

  // --- Ready ---------------------------------------------------------------
  async function finish() {
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
  $("tour-finish").onclick = async () => {
    if (!(await finish())) return;
    try {
      await call("close_onboarding");
      setupWindowVisible = false;
      tour.hidden = true;
    } catch (e) {
      failure(e);
    }
  };

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
      const status = row.querySelector(".tour-row-state");
      const button = row.querySelector("button");
      if (kind === "accessibility")
        row.querySelector(".tour-row-title").textContent = mac()
          ? "Accessibility"
          : "Keyboard control";
      row.querySelector(".tour-row-detail").textContent =
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
    tour
      .querySelectorAll(".tour-keys")
      .forEach((el) => el.replaceChildren(...keycaps(data.shortcut)));
    // The download follows into Permissions in the top bar.
    const showTop = scene === "permissions" && downloading();
    $("tour-top-pill").hidden = !showTop;
    if (showTop) renderPill($("tour-top-pill"), true);
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
    // Losing a permission before setup completes returns to that screen.
    if (scene === "ready" && !completed && !permissionsReady())
      show("permissions");
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
        // Plain names in the capsule; the ranking lives in Settings.
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
    tour.hidden = true;
  });
})();
