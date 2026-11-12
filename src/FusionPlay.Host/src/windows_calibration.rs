//! Windows endpoint calibration is separate from the stable Mac host settings.
use super::*;

#[derive(Default, Serialize, Deserialize)]
struct CalibrationFile {
    // Legacy values mean an unsigned advance. Retain them for ABI-1 clients.
    #[serde(default)]
    outputs: BTreeMap<String, u32>,
    #[serde(default)]
    offsets_ms: BTreeMap<String, i32>,
}

fn load(data: &Path) -> Result<CalibrationFile> {
    let path = data.join("output-calibration.json");
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map_err(storage),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(CalibrationFile::default()),
        Err(e) => Err(storage(e)),
    }
}
fn output_key(settings: &Settings) -> Result<String> {
    if !settings.output_device.is_empty() {
        return Ok(settings.output_device.clone());
    }
    Ok(audio_devices()?
        .into_iter()
        .find(|output| output.is_default)
        .map(|output| output.id)
        .unwrap_or_default())
}
fn offset(file: &CalibrationFile, key: &str) -> Result<i32> {
    let value = match file.offsets_ms.get(key) {
        Some(value) => *value,
        None => {
            let advance = *file.outputs.get(key).unwrap_or(&0);
            if advance > 500 {
                return Err(HostError::InvalidConfig {
                    message: "Legacy output compensation must be 0–500 ms".into(),
                });
            }
            -(advance as i32)
        }
    };
    if !(-500..=500).contains(&value) {
        return Err(HostError::InvalidConfig {
            message: "Output offset must be -500 to 500 ms".into(),
        });
    }
    Ok(value)
}
pub(super) fn apply(data: &Path, settings: &Settings) -> Result<()> {
    let key = output_key(settings)?;
    let value = offset(&load(data)?, &key)?;
    fusionplay_miplay_sdk::media::set_windows_sync_adjustment_millis(value);
    Ok(())
}
pub(super) fn get(receiver: &Receiver) -> Result<Value> {
    let key = output_key(&receiver.settings())?;
    let value = offset(&load(&receiver.data)?, &key)?;
    Ok(
        serde_json::json!({"output_device_id": key, "offset_ms": value,
        "advance_ms": (-value).max(0)}),
    )
}
pub(super) fn set(receiver: &Receiver, key: String, value: i32) -> Result<()> {
    let _operation = receiver.operations.lock().map_err(storage)?;
    if key.is_empty() || !(-500..=500).contains(&value) {
        return Err(HostError::InvalidConfig {
            message: "Output offset must be -500 to 500 ms for an available device".into(),
        });
    }
    if output_key(&receiver.settings())? != key {
        return Err(HostError::InvalidConfig {
            message: "当前声音输出已改变，请刷新设置后再校准。".into(),
        });
    }
    let mut file = load(&receiver.data)?;
    file.outputs.insert(key.clone(), (-value).max(0) as u32);
    file.offsets_ms.insert(key, value);
    save_json(&receiver.data.join("output-calibration.json"), &file)?;
    fusionplay_miplay_sdk::media::set_windows_sync_adjustment_millis(value);
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn compensation_is_endpoint_specific_persistent_and_bounded() {
        let dir =
            std::env::temp_dir().join(format!("fusionplay-calibration-{}", uuid::Uuid::new_v4()));
        let receiver = Receiver::new(dir.to_string_lossy().into()).unwrap();
        receiver.settings.lock().unwrap().output_device = "endpoint-a".into();
        set(&receiver, "endpoint-a".into(), -120).unwrap();
        assert_eq!(get(&receiver).unwrap()["offset_ms"], -120);
        assert_eq!(get(&receiver).unwrap()["advance_ms"], 120);
        assert!(set(&receiver, "endpoint-b".into(), 120).is_err());
        assert!(set(&receiver, "endpoint-a".into(), 501).is_err());
        assert!(set(&receiver, "endpoint-a".into(), -501).is_err());
        assert_eq!(get(&receiver).unwrap()["offset_ms"], -120);
        for value in [-500, 500, 40, -120] {
            set(&receiver, "endpoint-a".into(), value).unwrap();
            assert_eq!(get(&receiver).unwrap()["offset_ms"], value);
        }
        receiver.settings.lock().unwrap().output_device = "endpoint-b".into();
        assert_eq!(get(&receiver).unwrap()["advance_ms"], 0);
        receiver.settings.lock().unwrap().output_device = "endpoint-a".into();
        assert_eq!(get(&receiver).unwrap()["advance_ms"], 120);
        drop(receiver);
        assert_eq!(offset(&load(&dir).unwrap(), "endpoint-a").unwrap(), -120);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn legacy_advances_keep_direction_and_endpoints_after_signed_save() {
        let dir = std::env::temp_dir().join(format!(
            "fusionplay-calibration-migration-{}",
            uuid::Uuid::new_v4()
        ));
        let receiver = Receiver::new(dir.to_string_lossy().into()).unwrap();
        fs::write(
            dir.join("output-calibration.json"),
            br#"{"outputs":{"endpoint-a":500,"endpoint-b":125}}"#,
        )
        .unwrap();
        receiver.settings.lock().unwrap().output_device = "endpoint-a".into();
        assert_eq!(get(&receiver).unwrap()["offset_ms"], -500);
        receiver.settings.lock().unwrap().output_device = "endpoint-b".into();
        assert_eq!(get(&receiver).unwrap()["offset_ms"], -125);
        set(&receiver, "endpoint-b".into(), 75).unwrap();
        let saved = load(&dir).unwrap();
        assert_eq!(offset(&saved, "endpoint-a").unwrap(), -500);
        assert_eq!(offset(&saved, "endpoint-b").unwrap(), 75);
        assert_eq!(saved.outputs["endpoint-b"], 0);
        drop(receiver);
        fs::remove_dir_all(dir).unwrap();
    }
}
