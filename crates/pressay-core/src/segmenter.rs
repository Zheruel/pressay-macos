//! Bounded utterance segmentation, preserving the shipping app's timing policy.
use std::collections::VecDeque;
#[derive(Debug)]
pub struct Segment {
    pub start: f64,
    pub samples: Vec<f32>,
}
pub struct Segmenter {
    pending: VecDeque<f32>,
    current: Vec<f32>,
    lead: VecDeque<f32>,
    consumed: usize,
    start: usize,
    speech: usize,
    silent: usize,
    noise: f32,
    origin: f64,
}
impl Segmenter {
    pub fn new(origin: f64) -> Self {
        Self {
            pending: VecDeque::new(),
            current: vec![],
            lead: VecDeque::new(),
            consumed: 0,
            start: 0,
            speech: 0,
            silent: 0,
            noise: 0.002,
            origin,
        }
    }
    pub fn append(&mut self, samples: &[f32], speech: Option<bool>) -> Vec<Segment> {
        let mut result = vec![];
        // Callers supply one-second chunks; process directly so a maliciously
        // large batch cannot accumulate an unbounded pending copy.
        for sample in samples {
            self.pending.push_back(*sample);
            if self.pending.len() < 480 {
                continue;
            }
            let frame: Vec<_> = self.pending.drain(..480).collect();
            if let Some(segment) = self.process(&frame, speech) {
                result.push(segment);
            }
        }
        result
    }
    /// Feed one model-labelled frame without rounding 512-sample VAD decisions
    /// onto the adaptive 480-sample grid. Timing counters are always samples.
    pub fn append_labeled(&mut self, samples: &[f32], speech: bool) -> Vec<Segment> {
        let mut out = vec![];
        for frame in samples.chunks(512) {
            if let Some(segment) = self.process(frame, Some(speech)) {
                out.push(segment);
            }
        }
        out
    }
    fn process(&mut self, frame: &[f32], speech: Option<bool>) -> Option<Segment> {
        if frame.is_empty() {
            return None;
        }
        let rms = (frame.iter().map(|v| v * v).sum::<f32>() / frame.len() as f32).sqrt();
        let talking = speech.unwrap_or(rms > (self.noise * 3.).max(0.006));
        if !talking {
            self.noise = if rms < self.noise {
                rms * 0.5 + self.noise * 0.5
            } else {
                self.noise * 0.995 + rms * 0.005
            };
        }
        if self.current.is_empty() && !talking {
            self.consumed += frame.len();
            self.lead.extend(frame);
            while self.lead.len() > 4800 {
                self.lead.pop_front();
            }
            return None;
        }
        if self.current.is_empty() {
            self.start = self.consumed - self.lead.len();
            self.current.extend(self.lead.drain(..));
        }
        self.current.extend(frame);
        self.consumed += frame.len();
        if talking {
            self.speech += frame.len();
            self.silent = 0;
        } else {
            self.silent += frame.len();
        }
        if self.silent >= 11200 || self.current.len() >= 192000 {
            self.cut()
        } else {
            None
        }
    }
    pub fn finish(&mut self) -> Option<Segment> {
        self.current.extend(self.pending.drain(..));
        self.cut()
    }
    fn cut(&mut self) -> Option<Segment> {
        let mut samples = std::mem::take(&mut self.current);
        let enough = self.speech >= 6400;
        let trim = self.silent.saturating_sub(2400);
        samples.truncate(samples.len().saturating_sub(trim));
        self.speech = 0;
        self.silent = 0;
        enough.then_some(Segment {
            start: self.origin + self.start as f64 / 16000.,
            samples,
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn silence_is_bounded_and_never_transcribed() {
        let mut s = Segmenter::new(0.);
        for _ in 0..1000 {
            assert!(s.append(&[0.; 16000], None).is_empty());
        }
        assert!(s.finish().is_none());
        assert!(s.lead.len() <= 4800);
    }
    #[test]
    fn starts_keep_lead_and_tails_are_trimmed() {
        let mut s = Segmenter::new(5.);
        s.append(&[0.; 16000], Some(false));
        s.append(&[0.1; 16000], Some(true));
        let segments = s.append(&[0.; 16000], Some(false));
        assert_eq!(segments.len(), 1);
        assert!((segments[0].start - 5.69).abs() < 0.04);
        assert!(segments[0].samples.len() < 25000);
    }
    #[test]
    fn continuous_speech_is_cut_without_loss() {
        let mut s = Segmenter::new(0.);
        let mut n = 0;
        for _ in 0..61 {
            for segment in s.append(&[0.1; 16000], Some(true)) {
                assert!(segment.samples.len() <= 320480);
                n += segment.samples.len();
            }
        }
        n += s.finish().unwrap().samples.len();
        assert_eq!(n, 61 * 16000);
    }
    #[test]
    fn labelled_frames_preserve_exact_lead_tail_and_next_origin() {
        let mut s = Segmenter::new(10.);
        assert!(s.append_labeled(&[0.; 5120], false).is_empty());
        assert!(s.append_labeled(&[0.25; 6656], true).is_empty());
        let completed = s.append_labeled(&[0.; 11264], false);
        assert_eq!(completed.len(), 1);
        assert!((completed[0].start - 10.02).abs() < 1e-12);
        assert_eq!(completed[0].samples.len(), 4800 + 6656 + 2400);
        assert!(completed[0].samples[..4800].iter().all(|v| *v == 0.));
        assert!(completed[0].samples[4800..11456].iter().all(|v| *v == 0.25));
        s.append_labeled(&[0.5; 6656], true);
        let next = s.finish().unwrap();
        assert!((next.start - (10. + 23040. / 16000.)).abs() < 1e-12);
        assert_eq!(next.samples, vec![0.5; 6656]);
    }
    #[test]
    fn minimum_speech_uses_real_samples_in_a_partial_vad_tail() {
        let mut short = Segmenter::new(0.);
        short.append_labeled(&[0.1; 6399], true);
        assert!(short.finish().is_none());
        let mut enough = Segmenter::new(0.);
        enough.append_labeled(&[0.1; 6400], true);
        assert_eq!(enough.finish().unwrap().samples.len(), 6400);
    }
    #[test]
    fn meeting_maximum_is_twelve_seconds_without_gaps_or_duplicate_samples() {
        let source: Vec<f32> = (0..(37 * 16000 + 321))
            .map(|i| i as f32 / 1_000_000.)
            .collect();
        let mut s = Segmenter::new(3.);
        let mut segments = vec![];
        for block in source.chunks(512) {
            segments.extend(s.append_labeled(block, true));
        }
        segments.extend(s.finish());
        let mut consumed = 0;
        for segment in segments {
            assert!(
                segment.samples.len() <= 12 * 16000 + 511,
                "meeting utterance exceeds shipping twelve-second limit"
            );
            assert!((segment.start - (3. + consumed as f64 / 16000.)).abs() < 1e-12);
            assert_eq!(
                segment.samples,
                source[consumed..consumed + segment.samples.len()]
            );
            consumed += segment.samples.len();
        }
        assert_eq!(consumed, source.len());
    }
}
