# Pressay earcons

All cues are synthesized by `scripts/generate-earcons.py` (no third-party audio):

| File | Sound | Length |
| --- | --- | ---: |
| `dictation-begin.wav` | Two soft mallet notes rising a fourth (E5 → A5): "open" | 170 ms |
| `dictation-release.wav` | The mirror, falling A5 → E5 and softer: "closed" | 160 ms |
| `dictation-cancel.wav` | One muted low tap | 90 ms |
| `dictation-error.wav` | Two muted notes falling a minor third | 200 ms |

Each note is a struck tuned bar: marimba-ratio partials with faster-decaying
upper modes, a ~3 ms felt-mallet attack, a 2 ms noise tick for tactility, and
three low-passed early reflections for a small-room tail. Peaks sit between
-25 and -29 dBFS (RMS matched to the previous cues) for comfortable frequent
use, with a click-safe fade to digital silence.

Lengths must match `DictationSoundPlayer.Cue.duration`; the begin length also
sizes the window trimmed from captured audio. Regenerate with
`python3 scripts/generate-earcons.py`.
