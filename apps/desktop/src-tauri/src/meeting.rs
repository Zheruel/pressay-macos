//! A recording owns one ASR worker. Dictation remains blocked until it closes.
use crate::{
    engine::{self, Shared},
    meeting_capture::{self, Event, Track},
    workspace::Workspace,
};
use pressay_core::{
    analysis::{self, AnalysisHost, MeetingSpool, VadResult},
    catalog, download,
    notes::{Note, Speaker, TranscriptLine},
    segmenter::{Segment, Segmenter},
    worker::WorkerHost,
};
use std::{
    collections::VecDeque,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tauri::{AppHandle, Manager};
use tokio_util::sync::CancellationToken;

pub struct Session {
    pub stop: CancellationToken,
    pub cancel: Cancellation,
    pub task: tokio::task::JoinHandle<()>,
}
/// User cancellation is destructive only until capture and transcription have
/// both finished. Serialize that transition with cancellation so a queued UI
/// command cannot discard a complete transcript when it meant to skip analysis.
#[derive(Clone)]
pub struct Cancellation {
    discard: CancellationToken,
    speakers: CancellationToken,
    transcript_complete: Arc<Mutex<bool>>,
}
impl Cancellation {
    pub fn new() -> Self {
        let discard = CancellationToken::new();
        Self {
            speakers: discard.child_token(),
            discard,
            transcript_complete: Arc::new(Mutex::new(false)),
        }
    }
    pub fn cancel(&self) {
        let complete = self.transcript_complete.lock().unwrap();
        if *complete {
            self.speakers.cancel();
        } else {
            self.discard.cancel();
        }
    }
    fn complete_transcript(&self, succeeded: bool) -> bool {
        let mut complete = self.transcript_complete.lock().unwrap();
        *complete = succeeded && !self.discard.is_cancelled();
        *complete
    }
    pub fn is_discarded(&self) -> bool {
        self.discard.is_cancelled()
    }
}
impl Default for Cancellation {
    fn default() -> Self {
        Self::new()
    }
}
pub fn start(
    app: AppHandle,
    workspace: Arc<Workspace>,
    worker: PathBuf,
    runtime: PathBuf,
    kind: String,
) -> Session {
    let stop = CancellationToken::new();
    let cancel = Cancellation::new();
    let stopping = stop.clone();
    let cancelled = cancel.clone();
    let task = tokio::spawn(async move {
        let shared = app.state::<Arc<Shared>>().inner().clone();
        let result = run(
            &app, &shared, &workspace, worker, runtime, &kind, &stopping, &cancelled,
        )
        .await;
        let id = shared.view.lock().unwrap().active_note.clone();
        if let (Err(error), Some(id)) = (&result, &id) {
            let store = workspace.store.lock().unwrap();
            if let Ok(mut n) = store.note(id) {
                n.interrupted = true;
                n.notice = Some(error.clone());
                let _ = store.put_note(&n);
            }
        }

        engine::update(&app, &shared, |s| {
            s.stage = "idle".into();
            s.active_note = None;
            s.model_ready = false;
            if let Err(e) = &result {
                s.error = Some(e.clone());
            }
        });
        let _ = workspace.refresh(&app);
        if !cancelled.is_discarded() && !shared.is_shutting_down() {
            let model = shared.view.lock().unwrap().settings["asrModel"]
                .as_str()
                .unwrap_or("parakeetUltra")
                .to_string();
            let _ = shared.send(engine::Command::Prepare(model));
        }
        // Skipping speaker separation does not opt out of configured AI notes.
        // Keep the normal write-up path and its durable retry state consistent.
        if result.is_ok() && !cancelled.is_discarded() && !shared.is_shutting_down() {
            let app = app.clone();
            let shared = shared.clone();
            let workspace = workspace.clone();
            tokio::spawn(async move {
                if shared.is_shutting_down() {
                    return;
                }
                if let Some(id) = id {
                    if let Err(e) = crate::workspace::write_up_recording(
                        &id,
                        &app,
                        &workspace,
                        &cancelled.discard,
                    )
                    .await
                    {
                        if !shared.is_shutting_down() && !cancelled.is_discarded() {
                            engine::update(&app, &shared, |s| {
                                s.error = Some(format!("Transcript saved. {e}"))
                            });
                        }
                    }
                }
            });
        }
    });
    Session { stop, cancel, task }
}
#[allow(clippy::too_many_arguments)]
async fn run(
    app: &AppHandle,
    shared: &Arc<Shared>,
    workspace: &Workspace,
    worker: PathBuf,
    runtime: PathBuf,
    kind: &str,
    stop: &CancellationToken,
    cancellation: &Cancellation,
) -> Result<(), String> {
    let cancel = &cancellation.discard;
    let settings = shared.view.lock().unwrap().settings.clone();
    let input_device = if let Some(name) = settings["inputDevice"]
        .as_str()
        .filter(|name| !name.is_empty())
    {
        Some(name.to_owned())
    } else if let Some(uid) = settings["inputDeviceUID"]
        .as_str()
        .filter(|uid| !uid.is_empty())
    {
        Some(crate::platform::input_device_name_for_uid(uid).ok_or(
            "Your saved microphone is unavailable. Choose another microphone in General settings.",
        )?)
    } else {
        None
    };
    let model_id = settings["meetingASRModel"]
        .as_str()
        .filter(|s| !s.is_empty())
        .unwrap_or("moss");
    let model = catalog::find(model_id).map_err(|e| e.to_string())?;
    let root = if cfg!(target_os = "macos") {
        std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or(workspace.data.clone())
            .join("Library/Application Support/Pressay/Models/ASR")
    } else {
        workspace.data.join("Models/ASR")
    };
    let path = download::prepare(&root, model, cancel, |p| {
        engine::update(app, shared, |s| s.progress = Some(p))
    })
    .await
    .map_err(|e| e.to_string())?;
    let analysis_executable = worker
        .parent()
        .ok_or("Speech worker has no parent directory")?
        .join(if cfg!(windows) {
            "pressay-analysis-worker.exe"
        } else {
            "pressay-analysis-worker"
        });
    let analysis_root = workspace.data.join("Models/Analysis");
    let vad_path = download::prepare(
        &analysis_root,
        analysis::find("sileroVAD").map_err(|e| e.to_string())?,
        cancel,
        |p| engine::update(app, shared, |s| s.progress = Some(p)),
    )
    .await
    .map_err(|e| e.to_string())?;
    let speaker_path = if kind == "meeting" {
        Some(
            download::prepare(
                &analysis_root,
                analysis::find("sortformer").map_err(|e| e.to_string())?,
                cancel,
                |p| engine::update(app, shared, |s| s.progress = Some(p)),
            )
            .await
            .map_err(|e| e.to_string())?,
        )
    } else {
        None
    };
    let mut analysis_host = AnalysisHost::new(analysis_executable.clone(), runtime.clone());
    analysis_host
        .prepare_vad(&vad_path, cancel)
        .await
        .map_err(|e| e.to_string())?;
    let analysis_runtime = runtime.clone();
    let mut host = WorkerHost::new(worker.clone(), runtime);
    host.set_language(settings["meetingLanguage"].as_str().unwrap_or("auto"));
    host.request(model_id, &path, None, cancel)
        .await
        .map_err(|e| e.to_string())?;
    if stop.is_cancelled() || cancel.is_cancelled() {
        host.stop().await;
        return Err("Recording cancelled before the microphone opened".into());
    }
    let mut note = Note::new(kind);
    note.interrupted = true;
    note.notice =
        Some("Recording did not finish. The transcript contains the last saved segments.".into());
    let id = note.id.clone();
    workspace
        .store
        .lock()
        .unwrap()
        .put_note(&note)
        .map_err(|e| e.to_string())?;
    engine::update(app, shared, |s| {
        s.active_note = Some(id.clone());
        s.progress = None;
        s.stage = "meeting_starting".into();
    });
    workspace.refresh(app)?;
    let config = meeting_capture::Config {
        input_device,
        max_duration: Duration::from_secs(
            (settings["maxMeetingHours"]
                .as_u64()
                .unwrap_or(3)
                .clamp(1, 8))
                * 3600,
        ),
        capture_system_audio: kind == "meeting",
        mac_helper: worker.parent().map(|p| p.join("PressayMeetingCapture")),
        ..Default::default()
    };
    let mut spool = if kind == "meeting" {
        Some(MeetingSpool::new(&workspace.data, config.max_duration).map_err(|e| e.to_string())?)
    } else {
        None
    };
    let max_duration = config.max_duration;
    let began = Instant::now();
    let (capture, receiver) =
        tokio::task::spawn_blocking(move || meeting_capture::Capture::start(config))
            .await
            .map_err(|e| e.to_string())??;
    // Drain native audio continuously. ASR gets utterances through a bounded
    // queue: a slow model cannot cause hours of PCM to accumulate in memory.
    let (segments_tx, mut segments_rx) =
        tokio::sync::mpsc::channel::<Result<(Track, Segment), String>>(24);
    let capture_cancel = cancel.child_token();
    let drain_cancel = capture_cancel.clone();
    let audio_app = app.clone();
    let audio_shared = shared.clone();
    let runtime_handle = tokio::runtime::Handle::current();
    let drain = tokio::task::spawn_blocking(move || {
        let mut tracks: [Option<VoiceTrack>; 2] = [None, None];
        let result = (|| -> Result<Option<MeetingSpool>, String> {
            while let Ok(event) = receiver.recv() {
                if drain_cancel.is_cancelled() {
                    break;
                }
                match event {
                    Event::Warning(w) => segments_tx
                        .try_send(Err(w))
                        .map_err(|_| "Speech processing could not keep up".to_string())?,
                    Event::Audio(chunk) => {
                        if audio_shared.view.lock().unwrap().stage == "meeting_starting" {
                            engine::update(&audio_app, &audio_shared, |s| {
                                s.stage = "meeting".into()
                            });
                        }
                        if chunk.track == Track::System {
                            if let Some(file) = &mut spool {
                                file.append(chunk.start, &chunk.samples)
                                    .map_err(|e| e.to_string())?;
                            }
                        }
                        let i = if chunk.track == Track::Microphone {
                            0
                        } else {
                            1
                        };
                        if tracks[i]
                            .as_ref()
                            .is_some_and(|t| (t.expected_end - chunk.start).abs() > 2. / 16000.)
                        {
                            let old = tracks[i].as_mut().unwrap();
                            let flushed = runtime_handle
                                .block_on(analysis_host.flush_vad(i as u8, &drain_cancel))
                                .map_err(|e| e.to_string())?;
                            let mut tails = old.apply(flushed)?;
                            if let Some(tail) = old.segmenter.finish() {
                                tails.push(tail);
                            }
                            for segment in tails {
                                segments_tx
                                    .try_send(Ok((chunk.track, segment)))
                                    .map_err(|_| {
                                        "Speech processing fell behind during an audio route change"
                                            .to_string()
                                    })?;
                            }
                            runtime_handle
                                .block_on(analysis_host.reset_vad(i as u8, &drain_cancel))
                                .map_err(|e| e.to_string())?;
                            tracks[i] = None;
                        }
                        let track = tracks[i].get_or_insert_with(|| VoiceTrack::new(chunk.start));
                        track.expected_end = chunk.start + chunk.samples.len() as f64 / 16000.;
                        track.pending.extend(&chunk.samples);
                        let decision = runtime_handle
                            .block_on(analysis_host.classify(
                                i as u8,
                                &chunk.samples,
                                &drain_cancel,
                            ))
                            .map_err(|e| e.to_string())?;
                        for segment in track.apply(decision)? {
                            segments_tx.try_send(Ok((chunk.track,segment))).map_err(|_|"Speech processing fell behind. Your transcript was saved; use a faster meeting model.".to_string())?;
                        }
                    }
                }
            }
            if !drain_cancel.is_cancelled() {
                for (i, track) in tracks.iter_mut().enumerate() {
                    if let Some(track) = track {
                        let decision = runtime_handle
                            .block_on(analysis_host.flush_vad(i as u8, &drain_cancel))
                            .map_err(|e| e.to_string())?;
                        let mut segments = track.apply(decision)?;
                        if let Some(last) = track.segmenter.finish() {
                            segments.push(last);
                        }
                        for segment in segments {
                            segments_tx
                                .blocking_send(Ok((
                                    if i == 0 {
                                        Track::Microphone
                                    } else {
                                        Track::System
                                    },
                                    segment,
                                )))
                                .map_err(|_| "Transcript reader closed".to_string())?;
                        }
                    }
                }
            }
            Ok(spool.take())
        })();
        runtime_handle.block_on(analysis_host.stop());
        result
    });
    // Closing a microphone cannot wait behind inference. This separate owner
    // observes Stop even while the ASR worker is processing a slow utterance.
    let capture_stop = stop.clone();
    let capture_abort = capture_cancel.clone();
    let capture_app = app.clone();
    let capture_shared = shared.clone();
    let capture_workspace = app.state::<Arc<Workspace>>().inner().clone();
    let capture_note = id.clone();
    let capture_task = tokio::spawn(async move {
        let mut poll = tokio::time::interval(Duration::from_millis(50));
        let mut warned = false;
        let cancelled = loop {
            tokio::select! {biased;
                _=capture_abort.cancelled()=>break true,
                _=capture_stop.cancelled()=>break false,
                _=poll.tick()=>{
                    if capture.is_finished(){break false;}
                    if !warned && duration_warning_due(began.elapsed(), max_duration) {
                        warned = true;
                        let result = {
                            let store = capture_workspace.store.lock().unwrap();
                            store.note(&capture_note).and_then(|mut note| {
                                note.notice = Some(DURATION_WARNING.into());
                                store.put_note(&note)
                            })
                        };
                        if let Err(error) = result {
                            engine::update(&capture_app, &capture_shared, |s| s.error = Some(error.to_string()));
                        }
                        let _ = capture_workspace.refresh(&capture_app);
                    }
                }
            }
        };
        let duration = began.elapsed().as_secs_f64();
        engine::update(&capture_app, &capture_shared, |s| {
            s.stage = "meeting_finishing".into();
            s.meeting_elapsed = duration;
        });
        let result = tokio::task::spawn_blocking(move || {
            if cancelled {
                capture.cancel();
                Ok(())
            } else {
                capture.finish()
            }
        })
        .await
        .map_err(|e| e.to_string())
        .and_then(|r| r);
        (duration, result)
    });
    let mut tick = tokio::time::interval(Duration::from_millis(500));
    let processing:Result<(),String>=async{
        loop {tokio::select!{biased;
            _=cancel.cancelled()=>break,
            _=tick.tick()=>{if !stop.is_cancelled()&&!capture_task.is_finished(){engine::update(app,shared,|s|s.meeting_elapsed=began.elapsed().as_secs_f64());}},
            event=segments_rx.recv()=>{let Some(event)=event else{break};match event{
                Err(w)=>{let store=workspace.store.lock().unwrap();let mut n=store.note(&id).map_err(|e|e.to_string())?;n.notice=Some(w);store.put_note(&n).map_err(|e|e.to_string())?;drop(store);workspace.refresh(app)?;}
                Ok((track,segment))=>{
                    let raw=host.transcribe(model_id,&path,&segment.samples,cancel).await.map_err(|e|e.to_string())?;
                    let entries=pressay_core::vocabulary::parse(settings["vocabulary"].as_str().unwrap_or(""));
                    let text=pressay_core::text::deterministic(&raw,&entries,None,settings["meetingLanguage"].as_str());
                    if !text.trim().is_empty(){let store=workspace.store.lock().unwrap();let mut latest=store.note(&id).map_err(|e|e.to_string())?;
                        latest.add_line(TranscriptLine{speaker:if track==Track::Microphone{Speaker::Me}else{Speaker::Others},start:segment.start,end:Some(segment.start+segment.samples.len()as f64/16000.),text,voice:None}).map_err(|e|e.to_string())?;
                        latest.duration=shared.view.lock().unwrap().meeting_elapsed;
                        store.put_note(&latest).map_err(|e|e.to_string())?;drop(store);workspace.refresh(app)?;
                    }
                }
            }}
        }}Ok(())
    }.await;
    let mut failure = processing.err();
    if failure.is_some() || cancel.is_cancelled() {
        capture_cancel.cancel();
    }
    // Closing the receiver unblocks a final tail send on error/cancel.
    drop(segments_rx);
    let duration = match capture_task.await {
        Ok((duration, result)) => {
            if let Err(e) = result {
                failure = Some(e);
            }
            duration
        }
        Err(e) => {
            failure = Some(e.to_string());
            began.elapsed().as_secs_f64()
        }
    };
    let spool = match drain.await {
        Ok(Ok(spool)) => spool,
        Ok(Err(e)) => {
            failure = Some(e);
            None
        }
        Err(e) => {
            failure = Some(e.to_string());
            None
        }
    };
    host.stop().await;
    let complete_transcript = cancellation.complete_transcript(failure.is_none());
    if complete_transcript && !cancellation.speakers.is_cancelled() && !shared.is_shutting_down() {
        if let (Some(mut spool), Some(path)) = (spool, speaker_path) {
            if spool.duration().as_secs() > 0 {
                engine::update(app, shared, |s| s.stage = "meeting_speakers".into());
                let result = async {
                    let pcm = spool.seal().map_err(|e| e.to_string())?;
                    let mut speaker_host = AnalysisHost::new(analysis_executable, analysis_runtime);
                    let speaker_cancel = cancellation.speakers.child_token();
                    tokio::select! {
                        result = speaker_host.diarize(&path, &pcm, &speaker_cancel) => result.map_err(|e| e.to_string()),
                        _ = async {
                            while !shared.is_shutting_down() {
                                tokio::time::sleep(Duration::from_millis(50)).await;
                            }
                        } => {
                            speaker_cancel.cancel();
                            speaker_host.stop().await;
                            Err("Speaker separation was skipped while quitting.".into())
                        }
                    }
                }
                .await;
                let store = workspace.store.lock().unwrap();
                let mut latest = store.note(&id).map_err(|e| e.to_string())?;
                match result {
                    _ if cancellation.speakers.is_cancelled() => {
                        latest.notice =
                            Some("Speaker separation skipped. Your transcript was saved.".into());
                    }
                    Ok(segments) => latest.assign_voices(&segments),
                    Err(e) => latest.notice = Some(format!("Transcript saved. {e}")),
                }
                store.put_note(&latest).map_err(|e| e.to_string())?;
            }
        }
    }
    let store = workspace.store.lock().unwrap();
    note = store.note(&id).map_err(|e| e.to_string())?;
    note.duration = duration;
    note.interrupted = !complete_transcript;
    if complete_transcript
        && note.notice.as_deref()
            == Some("Recording did not finish. The transcript contains the last saved segments.")
    {
        note.notice = None;
    }
    if note.notice.as_deref() == Some(DURATION_WARNING) {
        note.notice = (duration >= max_duration.as_secs_f64()).then(|| {
            "Recording stopped at the meeting duration limit. Your transcript was saved.".into()
        });
    }
    if failure.is_some() {
        note.notice = failure.clone();
    }
    if discard_finished_note(&note, complete_transcript, cancel.is_cancelled()) {
        store.delete_note(&id).map_err(|e| e.to_string())?;
        engine::update(app, shared, |s| s.active_note = None);
    } else {
        store.put_note(&note).map_err(|e| e.to_string())?;
    }
    if let Some(error) = failure {
        Err(error)
    } else {
        Ok(())
    }
}

const DURATION_WARNING: &str = "Recording will stop in two minutes at the meeting duration limit. Your transcript will be saved.";
fn duration_warning_due(elapsed: Duration, limit: Duration) -> bool {
    elapsed < limit && elapsed >= limit.saturating_sub(Duration::from_secs(120))
}
fn discard_finished_note(note: &Note, complete: bool, discarded: bool) -> bool {
    // Every session currently creates a new note. Explicit discard removes it;
    // a normal silent stop keeps personal notes, and errors preserve recovery.
    discarded || (complete && note.lines.is_empty() && note.my_notes.is_empty())
}

struct VoiceTrack {
    expected_end: f64,
    pending: VecDeque<f32>,
    next_frame: u64,
    segmenter: Segmenter,
    speech: bool,
}
impl VoiceTrack {
    fn new(origin: f64) -> Self {
        Self {
            expected_end: origin,
            pending: VecDeque::new(),
            next_frame: 0,
            segmenter: Segmenter::new(origin),
            speech: false,
        }
    }
    fn apply(&mut self, decision: VadResult) -> Result<Vec<Segment>, String> {
        if decision.first_frame != self.next_frame || decision.frame_samples != 512 {
            return Err("Voice detection lost its place in the audio stream".into());
        }
        let mut out = vec![];
        for p in decision.probabilities {
            self.next_frame += 1;
            self.speech = if self.speech { p >= 0.35 } else { p >= 0.5 };
            let count = self.pending.len().min(512);
            if count == 0 {
                return Err("Voice detection returned audio that was not captured".into());
            }
            let frame = self.pending.drain(..count).collect::<Vec<_>>();
            out.extend(self.segmenter.append_labeled(&frame, self.speech));
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn skipping_speaker_analysis_preserves_transcript_and_configured_writeup() {
        let cancellation = super::Cancellation::new();
        let speaker_job = cancellation.speakers.child_token();
        let writeup_job = cancellation.discard.child_token();
        let mut note = pressay_core::notes::Note::new("meeting");
        note.add_line(pressay_core::notes::TranscriptLine {
            speaker: pressay_core::notes::Speaker::Others,
            start: 0.,
            end: Some(3.),
            text: "Keep the complete meeting transcript.".into(),
            voice: None,
        })
        .unwrap();
        note.my_notes = "Also keep my notes".into();
        let complete = cancellation.complete_transcript(true);
        cancellation.cancel();
        assert!(complete);
        assert!(!cancellation.is_discarded());
        assert!(speaker_job.is_cancelled());
        assert!(!writeup_job.is_cancelled());
        assert!(
            note.needs_write_up,
            "Configured write-up remains eligible now and after restart"
        );
        assert!(!super::discard_finished_note(
            &note,
            complete,
            cancellation.is_discarded()
        ));
        assert_eq!(note.lines[0].text, "Keep the complete meeting transcript.");
        assert_eq!(note.my_notes, "Also keep my notes");
    }
    #[test]
    fn capture_cancel_remains_destructive_even_if_actor_receives_it_after_capture_ends() {
        let cancellation = super::Cancellation::new();
        cancellation.cancel();
        assert!(!cancellation.complete_transcript(true));
        assert!(cancellation.is_discarded());
        let note = pressay_core::notes::Note::new("meeting");
        assert!(super::discard_finished_note(
            &note,
            false,
            cancellation.is_discarded()
        ));
    }
    #[test]
    fn cancellation_and_completion_have_one_serialized_winner() {
        for _ in 0..100 {
            let cancellation = super::Cancellation::new();
            let complete = std::thread::scope(|scope| {
                let task = scope.spawn(|| cancellation.complete_transcript(true));
                cancellation.cancel();
                task.join().unwrap()
            });
            assert_eq!(complete, !cancellation.is_discarded());
            assert!(cancellation.speakers.is_cancelled());
        }
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn skipping_reaps_an_inflight_speaker_worker_without_discarding_capture() {
        let directory = tempfile::tempdir().unwrap();
        let worker = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../crates/pressay-core/tests/fixtures/analysis-worker.sh");
        std::fs::write(
            directory.path().join("response.sh"),
            "printf started > \"$3/started\"\nexec sleep 120\n",
        )
        .unwrap();
        let pid_path = directory.path().join("pid");
        let pcm_path = directory.path().join("public-silence.f32");
        std::fs::write(&pcm_path, [0_u8; 64000]).unwrap();
        let cancellation = super::Cancellation::new();
        assert!(cancellation.complete_transcript(true));
        let signal = cancellation.clone();
        let started = directory.path().join("started");
        let skip = tokio::spawn(async move {
            let observed = tokio::time::timeout(Duration::from_secs(3), async {
                while !started.exists() {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            })
            .await;
            // Always release a waiting worker, even if the fixture failed.
            signal.cancel();
            observed.unwrap();
        });
        let mut host = AnalysisHost::new(worker, directory.path().into());
        let result = tokio::time::timeout(
            Duration::from_secs(5),
            host.diarize(&pid_path, &pcm_path, &cancellation.speakers.child_token()),
        )
        .await
        .unwrap();
        skip.await.unwrap();
        assert!(matches!(result, Err(pressay_core::Error::Cancelled)));
        assert!(!cancellation.is_discarded());
        let pid = std::fs::read_to_string(pid_path).unwrap();
        assert!(!std::process::Command::new("kill")
            .args(["-0", pid.trim()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap()
            .success());
    }
    #[test]
    fn duration_warning_starts_exactly_two_minutes_before_limit() {
        let limit = std::time::Duration::from_secs(3600);
        assert!(!super::duration_warning_due(
            std::time::Duration::from_millis(3_479_999),
            limit
        ));
        assert!(super::duration_warning_due(
            std::time::Duration::from_secs(3480),
            limit
        ));
        assert!(super::duration_warning_due(
            std::time::Duration::from_secs(3599),
            limit
        ));
        assert!(!super::duration_warning_due(limit, limit));
    }
    #[test]
    fn silent_stop_retains_personal_notes_and_errors_but_explicit_discard_removes_new_note() {
        let mut note = pressay_core::notes::Note::new("meeting");
        assert!(super::discard_finished_note(&note, true, false));
        assert!(!super::discard_finished_note(&note, false, false));
        note.my_notes = "Keep this thought".into();
        assert!(!super::discard_finished_note(&note, true, false));
        assert!(super::discard_finished_note(&note, false, true));
        note.my_notes.clear();
        note.lines.push(pressay_core::notes::TranscriptLine {
            speaker: pressay_core::notes::Speaker::Me,
            start: 0.,
            end: Some(1.),
            text: "Hello".into(),
            voice: None,
        });
        assert!(!super::discard_finished_note(&note, true, false));
    }
    use super::*;
    fn decision(first: u64, probabilities: Vec<f32>) -> VadResult {
        VadResult {
            first_frame: first,
            frame_samples: 512,
            probabilities,
        }
    }
    #[test]
    fn final_vad_frame_uses_only_real_tail_samples() {
        let mut track = VoiceTrack::new(7.25);
        let samples: Vec<f32> = (0..6400).map(|i| i as f32 / 6400.).collect();
        track.pending.extend(&samples);
        assert!(track.apply(decision(0, vec![0.9; 12])).unwrap().is_empty());
        assert_eq!(track.pending.len(), 256);
        assert!(track.apply(decision(12, vec![0.9])).unwrap().is_empty());
        assert!(track.pending.is_empty());
        let tail = track.segmenter.finish().unwrap();
        assert_eq!(tail.start, 7.25);
        assert_eq!(tail.samples, samples); // no 256-frame model padding enters ASR
        assert!(track.segmenter.finish().is_none());
    }
    #[test]
    fn aligned_flush_does_not_duplicate_the_last_frame() {
        let mut track = VoiceTrack::new(1.5);
        track.pending.extend([0.25; 8192]);
        track.apply(decision(0, vec![0.8; 16])).unwrap();
        assert!(track.apply(decision(16, vec![])).unwrap().is_empty());
        assert_eq!(track.next_frame, 16);
        assert!(track.pending.is_empty());
        assert_eq!(track.segmenter.finish().unwrap().samples.len(), 8192);
    }
    #[test]
    fn discontinuity_flush_keeps_old_tail_and_new_timeline_origin() {
        let mut old = VoiceTrack::new(2.);
        old.pending.extend([0.1; 6500]);
        old.apply(decision(0, vec![0.8; 12])).unwrap();
        old.apply(decision(12, vec![0.8])).unwrap();
        let before_gap = old.segmenter.finish().unwrap();
        // The capture route change resets the VAD state and constructs a new
        // VoiceTrack. Its frame zero must use the new clock origin, not join
        // the two snippets across the missing interval.
        let mut resumed = VoiceTrack::new(9.75);
        resumed.pending.extend([0.2; 6656]);
        resumed.apply(decision(0, vec![0.8; 13])).unwrap();
        let after_gap = resumed.segmenter.finish().unwrap();
        assert_eq!(before_gap.start, 2.);
        assert_eq!(before_gap.samples.len(), 6500);
        assert_eq!(after_gap.start, 9.75);
        assert_eq!(after_gap.samples, vec![0.2; 6656]);
        assert!(after_gap.start > before_gap.start + before_gap.samples.len() as f64 / 16000.);
    }
    #[test]
    fn vad_hysteresis_and_frame_order_are_enforced() {
        let mut track = VoiceTrack::new(0.);
        track.pending.extend([0.1; 512 * 4]);
        track.apply(decision(0, vec![0.49])).unwrap();
        assert!(!track.speech);
        track.apply(decision(1, vec![0.50])).unwrap();
        assert!(track.speech);
        track.apply(decision(2, vec![0.35])).unwrap();
        assert!(track.speech);
        track.apply(decision(3, vec![0.349])).unwrap();
        assert!(!track.speech);
        let remaining = track.pending.len();
        assert!(track.apply(decision(2, vec![0.9])).is_err());
        assert_eq!(track.pending.len(), remaining);
        assert!(track
            .apply(VadResult {
                first_frame: 4,
                frame_samples: 480,
                probabilities: vec![]
            })
            .is_err());
        assert!(track.apply(decision(4, vec![0.9])).is_err());
    }
}
