//! Versioned Windows C boundary. Callers never consume the SDK event stream.
//! Every returned buffer belongs to this DLL and must be freed by fp_buffer_free.
use super::*;
use std::collections::HashMap;
use std::sync::OnceLock;

const ABI: u32 = 1;
const MAX_REQUEST: usize = 8 * 1024 * 1024;
static RECEIVERS: OnceLock<Mutex<HashMap<u64, Arc<Receiver>>>> = OnceLock::new();
static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);

#[repr(C)]
pub struct Buffer {
    pub data: *mut u8,
    pub len: usize,
}

fn handles() -> &'static Mutex<HashMap<u64, Arc<Receiver>>> {
    RECEIVERS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn request(handle: u64, input: Value) -> Result<Value> {
    let op = input["op"].as_str().unwrap_or("");
    match op {
        "create" => {
            let path =
                input["data_directory"]
                    .as_str()
                    .ok_or_else(|| HostError::InvalidConfig {
                        message: "Missing absolute data directory".into(),
                    })?;
            let receiver = Receiver::new(path.into())?;
            let id = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
            let settings = receiver.settings();
            handles().lock().map_err(storage)?.insert(id, receiver);
            return Ok(serde_json::json!({"handle": id, "settings": settings}));
        }
        "networks" => return serde_json::to_value(network_interfaces()?).map_err(storage),
        "outputs" => return serde_json::to_value(audio_devices()?).map_err(storage),
        "destroy" => {
            let receiver = handles().lock().map_err(storage)?.remove(&handle);
            // Stop/join outside the handle registry lock.
            drop(receiver);
            return Ok(Value::Null);
        }
        _ => {}
    }
    let receiver = handles()
        .lock()
        .map_err(storage)?
        .get(&handle)
        .cloned()
        .ok_or_else(|| HostError::InvalidConfig {
            message: "Receiver handle is closed or invalid".into(),
        })?;
    match op {
        "poll" => {
            let state = receiver.shared.state.lock().map_err(storage)?;
            let revision = receiver.shared.revision.load(Ordering::Acquire);
            Ok(serde_json::json!({"revision": revision,
                "snapshot": if input["revision"].as_u64() == Some(revision) { None } else { Some(&*state) }}))
        }
        "settings" => Ok(serde_json::to_value(receiver.settings()).map_err(storage)?),
        "get_calibration" => windows_calibration::get(&receiver),
        "set_calibration" => {
            let key = input["output_device_id"].as_str().unwrap_or("").to_owned();
            // New signed offsets take precedence; ABI-1 advance-only clients
            // continue to use a positive number for earlier playback.
            let value = if let Some(value) = input.get("offset_ms") {
                value.as_i64().filter(|v| (-500..=500).contains(v))
            } else {
                input["advance_ms"]
                    .as_u64()
                    .filter(|v| *v <= 500)
                    .map(|v| -(v as i64))
            }
            .ok_or_else(|| HostError::InvalidConfig {
                message: "Output offset must be -500 to 500 ms".into(),
            })?;
            windows_calibration::set(&receiver, key, value as i32)?;
            Ok(Value::Null)
        }
        "start" => {
            let settings = serde_json::from_value(input["settings"].clone()).map_err(|e| {
                HostError::InvalidConfig {
                    message: e.to_string(),
                }
            })?;
            receiver.start(settings)?;
            Ok(Value::Null)
        }
        "stop" => {
            receiver.stop();
            Ok(Value::Null)
        }
        "control" => {
            let command = serde_json::from_value(input["command"].clone()).map_err(|e| {
                HostError::InvalidConfig {
                    message: e.to_string(),
                }
            })?;
            Ok(serde_json::to_value(receiver.control(command)?).map_err(storage)?)
        }
        "seek" => {
            let position_ms =
                input["position_ms"]
                    .as_u64()
                    .ok_or_else(|| HostError::InvalidConfig {
                        message: "position_ms is required and must be an unsigned 64-bit integer"
                            .into(),
                    })?;
            let expected_track_id =
                input["expected_track_id"]
                    .as_str()
                    .ok_or_else(|| HostError::InvalidConfig {
                        message: "expected_track_id is required and must be a string".into(),
                    })?;
            let expected_title =
                input["expected_title"]
                    .as_str()
                    .ok_or_else(|| HostError::InvalidConfig {
                        message: "expected_title is required and must be a string".into(),
                    })?;
            serde_json::to_value(receiver.seek(
                position_ms,
                expected_track_id.to_owned(),
                expected_title.to_owned(),
            )?)
            .map_err(storage)
        }
        "volume" => {
            let volume = input["volume"]
                .as_u64()
                .filter(|v| *v <= 100)
                .ok_or_else(|| HostError::InvalidConfig {
                    message: "Volume must be 0–100".into(),
                })?;
            receiver.set_volume(volume as u32)?;
            Ok(Value::Null)
        }
        _ => Err(HostError::InvalidConfig {
            message: "Unknown ABI operation".into(),
        }),
    }
}

