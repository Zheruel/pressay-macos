//! Private, bounded WAV storage. Identifiers never become arbitrary file paths.
use crate::{Error, Result};
use std::{
    io::Write,
    path::{Path, PathBuf},
};
pub const MAX_WAV_BYTES: usize = 16_000 * 300 * 2 + 44;

pub struct AudioStore {
    root: PathBuf,
}
impl AudioStore {
    pub fn new(root: PathBuf) -> Result<Self> {
        std::fs::create_dir_all(&root)?;
        Ok(Self { root })
    }
    fn path(&self, id: &str) -> Result<PathBuf> {
        uuid::Uuid::parse_str(id)
            .map_err(|_| Error::Message("Invalid recording identifier".into()))?;
        Ok(self.root.join(format!("{id}.wav")))
    }
    pub fn save(&self, id: &str, samples: &[f32]) -> Result<()> {
        if samples.len() > 16_000 * 300 || samples.iter().any(|v| !v.is_finite()) {
            return Err(Error::Message("Invalid recording".into()));
        }
        let path = self.path(id)?;
        let mut temp = tempfile::NamedTempFile::new_in(&self.root)?;
        let bytes = wav(samples);
        temp.write_all(&bytes)?;
        temp.as_file().sync_all()?;
        temp.persist(path).map_err(|e| Error::Io(e.error))?;
        Ok(())
    }
    /// Accept only bounded 16 kHz mono PCM16, strip optional WAV metadata,
    /// and atomically create a private recording without replacing any file.
    pub fn import_wav(&self, id: &str, bytes: &[u8]) -> Result<bool> {
        let pcm = pcm16_data(bytes)?;
        let path = self.path(id)?;
        let mut temp = tempfile::NamedTempFile::new_in(&self.root)?;
        let mut canonical = wav(&[]);
        canonical[4..8].copy_from_slice(&((pcm.len() + 36) as u32).to_le_bytes());
        canonical[40..44].copy_from_slice(&(pcm.len() as u32).to_le_bytes());
        temp.write_all(&canonical)?;
        temp.write_all(pcm)?;
        temp.as_file().sync_all()?;
        match temp.persist_noclobber(path) {
            Ok(_) => Ok(true),
            Err(e) if e.error.kind() == std::io::ErrorKind::AlreadyExists => Ok(false),
            Err(e) => Err(Error::Io(e.error)),
        }
    }
    pub fn read(&self, id: &str) -> Result<Vec<u8>> {
        let path = self.path(id)?;
        let meta = std::fs::symlink_metadata(&path)?;
        if !meta.is_file() || meta.file_type().is_symlink() || meta.len() > 16_000 * 300 * 2 + 44 {
            return Err(Error::Message("Invalid recording file".into()));
        }
        Ok(std::fs::read(path)?)
    }
    pub fn remove(&self, id: &str) -> Result<()> {
        // Imported IDs need not be UUIDs and have no owned audio.
        let Ok(path) = self.path(id) else {
            return Ok(());
        };
        match std::fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }
    /// Failed/cancelled recognitions keep diagnostic WAVs for seven days.
    /// Visit only ordinary UUID-named files owned by this AudioStore; imported
    /// paths, links and every database-referenced recording remain untouched.
    pub(crate) fn prune_orphans(
        &self,
        referenced: &std::collections::HashSet<String>,
        at: f64,
    ) -> Result<usize> {
        if !at.is_finite() {
            return Err(Error::Message("Invalid retention timestamp".into()));
        }
        let mut removed = 0;
        for entry in std::fs::read_dir(&self.root)? {
            let entry = entry?;
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) != Some("wav") {
                continue;
            }
            let Some(id) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if uuid::Uuid::parse_str(id).is_err() || referenced.contains(id) {
                continue;
            }
            let metadata = match std::fs::symlink_metadata(&path) {
                Ok(metadata) => metadata,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error.into()),
            };
            if !metadata.is_file() || metadata.file_type().is_symlink() {
                continue;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::MetadataExt;
                if metadata.nlink() != 1 {
                    continue;
                }
            }
            let Ok(modified) = metadata.modified()?.duration_since(std::time::UNIX_EPOCH) else {
                continue;
            };
            if modified.as_secs_f64() >= at - 7. * 86400. {
                continue;
            }
            match std::fs::remove_file(path) {
                Ok(()) => removed += 1,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }
        Ok(removed)
    }
    pub fn root(&self) -> &Path {
        &self.root
    }
}
fn pcm16_data(bytes: &[u8]) -> Result<&[u8]> {
    let invalid = || Error::Message("Expected a bounded 16 kHz mono PCM16 WAV recording".into());
    if bytes.len() < 44
        || bytes.len() > MAX_WAV_BYTES + 65536
        || &bytes[..4] != b"RIFF"
        || &bytes[8..12] != b"WAVE"
    {
        return Err(invalid());
    }
    let declared = u32::from_le_bytes(bytes[4..8].try_into().unwrap()) as usize;
    if declared.checked_add(8) != Some(bytes.len()) {
        return Err(invalid());
    }
    let mut offset = 12;
    let mut format = false;
    let mut pcm = None;
    let mut chunks = 0;
    while offset < bytes.len() {
        chunks += 1;
        if chunks > 1024 || offset + 8 > bytes.len() {
            return Err(invalid());
        }
        let kind = &bytes[offset..offset + 4];
        let size = u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().unwrap()) as usize;
        let start = offset + 8;
        let end = start
            .checked_add(size)
            .filter(|end| *end <= bytes.len())
            .ok_or_else(invalid)?;
        match kind {
            b"fmt " => {
                if format || size < 16 {
                    return Err(invalid());
                }
                let f = &bytes[start..end];
                if u16::from_le_bytes(f[0..2].try_into().unwrap()) != 1
                    || u16::from_le_bytes(f[2..4].try_into().unwrap()) != 1
                    || u32::from_le_bytes(f[4..8].try_into().unwrap()) != 16000
                    || u32::from_le_bytes(f[8..12].try_into().unwrap()) != 32000
                    || u16::from_le_bytes(f[12..14].try_into().unwrap()) != 2
                    || u16::from_le_bytes(f[14..16].try_into().unwrap()) != 16
                {
                    return Err(invalid());
                }
                format = true;
            }
            b"data" => {
                if pcm.is_some()
                    || size == 0
                    || !size.is_multiple_of(2)
                    || size > MAX_WAV_BYTES - 44
                {
                    return Err(invalid());
                }
                pcm = Some(&bytes[start..end]);
            }
            _ => {}
        }
        offset = end
            .checked_add(size % 2)
            .filter(|end| *end <= bytes.len())
            .ok_or_else(invalid)?;
    }
    if !format {
        return Err(invalid());
    }
    pcm.ok_or_else(invalid)
}
pub fn wav(samples: &[f32]) -> Vec<u8> {
    let n = (samples.len() * 2) as u32;
    let mut data = Vec::with_capacity(n as usize + 44);
    data.extend(b"RIFF");
    data.extend((n + 36).to_le_bytes());
    data.extend(b"WAVEfmt ");
    data.extend(16u32.to_le_bytes());
    data.extend(1u16.to_le_bytes());
    data.extend(1u16.to_le_bytes());
    data.extend(16000u32.to_le_bytes());
    data.extend(32000u32.to_le_bytes());
    data.extend(2u16.to_le_bytes());
    data.extend(16u16.to_le_bytes());
    data.extend(b"data");
    data.extend(n.to_le_bytes());
    for sample in samples {
        data.extend(((sample.clamp(-1., 1.) * 32767.).round() as i16).to_le_bytes());
    }
    data
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retention_prunes_only_old_unreferenced_owned_recordings() {
        let dir = tempfile::tempdir().unwrap();
        let audio = AudioStore::new(dir.path().join("audio")).unwrap();
        let store = crate::storage::Store::open(&dir.path().join("db")).unwrap();
        let at = 2_000_000.;
        let old = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_000_000);
        let recent = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_999_999);
        let mut ids = Vec::new();
        for index in 0..4 {
            let id = uuid::Uuid::new_v4().to_string();
            audio.save(&id, &[0.]).unwrap();
            std::fs::File::open(audio.path(&id).unwrap())
                .unwrap()
                .set_times(std::fs::FileTimes::new().set_modified(if index == 1 {
                    recent
                } else {
                    old
                }))
                .unwrap();
            if index >= 2 {
                store
                    .add(&crate::storage::Dictation {
                        id: id.clone(),
                        created_at: 1.,
                        duration: 1.,
                        model: "fixture".into(),
                        raw: "hello".into(),
                        text: "hello".into(),
                        correction: (index == 3).then(|| "corrected".into()),
                        pinned: index == 2,
                        target: None,
                        latency: 0.,
                        legacy: serde_json::json!({"managedAudio":true}),
                    })
                    .unwrap();
            }
            ids.push(id);
        }
        let legacy = audio.root().join("legacy.wav");
        std::fs::write(&legacy, b"legacy").unwrap();
        std::fs::File::open(&legacy)
            .unwrap()
            .set_times(std::fs::FileTimes::new().set_modified(old))
            .unwrap();
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(
                &legacy,
                audio.root().join(format!("{}.wav", uuid::Uuid::new_v4())),
            )
            .unwrap();
            std::fs::hard_link(
                &legacy,
                audio.root().join(format!("{}.wav", uuid::Uuid::new_v4())),
            )
            .unwrap();
        }
        store.retain(at, &audio).unwrap();
        assert!(!audio.path(&ids[0]).unwrap().exists());
        for id in &ids[1..] {
            assert!(audio.read(id).is_ok());
        }
        assert_eq!(std::fs::read(legacy).unwrap(), b"legacy");
        #[cfg(unix)]
        assert_eq!(std::fs::read_dir(audio.root()).unwrap().count(), 6);
    }

    #[test]
    fn audio_is_bounded_and_cannot_escape_store() {
        let d = tempfile::tempdir().unwrap();
        let s = AudioStore::new(d.path().join("audio")).unwrap();
        assert!(s.read("../../secret").is_err());
        let id = uuid::Uuid::new_v4().to_string();
        s.save(&id, &[-1., 0., 1.]).unwrap();
        let bytes = s.read(&id).unwrap();
        assert_eq!(&bytes[..4], b"RIFF");
        assert_eq!(bytes.len(), 50);
        assert!(s.save(&id, &[f32::NAN]).is_err());
        s.remove(&id).unwrap();
        assert!(s.read(&id).is_err());
    }
    #[test]
    fn retention_preserves_corrections_pins_and_legacy_files() {
        use crate::storage::{Dictation, Store};
        let d = tempfile::tempdir().unwrap();
        let a = AudioStore::new(d.path().join("audio")).unwrap();
        let s = Store::open(&d.path().join("db")).unwrap();
        let legacy = d.path().join("legacy.wav");
        std::fs::write(&legacy, b"keep").unwrap();
        for (pinned, correction) in [
            (false, None),
            (true, None),
            (false, Some("fixed".to_owned())),
        ] {
            let id = uuid::Uuid::new_v4().to_string();
            a.save(&id, &[0.]).unwrap();
            s.add(&Dictation {
                id,
                created_at: 1.,
                duration: 1.,
                model: "test".into(),
                raw: "words".into(),
                text: "words".into(),
                correction,
                pinned,
                target: None,
                latency: 0.,
                legacy: serde_json::json!({"audioPath":legacy,"managedAudio":true}),
            })
            .unwrap();
        }
        s.retain(50. * 86400., &a).unwrap();
        assert_eq!(s.history(10).unwrap().len(), 2);
        assert_eq!(std::fs::read(legacy).unwrap(), b"keep");
        for r in s.history(10).unwrap() {
            assert!(a.read(&r.id).is_ok());
        }
    }
    #[test]
    fn wav_import_validates_format_strips_metadata_and_never_overwrites() {
        let d = tempfile::tempdir().unwrap();
        let audio = AudioStore::new(d.path().join("audio")).unwrap();
        let id = uuid::Uuid::new_v4().to_string();
        let original = wav(&[0., 0.5, -0.5]);
        let mut input = original[..12].to_vec();
        input.extend_from_slice(b"JUNK");
        input.extend_from_slice(&4u32.to_le_bytes());
        input.extend_from_slice(b"meta");
        input.extend_from_slice(&original[12..]);
        let size = input.len() - 8;
        input[4..8].copy_from_slice(&(size as u32).to_le_bytes());
        assert!(audio.import_wav(&id, &input).unwrap());
        assert_eq!(audio.read(&id).unwrap(), original);
        assert!(!audio.import_wav(&id, &wav(&[1.])).unwrap());
        assert_eq!(audio.read(&id).unwrap(), original);
        for change in ["rate", "channels", "length", "format"] {
            let mut bytes = original.clone();
            match change {
                "rate" => bytes[24..28].copy_from_slice(&48000u32.to_le_bytes()),
                "channels" => bytes[22..24].copy_from_slice(&2u16.to_le_bytes()),
                "length" => bytes[40..44].copy_from_slice(&u32::MAX.to_le_bytes()),
                _ => bytes[20..22].copy_from_slice(&3u16.to_le_bytes()),
            };
            assert!(audio
                .import_wav(&uuid::Uuid::new_v4().to_string(), &bytes)
                .is_err());
        }
        assert!(audio.import_wav("../outside", &original).is_err());
    }
}
