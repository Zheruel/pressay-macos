use crate::{Error, Result};
pub const SAMPLE_RATE: usize = 16_000;
pub const MAX_CHUNK_SAMPLES: usize = 25 * SAMPLE_RATE;
/// Match the shipping host: Qwen benefits from 60 s context; other models use 25 s.
pub fn chunk_samples(model: &str) -> usize {
    if model == "whisperTurboGGML" {
        300 * SAMPLE_RATE
    } else if ["qwen3ASR17", "qwen3ASR06", "funASRMLTNano", "voxtralMini"].contains(&model) {
        60 * SAMPLE_RATE
    } else {
        MAX_CHUNK_SAMPLES
    }
}

pub fn validate_for_model(samples: &[f32], model: &str) -> Result<()> {
    if model == "whisperTurboGGML"
        && !samples.is_empty()
        && samples.len() <= 300 * SAMPLE_RATE
        && samples.iter().all(|v| v.is_finite())
    {
        Ok(())
    } else {
        validate(samples)
    }
}
pub fn validate(samples: &[f32]) -> Result<()> {
    if samples.is_empty()
        || samples.len() > 60 * SAMPLE_RATE
        || samples.iter().any(|v| !v.is_finite())
    {
        return Err(Error::Message("Invalid audio length or samples".into()));
    }
    Ok(())
}

/// Same 200 ms quiet-frame search as the Swift host, within 3 s of the midpoint.
/// No overlap: a word must never be duplicated when adjacent results are joined.
pub fn split_point(samples: &[f32]) -> usize {
    let midpoint = samples.len() / 2;
    let frame = SAMPLE_RATE / 5;
    if samples.len() < frame * 2 {
        return midpoint;
    }
    let lower = midpoint.saturating_sub(3 * SAMPLE_RATE).max(frame / 2);
    let upper = (midpoint + 3 * SAMPLE_RATE).min(samples.len() - frame - frame / 2);
    let energy = |s: &[f32]| s.iter().map(|x| f64::from(*x).powi(2)).sum::<f64>() / s.len() as f64;
    let overall = energy(samples);
    let mut best = (f64::INFINITY, midpoint);
    for i in (lower..=upper).step_by(frame / 4) {
        let e = energy(&samples[i..i + frame]);
        if e < best.0 {
            best = (e, i + frame / 2);
        }
    }
    if overall > 0. && best.0 < overall * 0.1 {
        best.1
    } else {
        midpoint
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn finds_pauses_without_dropping_samples() {
        let mut samples = vec![0.2; 16_000 * 30];
        samples[16_000 * 14..16_000 * 15].fill(0.);
        let cut = split_point(&samples);
        assert!((16_000 * 14..16_000 * 15).contains(&cut));
        assert_eq!([&samples[..cut], &samples[cut..]].concat(), samples);
    }
    #[test]
    fn validates_pcm() {
        assert!(validate(&[]).is_err());
        assert!(validate(&[f32::NAN]).is_err());
        assert!(validate(&vec![0.; 60 * SAMPLE_RATE + 1]).is_err());
        assert!(validate(&[0.]).is_ok());
    }
}
