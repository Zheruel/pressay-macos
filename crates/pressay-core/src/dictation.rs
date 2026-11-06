//! Dictation onset trimming and streaming pause cuts, shared by every host.
//!
//! The planner keeps counters only. The host retains the original PCM until
//! every piece succeeds, so a failed detector or transcription can fall back
//! to the full clip without gaps or duplicate words.
use std::ops::Range;

use crate::{analysis::VadResult, Error, Result};

pub const SAMPLE_RATE: usize = 16_000;
pub const VAD_FRAME_SAMPLES: usize = 512;
pub const MINIMUM_PIECE_SAMPLES: usize = 8 * SAMPLE_RATE;
pub const PAUSE_FRAMES: usize = (SAMPLE_RATE / 2).div_ceil(VAD_FRAME_SAMPLES);
pub const MAX_TRIM_SAMPLES: usize = 300 * SAMPLE_RATE;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Piece {
    /// Absolute offsets into the original 16 kHz capture, without overlap.
    pub range: Range<usize>,
    /// Silent pieces still advance the timeline, but need no ASR call.
    pub has_speech: bool,
    /// Apply onset trimming only to this piece, and to the final tail.
    pub first: bool,
}

#[derive(Debug)]
pub struct CutPlanner {
    maximum: usize,
    received: usize,
    judged: usize,
    last_cut: usize,
    cuts: usize,
    silent_frames: usize,
    talking: bool,
    piece_has_speech: bool,
    broken: bool,
}

impl CutPlanner {
    pub fn new(max_samples: usize) -> Self {
        Self {
            maximum: max_samples,
            received: 0,
            judged: 0,
            last_cut: 0,
            cuts: 0,
            silent_frames: 0,
            talking: false,
            piece_has_speech: false,
            broken: false,
        }
    }

    /// Register each newly received PCM batch exactly once, before its VAD
    /// result. Empty batches are harmless. No PCM is retained or allocated.
    pub fn push_audio(&mut self, samples: &[f32]) -> Result<()> {
        let end = self.received.checked_add(samples.len());
        if self.broken
            || end.is_none_or(|end| end > self.maximum)
            || samples.iter().any(|sample| !sample.is_finite())
        {
            return self.fail("Invalid or oversized streaming dictation audio");
        }
        self.received = end.expect("validated sample count");
        Ok(())
    }

    /// Consume contiguous full 512-sample Silero decisions. A final partial
    /// frame remains in the tail; do not feed a padded final-frame decision.
    /// Invalid, repeated, missing or out-of-order decisions force fallback.
    pub fn observe(&mut self, result: &VadResult) -> Result<Vec<Piece>> {
        let end = result
            .probabilities
            .len()
            .checked_mul(VAD_FRAME_SAMPLES)
            .and_then(|count| self.judged.checked_add(count));
        if self.broken
            || result.frame_samples != VAD_FRAME_SAMPLES
            || result.first_frame != (self.judged / VAD_FRAME_SAMPLES) as u64
            || end.is_none_or(|end| end > self.received)
            || result
                .probabilities
                .iter()
                .any(|probability| !probability.is_finite() || !(0.0..=1.0).contains(probability))
        {
            return self.fail("Invalid or discontinuous dictation voice activity");
        }
        let mut pieces = Vec::new();
        for probability in &result.probabilities {
            self.talking = *probability >= if self.talking { 0.35 } else { 0.5 };
            self.judged += VAD_FRAME_SAMPLES;
            self.silent_frames = if self.talking {
                0
            } else {
                self.silent_frames + 1
            };
            self.piece_has_speech |= self.talking;
            // Match DictationStreamer: the open piece must reach eight seconds
            // at judgement time. The resulting cut is halfway into its pause.
            if self.silent_frames >= PAUSE_FRAMES
                && self.judged - self.last_cut >= MINIMUM_PIECE_SAMPLES
            {
                let cut = self.judged - self.silent_frames * VAD_FRAME_SAMPLES / 2;
                pieces.push(Piece {
                    range: self.last_cut..cut,
                    has_speech: self.piece_has_speech,
                    first: self.cuts == 0,
                });
                self.last_cut = cut;
                self.cuts += 1;
                self.silent_frames = 0;
                self.piece_has_speech = false;
            }
        }
        Ok(pieces)
    }