fn reply(result: Result<Value>) -> Value {
    match result {
        Ok(value) => serde_json::json!({"abi": ABI, "ok": true, "value": value}),
        Err(error) => {
            let code = match &error {
                HostError::InvalidConfig { .. } => "invalid_config",
                HostError::Storage { .. } => "storage",
                HostError::Receiver { .. } => "receiver",
                HostError::AlreadyRunning => "already_running",
            };
            serde_json::json!({"abi": ABI, "ok": false, "error": {"code": code, "message": error.to_string()}})
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fp_abi_version() -> u32 {
    ABI
}

/// # Safety
/// `input` must remain readable for `len` bytes until this call returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fp_invoke(handle: u64, input: *const u8, len: usize) -> Buffer {
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if input.is_null() || len == 0 || len > MAX_REQUEST {
            return reply(Err(HostError::InvalidConfig { message: "Invalid request buffer".into() }));
        }
        let bytes = unsafe { std::slice::from_raw_parts(input, len) };
        let result = serde_json::from_slice(bytes)
            .map_err(|e| HostError::InvalidConfig { message: e.to_string() })
            .and_then(|value| request(handle, value));
        reply(result)
    })).unwrap_or_else(|_| serde_json::json!({"abi": ABI, "ok": false, "error": {"code":"internal", "message":"Native receiver operation failed"}}));
    let mut bytes = serde_json::to_vec(&result)
        .expect("ABI values serialize")
        .into_boxed_slice();
    let buffer = Buffer {
        data: bytes.as_mut_ptr(),
        len: bytes.len(),
    };
    std::mem::forget(bytes);
    buffer
}

