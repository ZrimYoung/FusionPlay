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
            let value = input["advance_ms"]
                .as_u64()
                .filter(|v| *v <= 500)
                .ok_or_else(|| HostError::InvalidConfig {
                    message: "Output compensation must be 0–500 ms".into(),
                })?;
            windows_calibration::set(&receiver, key, value as u32)?;
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
}