    pub fn received_samples(&self) -> usize {
        self.received
    }
    pub fn judged_samples(&self) -> usize {
        self.judged
    }
    pub fn last_cut(&self) -> usize {
        self.last_cut
    }
    /// Invalidate on an ASR failure or any capture discontinuity. The host
    /// discards accumulated text and transcribes its retained original PCM.
    pub fn invalidate(&mut self) {
        self.broken = true;
    }
    /// A contiguous final tail, or None when the host must use the full clip.
    /// An empty joined transcript must also trigger full-clip fallback.
    pub fn finish(&self, total_samples: usize) -> Option<Range<usize>> {
        (!self.broken && self.cuts > 0 && total_samples == self.received)
            .then_some(self.last_cut..total_samples)
    }
    fn fail<T>(&mut self, message: &str) -> Result<T> {
        self.invalidate();
        Err(Error::Message(message.into()))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum TrimError {
    #[error("Recording is too short")]
    RecordingTooShort,
    #[error("No speech detected")]
    Silence,
    #[error("Invalid or oversized dictation audio")]
    InvalidAudio,
}

/// Match AudioTrimmer's 20 ms RMS frames, 0.003 threshold, 250 ms padding,
/// 250 ms minimum input, and 1.2 s minimum output at 16 kHz. The optional cue
/// guard excludes overlapping frames from speech detection, but never clips
/// away available pre-roll: speech may have started during the cue.
pub fn trim(
    samples: &[f32],
    earcon_guard: Option<Range<usize>>,
) -> std::result::Result<Vec<f32>, TrimError> {
    if samples.len() > MAX_TRIM_SAMPLES || samples.iter().any(|sample| !sample.is_finite()) {
        return Err(TrimError::InvalidAudio);
    }
    if samples.len() < SAMPLE_RATE / 4 {
        return Err(TrimError::RecordingTooShort);
    }
    let guard = earcon_guard.map(|range| {
        let lower = range.start.min(samples.len());
        lower..range.end.max(lower).min(samples.len())
    });
    let frame_size = SAMPLE_RATE / 50;
    let padding = SAMPLE_RATE / 4;
    let minimum = SAMPLE_RATE * 1200 / 1000;
    let mut first_speech = None;
    let mut last_speech = 0;
    for (index, frame) in samples.chunks(frame_size).enumerate() {
        let start = index * frame_size;
        let end = start + frame.len();
        if guard
            .as_ref()
            .is_some_and(|range| start < range.end && end > range.start)
        {
            continue;
        }
        // Wider accumulation avoids overflow from otherwise finite PCM.
        let rms = (frame
            .iter()
            .map(|sample| f64::from(*sample).powi(2))
            .sum::<f64>()
            / frame.len() as f64)
            .sqrt();
        if rms >= f64::from(0.003_f32) {
            first_speech.get_or_insert(start);
            last_speech = end;
        }
    }
    let first_speech = first_speech.ok_or(TrimError::Silence)?;
    let mut start = first_speech.saturating_sub(padding);
    let mut end = (last_speech + padding).min(samples.len());
    if end - start < minimum {
        let missing = minimum - (end - start);
        let grow_before = start.min(missing / 2);
        start -= grow_before;
        end = (end + missing - grow_before).min(samples.len());
        start = start.saturating_sub(minimum.saturating_sub(end - start));
    }
    let lead_in = first_speech - start;
    // At the five-minute capture limit, synthetic context must not make the
    // result too large for owned WAV storage. Keep every real sample first.
    let artificial_lead = padding
        .saturating_sub(lead_in)
        .min(MAX_TRIM_SAMPLES - (end - start));
    let natural_length = artificial_lead + end - start;
    let missing = minimum.saturating_sub(natural_length);
    let mut output = Vec::with_capacity(natural_length + missing);
    output.resize(artificial_lead + missing / 2, 0.0);
    output.extend_from_slice(&samples[start..end]);
    output.resize(natural_length + missing, 0.0);
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn five_minute_onset_preserves_all_real_audio_and_remains_storable() {
        let samples = vec![0.125; MAX_TRIM_SAMPLES];
        let trimmed = trim(&samples, None).unwrap();
        assert_eq!(trimmed, samples);
        let directory = tempfile::tempdir().unwrap();
        let audio = crate::recordings::AudioStore::new(directory.path().into()).unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        audio.save(&id, &trimmed).unwrap();
        assert_eq!(
            audio.read(&id).unwrap().len(),
            crate::recordings::MAX_WAV_BYTES
        );

        let near_limit = &samples[..MAX_TRIM_SAMPLES - 1000];
        let trimmed = trim(near_limit, None).unwrap();
        assert_eq!(trimmed.len(), MAX_TRIM_SAMPLES);
        assert!(trimmed[..1000].iter().all(|sample| *sample == 0.));
        assert_eq!(&trimmed[1000..], near_limit);
    }
    fn decisions(first_frame: u64, probabilities: Vec<f32>) -> VadResult {
        VadResult {
            first_frame,
            frame_samples: 512,
            probabilities,
        }
    }
    fn planner(frames: usize) -> CutPlanner {
        let mut planner = CutPlanner::new(MAX_TRIM_SAMPLES);
        planner.push_audio(&vec![0.; frames * 512]).unwrap();
        planner
    }

    #[test]
    fn waits_for_eight_seconds_and_a_full_half_second_pause() {
        let mut planner = planner(270);
        assert!(planner
            .observe(&decisions(0, vec![1.; 250]))
            .unwrap()
            .is_empty());
        assert!(planner
            .observe(&decisions(250, vec![0.; 15]))
            .unwrap()
            .is_empty());
        let pieces = planner.observe(&decisions(265, vec![0.])).unwrap();
        assert_eq!(
            pieces,
            vec![Piece {
                range: 0..258 * 512,
                has_speech: true,
                first: true
            }]
        );
        assert_eq!(planner.finish(270 * 512), Some(258 * 512..270 * 512));
    }

    #[test]
    fn judgement_threshold_matches_swift_even_when_midpoint_precedes_eight_seconds() {
        let mut planner = planner(250);
        planner.observe(&decisions(0, vec![1.; 234])).unwrap();
        assert!(planner
            .observe(&decisions(234, vec![0.; 15]))
            .unwrap()
            .is_empty());
        let pieces = planner.observe(&decisions(249, vec![0.])).unwrap();
        assert_eq!(pieces[0].range, 0..242 * 512);
    }

    #[test]
    fn cuts_and_partial_tail_cover_exactly_the_original_audio() {
        let probabilities = [vec![1.; 260], vec![0.; 20], vec![1.; 260], vec![0.; 20]].concat();
        let mut planner = CutPlanner::new(MAX_TRIM_SAMPLES);
        let source: Vec<_> = (0..probabilities.len() * 512 + 317)
            .map(|i| i as f32)
            .collect();
        let mut ranges = vec![];
        for (i, batch) in probabilities.chunks(7).enumerate() {
            let offset = i * 7 * 512;
            planner
                .push_audio(&source[offset..offset + batch.len() * 512])
                .unwrap();
            ranges.extend(
                planner
                    .observe(&decisions((i * 7) as u64, batch.to_vec()))
                    .unwrap()
                    .into_iter()
                    .map(|piece| piece.range),
            );
        }
        planner
            .push_audio(&source[probabilities.len() * 512..])
            .unwrap();
        assert_eq!(ranges.len(), 2);
        ranges.push(planner.finish(source.len()).unwrap());
        let reconstructed: Vec<_> = ranges
            .into_iter()
            .flat_map(|range| source[range].to_vec())
            .collect();
        assert_eq!(reconstructed, source);
    }

    #[test]
    fn hysteresis_retains_quiet_speech_and_resets_after_pause() {
        let mut planner = planner(282);
        planner.observe(&decisions(0, vec![0.5])).unwrap();
        assert!(planner
            .observe(&decisions(1, vec![0.35; 265]))
            .unwrap()
            .is_empty());
        let cuts = planner.observe(&decisions(266, vec![0.349; 16])).unwrap();
        assert!(cuts[0].has_speech);
        assert!(!planner.talking);
    }

    #[test]
    fn continuous_speech_and_short_clips_use_whole_clip_fallback() {
        let mut planner = planner(1000);
        assert!(planner
            .observe(&decisions(0, vec![1.; 1000]))
            .unwrap()
            .is_empty());
        assert_eq!(planner.finish(512000), None);
    }

    #[test]
    fn silence_cuts_are_contiguous_but_need_no_transcription() {
        let mut planner = planner(1000);
        let pieces = planner.observe(&decisions(0, vec![0.; 1000])).unwrap();
        let mut last = 0;
        for (i, piece) in pieces.iter().enumerate() {
            assert_eq!(piece.range.start, last);
            assert!(piece.range.end > last);
            assert!(!piece.has_speech);
            assert_eq!(piece.first, i == 0);
            last = piece.range.end;
        }
        assert_eq!(last, planner.last_cut());
        assert_eq!(planner.finish(512000), Some(last..512000));
    }

    #[test]
    fn invalid_or_missing_frames_invalidate_all_previous_cuts() {
        for result in [
            decisions(251, vec![0.]),
            decisions(250, vec![f32::NAN]),
            decisions(250, vec![1.1]),
            decisions(250, vec![-0.1]),
            VadResult {
                first_frame: 250,
                frame_samples: 480,
                probabilities: vec![0.],
            },
        ] {
            let mut planner = planner(251);
            assert!(!planner
                .observe(&decisions(0, vec![0.; 250]))
                .unwrap()
                .is_empty());
            assert!(planner.observe(&result).is_err());
            assert_eq!(planner.finish(251 * 512), None);
            assert!(planner.push_audio(&[]).is_err());
        }
        let mut planner = planner(250);
        assert!(planner.observe(&decisions(0, vec![0.; 251])).is_err());
        assert_eq!(planner.judged_samples(), 0);
    }

    #[test]
    fn capture_limits_mismatches_and_asr_failure_force_fallback() {
        let mut planner = planner(250);
        planner.observe(&decisions(0, vec![0.; 250])).unwrap();
        assert!(planner.finish(250 * 512 + 1).is_none());
        planner.invalidate();
        assert!(planner.finish(250 * 512).is_none());
        let mut small = CutPlanner::new(2);
        small.push_audio(&[0., 1.]).unwrap();
        assert!(small.push_audio(&[0.]).is_err());
        assert_eq!(small.received_samples(), 2);
        assert!(CutPlanner::new(10).push_audio(&[f32::INFINITY]).is_err());
    }

    #[test]
    fn trim_rejects_short_silent_invalid_and_oversized_audio() {
        assert_eq!(
            trim(&vec![0.1; 3999], None),
            Err(TrimError::RecordingTooShort)
        );
        assert_eq!(trim(&vec![0.; 4000], None), Err(TrimError::Silence));
        assert_eq!(trim(&vec![0.0029; 4000], None), Err(TrimError::Silence));
        assert_eq!(trim(&[f32::NAN], None), Err(TrimError::InvalidAudio));
        assert_eq!(
            trim(&vec![0.; MAX_TRIM_SAMPLES + 1], None),
            Err(TrimError::InvalidAudio)
        );
    }

    #[test]
    fn trim_preserves_real_context_before_adding_silence() {
        let mut samples = vec![0.; 32000];
        samples[16000..16320].fill(0.1);
        let result = trim(&samples, None).unwrap();
        assert_eq!(result.len(), 19200);
        assert_eq!(result, samples[6560..25760]);
    }

    #[test]
    fn onset_at_frame_zero_gets_full_lead_in_and_one_word_context() {
        let samples = vec![0.1; 4000];
        let result = trim(&samples, None).unwrap();
        assert_eq!(result.len(), 19200);
        assert_eq!(&result[9600..13600], samples);
        assert!(result[..9600]
            .iter()
            .chain(&result[13600..])
            .all(|v| *v == 0.));
        let result = trim(&vec![0.1; 20000], None).unwrap();
        assert_eq!(result.len(), 24000);
        assert!(result[..4000].iter().all(|v| *v == 0.));
    }

    #[test]
    fn guard_excludes_cue_but_retains_speech_overlapping_cue_and_preroll() {
        let mut samples = vec![0.; 32000];
        samples[1000..2000].fill(0.8);
        assert_eq!(trim(&samples, Some(900..2100)), Err(TrimError::Silence));
        samples[1900..2560].fill(0.1);
        let result = trim(&samples, Some(900..2100)).unwrap();
        // The first visible speech is at2240. Padding must retain the real
        // speech which started at1900, inside the cue guard.
        assert_eq!(&result[1760..1760 + 19200], &samples[..19200]);
        samples[..320].fill(0.2);
        let result = trim(&samples, Some(900..2100)).unwrap();
        assert_eq!(&result[4000..4320], &samples[..320]);
    }

    #[test]
    fn guards_past_capture_and_partial_final_frames_are_safe() {
        let mut samples = vec![0.; 4001];
        samples[4000] = 0.1;
        let expected = trim(&samples, None).unwrap();
        assert_eq!(trim(&samples, Some(10000..20000)).unwrap(), expected);
        assert_eq!(trim(&samples, Some(4001..4001)).unwrap(), expected);
        assert!(expected.contains(&0.1));
    }
}
