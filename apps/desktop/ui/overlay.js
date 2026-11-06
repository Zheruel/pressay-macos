"use strict";
const overlayLabels = {
  starting: "Opening microphone…",
  recording: "Listening · Esc to cancel",
  processing: "Transcribing · Esc to cancel",
  polishing: "Polishing your words…",
  meeting: "Meeting recording",
  meeting_finishing: "Finishing meeting…",
  success: "Inserted",
  error: "Saved in History",
  cancelled: "Cancelled",
};
function updateLevels(levels) {
  document.querySelectorAll(".overlay-wave i").forEach((bar, index) => {
    const value = Number(levels?.[index] || 0);
    bar.style.height = `${6 + 24 * (Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : 0)}px`;
  });
}
window.__TAURI__.event.listen("pressay-levels", ({ payload }) => {
  updateLevels(Array.isArray(payload) ? payload : payload.audio_levels || payload.levels);
});
window.__TAURI__.event.listen("pressay-overlay", ({ payload }) => {
  const phase = payload.stage;
  document.body.dataset.phase = phase;
  const elapsed = Number(payload.meeting_elapsed || 0);
  const detail = phase === "meeting" && elapsed > 0
    ? `Meeting · ${Math.floor(elapsed / 60)}:${String(Math.floor(elapsed % 60)).padStart(2, "0")}`
    : overlayLabels[phase] || "Pressay";
  document.querySelector("#overlay-status").textContent =
    payload.error || payload.overlay_message || detail;
  const stop = document.querySelector("#overlay-stop");
  stop.hidden = phase !== "meeting";
  updateLevels(payload.audio_levels);
});
document.querySelector("#overlay-stop").onclick = async () => {
  try {
    await window.__TAURI__.core.invoke("stop_meeting");
  } catch (error) {
    document.querySelector("#overlay-status").textContent = String(error);
  }
};
