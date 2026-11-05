window.__TAURI__.event.listen("pressay-state", ({ payload }) => {
  document.querySelector("#overlay-status").textContent =
    payload.stage === "processing"
      ? "Transcribing on your device…"
      : "Listening…";
});