/// # Safety
/// Pass each buffer returned by fp_invoke exactly once, without changing it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fp_buffer_free(buffer: Buffer) {
    if !buffer.data.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(buffer.data, buffer.len)) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn invoke(handle: u64, value: Value) -> Value {
        let bytes = serde_json::to_vec(&value).unwrap();
        let buffer = unsafe { fp_invoke(handle, bytes.as_ptr(), bytes.len()) };
        let result =
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(buffer.data, buffer.len) })
                .unwrap();
        unsafe { fp_buffer_free(buffer) };
        result
    }
    #[test]
    fn c_boundary_preserves_identity_and_rejects_stale_handles() {
        let dir = std::env::temp_dir().join(format!("fusionplay-中文-{}", uuid::Uuid::new_v4()));
        let mut identity = None;
        for _ in 0..10 {
            let created = invoke(0, serde_json::json!({"op":"create", "data_directory":dir}));
            assert_eq!(created["ok"], true, "{created}");
            let handle = created["value"]["handle"].as_u64().unwrap();
            let contents = fs::read(dir.join("identity.json")).unwrap();
            if let Some(previous) = &identity {
                assert_eq!(previous, &contents);
            } else {
                identity = Some(contents);
            }
            let locked = invoke(0, serde_json::json!({"op":"create", "data_directory":dir}));
            assert_eq!(locked["error"]["code"], "already_running");
            let first = invoke(handle, serde_json::json!({"op":"poll"}));
            let revision = &first["value"]["revision"];
            assert_eq!(
                invoke(
                    handle,
                    serde_json::json!({"op":"poll", "revision":revision})
                )["value"]["snapshot"],
                Value::Null
            );
            assert_eq!(
                invoke(
                    handle,
                    serde_json::json!({"op":"control", "command":"Next"})
                )["ok"],
                false
            );
            assert_eq!(
                invoke(handle, serde_json::json!({"op":"volume", "volume":101}))["ok"],
                false
            );
            assert_eq!(
                invoke(handle, serde_json::json!({"op":"volume", "volume":23}))["ok"],
                true
            );
            assert_eq!(
                invoke(handle, serde_json::json!({"op":"settings"}))["value"]["volume"],
                23
            );
            assert_eq!(
                invoke(handle, serde_json::json!({"op":"destroy"}))["ok"],
                true
            );
            assert_eq!(
                invoke(handle, serde_json::json!({"op":"poll"}))["error"]["code"],
                "invalid_config"
            );
        }
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn invalid_json_returns_owned_error_buffer() {
        let bytes = b"{invalid";
        let result = unsafe { fp_invoke(0, bytes.as_ptr(), bytes.len()) };
        let value: Value =
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(result.data, result.len) })
                .unwrap();
        assert_eq!(value["error"]["code"], "invalid_config");
        unsafe { fp_buffer_free(result) };
    }

    #[test]
    fn calibration_abi_accepts_signed_and_legacy_values_without_invalid_fallback() {
        let dir = std::env::temp_dir().join(format!(
            "fusionplay-calibration-abi-{}",
            uuid::Uuid::new_v4()
        ));
        let created = invoke(0, serde_json::json!({"op":"create", "data_directory":dir}));
        let handle = created["value"]["handle"].as_u64().unwrap();
        let receiver = handles().lock().unwrap().get(&handle).unwrap().clone();
        receiver.settings.lock().unwrap().output_device = "abi-endpoint".into();
        let set = |fields: Value| {
            let mut value =
                serde_json::json!({"op":"set_calibration", "output_device_id":"abi-endpoint"});
            value
                .as_object_mut()
                .unwrap()
                .extend(fields.as_object().unwrap().clone());
            invoke(handle, value)
        };
        assert_eq!(set(serde_json::json!({"advance_ms":125}))["ok"], true);
        assert_eq!(
            invoke(handle, serde_json::json!({"op":"get_calibration"}))["value"]["offset_ms"],
            -125
        );
        assert_eq!(
            set(serde_json::json!({"offset_ms":75,"advance_ms":125}))["ok"],
            true
        );
        for invalid in [
            serde_json::json!(null),
            serde_json::json!(501),
            serde_json::json!(-501),
            serde_json::json!(1.5),
            serde_json::json!("25"),
        ] {
            assert_eq!(
                set(serde_json::json!({"offset_ms":invalid,"advance_ms":100}))["error"]["code"],
                "invalid_config"
            );
            assert_eq!(
                invoke(handle, serde_json::json!({"op":"get_calibration"}))["value"]["offset_ms"],
                75
            );
        }
        assert_eq!(set(serde_json::json!({"advance_ms":501}))["ok"], false);
        assert_eq!(
            invoke(handle, serde_json::json!({"op":"destroy"}))["ok"],
            true
        );
        drop(receiver);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn seek_abi_requires_typed_fields_and_never_substitutes_missing_track_guards() {
        let dir = std::env::temp_dir().join(format!(
            "fusionplay-seek-abi-types-{}",
            uuid::Uuid::new_v4()
        ));
        let created = invoke(0, serde_json::json!({"op":"create", "data_directory":dir}));
        let handle = created["value"]["handle"].as_u64().unwrap();
        {
            let receiver = handles().lock().unwrap().get(&handle).unwrap().clone();
            let mut state = receiver.shared.state.lock().unwrap();
            state.controls_available = true;
            state.duration_ms = Some(1000);
            state.position_ms = Some(125);
            // Exact empty guards are legal values in the Host contract. Omitting
            // either required field must still fail before reaching that contract.
        }
        let request = serde_json::json!({"op":"seek", "position_ms":500, "expected_track_id":"", "expected_title":""});
        let before = invoke(handle, serde_json::json!({"op":"poll"}))["value"].clone();
        assert_eq!(invoke(handle, request.clone())["error"]["code"], "receiver");
        for field in ["position_ms", "expected_track_id", "expected_title"] {
            let mut missing = request.clone();
            missing.as_object_mut().unwrap().remove(field);
            let rejected = invoke(handle, missing);
            assert_eq!(rejected["error"]["code"], "invalid_config");
            assert!(
                rejected["error"]["message"]
                    .as_str()
                    .unwrap()
                    .contains(field)
            );
            let invalid = if field == "position_ms" {
                vec![
                    serde_json::json!(null),
                    serde_json::json!(-1),
                    serde_json::json!(1.5),
                    serde_json::json!("500"),
                    serde_json::json!(true),
                    serde_json::json!([]),
                ]
            } else {
                vec![
                    serde_json::json!(null),
                    serde_json::json!(5),
                    serde_json::json!(false),
                    serde_json::json!([]),
                    serde_json::json!({}),
                ]
            };
            for value in invalid {
                let mut malformed = request.clone();
                malformed[field] = value;
                let rejected = invoke(handle, malformed);
                assert_eq!(rejected["error"]["code"], "invalid_config");
                assert!(
                    rejected["error"]["message"]
                        .as_str()
                        .unwrap()
                        .contains(field)
                );
            }
        }
        assert_eq!(
            invoke(handle, serde_json::json!({"op":"poll"}))["value"],
            before
        );
        assert_eq!(
            invoke(handle, serde_json::json!({"op":"destroy"}))["ok"],
            true
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn seek_abi_checks_session_track_range_and_never_projects_requested_progress() {
        let dir = std::env::temp_dir().join(format!(
            "fusionplay-seek-abi-routing-{}",
            uuid::Uuid::new_v4()
        ));
        let created = invoke(0, serde_json::json!({"op":"create", "data_directory":dir}));
        let handle = created["value"]["handle"].as_u64().unwrap();
        let seek = |position, track, title| {
            invoke(
                handle,
                serde_json::json!({"op":"seek", "position_ms":position, "expected_track_id":track, "expected_title":title}),
            )
        };
        let before = invoke(handle, serde_json::json!({"op":"poll"}))["value"].clone();
        assert_eq!(
            seek(0, "track-a", "Song")["error"]["code"],
            "invalid_config"
        );
        assert_eq!(
            invoke(handle, serde_json::json!({"op":"poll"}))["value"],
            before
        );
        {
            let receiver = handles().lock().unwrap().get(&handle).unwrap().clone();
            let mut state = receiver.shared.state.lock().unwrap();
            state.controls_available = true;
            state.phase = Phase::Playing;
            state.track_id = "track-a".into();
            state.title = "Song".into();
            state.duration_ms = Some(1000);
            state.position_ms = Some(125);
        }
        let before = invoke(handle, serde_json::json!({"op":"poll"}))["value"].clone();
        for position in [0_u64, 1000] {
            // Valid boundary requests reach Receiver.seek's stopped-core check,
            // proving the ABI routes the operation rather than rejecting it as unknown.
            assert_eq!(
                seek(position, "track-a", "Song")["error"]["code"],
                "receiver"
            );
        }
        for (position, track, title) in [
            (1001, "track-a", "Song"),
            (u64::MAX, "track-a", "Song"),
            (500, "old-track", "Song"),
            (500, "track-a", "Old song"),
        ] {
            assert_eq!(
                seek(position, track, title)["error"]["code"],
                "invalid_config"
            );
        }
        assert_eq!(
            invoke(handle, serde_json::json!({"op":"poll"}))["value"],
            before
        );
        {
            let receiver = handles().lock().unwrap().get(&handle).unwrap().clone();
            receiver.shared.state.lock().unwrap().track_id = "track-b".into();
        }
        let changed = invoke(handle, serde_json::json!({"op":"poll"}))["value"].clone();
        assert_eq!(
            seek(500, "track-a", "Song")["error"]["code"],
            "invalid_config"
        );
        assert_eq!(
            invoke(handle, serde_json::json!({"op":"poll"}))["value"],
            changed
        );
        assert_eq!(
            invoke(handle, serde_json::json!({"op":"destroy"}))["ok"],
            true
        );
        assert_eq!(
            seek(500, "track-b", "Song")["error"]["code"],
            "invalid_config"
        );
        fs::remove_dir_all(dir).unwrap();
    }
}
