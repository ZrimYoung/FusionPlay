//! Synchronization preference for the Apple audio output path.
use super::*;

// Keep the existing path on macOS so upgrades preserve the adjustment.
#[cfg(target_os = "macos")]
const SETTINGS_FILENAME: &str = "macos-sync.json";
#[cfg(target_os = "ios")]
const SETTINGS_FILENAME: &str = "ios-sync.json";

#[derive(Default, Serialize, Deserialize)]
struct SyncSettings {
    #[serde(default)]
    adjustment_ms: i32,
}
fn validate(value: i32) -> Result<i32> {
    if !(-200..=200).contains(&value) {
        return Err(HostError::InvalidConfig {
            message: "Sync adjustment must be -200 to 200 ms".into(),
        });
    }
    Ok(value)
}
fn load(data: &Path) -> Result<i32> {
    match fs::read(data.join(SETTINGS_FILENAME)) {
        Ok(bytes) => validate(
            serde_json::from_slice::<SyncSettings>(&bytes)
                .map_err(storage)?
                .adjustment_ms,
        ),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(0),
        Err(e) => Err(storage(e)),
    }
}
pub(super) fn apply(data: &Path) -> Result<()> {
    fusionplay_miplay_sdk::media::set_apple_sync_adjustment_millis(load(data)?);
    Ok(())
}
#[uniffi::export]
impl Receiver {
    pub fn sync_adjustment(&self) -> Result<i32> {
        load(&self.data)
    }
    pub fn set_sync_adjustment(&self, millis: i32) -> Result<()> {
        let _operation = self.operations.lock().map_err(storage)?;
        let value = validate(millis)?;
        save_json(
            &self.data.join(SETTINGS_FILENAME),
            &SyncSettings {
                adjustment_ms: value,
            },
        )?;
        fusionplay_miplay_sdk::media::set_apple_sync_adjustment_millis(value);
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn sync_preference_defaults_persists_and_rejects_invalid_values() {
        let dir =
            std::env::temp_dir().join(format!("fusionplay-apple-sync-{}", uuid::Uuid::new_v4()));
        let receiver = Receiver::new(dir.to_string_lossy().into()).unwrap();
        assert_eq!(receiver.sync_adjustment().unwrap(), 0);
        for value in [-200, 200, -35] {
            receiver.set_sync_adjustment(value).unwrap();
            assert_eq!(receiver.sync_adjustment().unwrap(), value);
        }
        assert!(receiver.set_sync_adjustment(201).is_err());
        assert!(receiver.set_sync_adjustment(-201).is_err());
        drop(receiver);

        let receiver = Receiver::new(dir.to_string_lossy().into()).unwrap();
        assert_eq!(receiver.sync_adjustment().unwrap(), -35);
        receiver.set_sync_adjustment(0).unwrap();
        assert_eq!(receiver.sync_adjustment().unwrap(), 0);
        drop(receiver);
        fs::remove_dir_all(dir).unwrap();
    }
}
