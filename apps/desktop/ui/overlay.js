"use strict";
const island = document.querySelector("#island"),
  reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");
let phase = "idle",
  levels = [0, 0, 0, 0],
  notch = { width: 0, height: 0 },
  hovering = false;
let recordingStarted = 0,
  meetingElapsed = 0,
  meetingUpdated = 0,
  dismissal;
const meetingPhases = ["meeting", "meeting_finishing"];
function islandMetrics() {
  const gap = notch.width,
    band = gap ? Math.max(notch.height, 30) : 32;
  if (meetingPhases.includes(phase) && hovering)
    return {
      width: Math.max(gap + 156, 240),
      height: band + 44,
      radius: 20,
      shoulder: 9,
    };
  if (phase === "error")
    return {
      width: Math.max(gap + 190, 340),
      height: gap ? band + 36 : 40,
      radius: 20,
      shoulder: 9,
    };
  const ears = {
    starting: 36,
    recording: gap ? 78 : 64,
    processing: gap ? 102 : 74,
    polishing: gap ? 90 : 66,
    success: gap ? 82 : 60,
    meeting: gap ? 78 : 64,
    meeting_finishing: gap ? 78 : 64,
  };
  if (ears[phase])
    return {
      width: gap + ears[phase] * 2,
      height: band,
      radius: band * 0.44,
      shoulder: 7,
    };
  return gap
    ? { width: gap, height: notch.height, radius: 9, shoulder: 5 }
    : { width: 90, height: 6, radius: 3, shoulder: 3 };
}
function drawIsland() {
  const m = islandMetrics(),
    width = m.width + 2 * m.shoulder,
    height = m.height;
  const s = Math.min(m.shoulder, width / 4, height / 2),
    r = Math.max(0, Math.min(m.radius, (width - 2 * s) / 2, height - s));
  island.style.width = `${width}px`;
  island.style.height = `${height}px`;
  document.documentElement.style.setProperty(
    "--band",
    `${notch.width ? Math.max(notch.height, 30) : 32}px`,
  );
  document.documentElement.style.setProperty("--gap", `${notch.width}px`);
  document.documentElement.style.setProperty("--shoulder", `${m.shoulder}px`);
  document.body.classList.toggle("has-notch", notch.width > 0);
  document
    .querySelector("#island-background")
    .setAttribute("viewBox", `0 0 ${width} ${height}`);
  document
    .querySelector("#island-shape")
    .setAttribute(
      "d",
      `M0 0 Q${s} 0 ${s} ${s} L${s} ${height - r} Q${s} ${height} ${s + r} ${height} L${width - s - r} ${height} Q${width - s} ${height} ${width - s} ${height - r} L${width - s} ${s} Q${width - s} 0 ${width} 0 Z`,
    );
  document.querySelector("#island-meeting-controls").hidden =
    !meetingPhases.includes(phase) || !hovering;
  document.querySelector("#overlay-stop").disabled = phase !== "meeting";
  document.querySelector("#island-meeting-label").textContent =
    phase === "meeting_finishing" ? "Saving your notes…" : "Taking notes";
}
function updateLevels(values) {
  levels = Array.from({ length: 4 }, (_, i) =>
    Number.isFinite(Number(values?.[i]))
      ? Math.max(0, Math.min(1, Number(values[i])))
      : 0,
  );
  drawLevels();
}
function drawLevels() {
  const profiles = [0.55, 0.85, 1, 0.8, 0.6],
    bands = [
      levels[0],
      levels[1],
      (levels[1] + levels[2]) / 2,
      levels[2],
      levels[3],
    ];
  const time = performance.now() / 1000;
  document.querySelectorAll(".overlay-wave i").forEach((bar, index) => {
    const value = phase === "starting" ? 0 : bands[index],
      sway = reduceMotion.matches
        ? 1
        : 1 + 1.1 * Math.sin(time * 3.2 + index * 1.2);
    bar.style.height = `${value > 0.015 ? Math.min(18, 5 + 13 * Math.pow(value, 0.7) * profiles[index]) : 3 + sway}px`;
  });
}
function timerText(seconds) {
  seconds = Math.max(0, Math.floor(seconds));
  return seconds >= 3600
    ? `${Math.floor(seconds / 3600)}:${String(Math.floor(seconds / 60) % 60).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`
    : `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}
function drawTimer() {
  const seconds =
    phase === "recording"
      ? (performance.now() - recordingStarted) / 1000
      : meetingElapsed +
        (phase === "meeting" ? (performance.now() - meetingUpdated) / 1000 : 0);
  document.querySelector("#island-timer").textContent = timerText(seconds);
}
function setPhase(next, detail = "") {
  const previous = phase;
  phase = next;
  document.body.dataset.phase = phase;
  if (phase === "recording" && previous !== phase)
    recordingStarted = performance.now();
  if (!meetingPhases.includes(phase)) hovering = false;
  const labels = {
    processing: "Transcribing",
    polishing: "Polishing",
    meeting_finishing: "Saving",
    success: detail || "Inserted",
  };
  document.querySelector("#overlay-status").textContent = labels[phase] || "";
  document.querySelector("#island-banner").hidden = phase !== "error";
  document.querySelector("#island-error").textContent =
    detail || "Saved in History";
  island.setAttribute(
    "aria-label",
    phase === "recording"
      ? "Recording dictation"
      : phase === "meeting"
        ? "Meeting recording"
        : phase === "starting"
          ? "Opening microphone"
          : detail || labels[phase] || "Pressay dictation",
  );
  drawIsland();
  drawLevels();
  drawTimer();
  if (previous !== phase) {
    clearTimeout(dismissal);
    if (phase === "success" || phase === "error")
      dismissal = setTimeout(
        () => setPhase("idle"),
        phase === "error" ? 2600 : detail === "Saved" ? 1200 : 900,
      );
  }
}
window.__TAURI__.event.listen("pressay-levels", ({ payload }) =>
  updateLevels(
    Array.isArray(payload) ? payload : payload.audio_levels || payload.levels,
  ),
);
window.__TAURI__.event.listen("pressay-overlay-hover", ({ payload }) => {
  hovering = !!payload.hover;
  drawIsland();
});
window.__TAURI__.event.listen("pressay-overlay", ({ payload }) => {
  if (payload.notch)
    notch = {
      width: Math.max(0, Number(payload.notch.width) || 0),
      height: Math.max(0, Number(payload.notch.height) || 0),
    };
  const elapsed = Number(payload.meeting_elapsed);
  if (Number.isFinite(elapsed)) {
    meetingElapsed = Math.max(0, elapsed);
    meetingUpdated = performance.now();
  }
  const next = payload.stage === "cancelled" ? "idle" : payload.stage;
  setPhase(next, payload.error || payload.overlay_message || "");
  updateLevels(payload.audio_levels);
});
document.querySelector("#overlay-stop").onclick = async () => {
  if (phase !== "meeting") return;
  document.querySelector("#overlay-stop").disabled = true;
  try {
    await window.__TAURI__.core.invoke("stop_meeting");
  } catch (error) {
    setPhase("error", String(error));
  }
};
// DOM pointer tracking also supports platforms where only local pointer events are available.
island.addEventListener("mouseenter", () => {
  if (meetingPhases.includes(phase)) {
    hovering = true;
    drawIsland();
  }
});
island.addEventListener("mouseleave", () => {
  hovering = false;
  drawIsland();
});
setInterval(() => {
  if (phase !== "idle") {
    drawTimer();
    if (!reduceMotion.matches) drawLevels();
  }
}, 100);
reduceMotion.addEventListener("change", drawLevels);
setPhase("idle");
