//! Platform-neutral host contract. Neither Swift nor the Android JNI API is
//! coupled to the SDK's diagnostic JSON schema.
use fusionplay_miplay_sdk::{MediaAction, MiPlayReceiver, ReceiverConfig, ReceiverIdentity};
use serde::{Deserialize, Serialize};
use serde_json::Value;
#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::Write,
    net::Ipv4Addr,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
#[cfg(any(target_os = "macos", target_os = "ios"))]
mod apple_sync;
mod network_identity;
#[cfg(windows)]
mod windows_calibration;
#[cfg(windows)]
mod windows_ffi;
uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum HostError {
    #[error("Invalid configuration: {message}")]
    InvalidConfig { message: String },
    #[error("Storage: {message}")]
    Storage { message: String },
    #[error("Receiver: {message}")]
    Receiver { message: String },
    #[error("Another receiver is using this data directory")]
    AlreadyRunning,
}
type Result<T> = std::result::Result<T, HostError>;
fn storage(e: impl std::fmt::Display) -> HostError {
    HostError::Storage {
        message: e.to_string(),
    }
}
fn receiver_error(e: impl std::fmt::Display) -> HostError {
    HostError::Receiver {
        message: format!("{e:#}"),
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, uniffi::Record)]
pub struct Settings {
    pub name: String,
    pub interface_name: String,
    pub output_device: String,
    pub volume: u32,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            name: if cfg!(windows) {
                "FusionPlay-Windows"
            } else if cfg!(target_os = "ios") {
                "FusionPlay-iOS"
            } else {
                "FusionPlay-Mac"
            }
            .into(),
            interface_name: String::new(),
            output_device: String::new(),
            volume: 50,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum Phase {
    Stopped,
    Starting,
    Ready,
    Connected,
    Playing,
    Paused,
    Failed,
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, uniffi::Enum)]
pub enum PlaybackCommand {
    Play,
    Pause,
    Previous,
    Next,
}
impl From<PlaybackCommand> for MediaAction {
    fn from(command: PlaybackCommand) -> Self {
        match command {
            PlaybackCommand::Play => Self::Resume,
            PlaybackCommand::Pause => Self::Pause,
            PlaybackCommand::Previous => Self::Previous,
            PlaybackCommand::Next => Self::Next,
        }
    }
}
#[derive(Clone, Debug, Serialize, uniffi::Record)]
pub struct CommandOutcome {
    pub dispatched: bool,
    pub confirmed: bool,
}
#[derive(Clone, Debug, PartialEq, Serialize, uniffi::Record)]
pub struct Snapshot {
    pub phase: Phase,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub track_id: String,
    pub artwork_url: String,
    pub lyrics_text: String,
    pub duration_ms: Option<u64>,
    pub position_ms: Option<u64>,
    pub controls_available: bool,
    pub volume: u32,
    pub message: String,
    pub address: String,
    pub output: String,
    pub queue_ms: f64,
    pub output_latency_ms: f64,
    pub schedule_error_ms: f64,
    pub underruns: u64,
    pub dropped_frames: u64,
    pub resyncs: u64,
    pub display_title: Option<String>,
    pub display_artist: Option<String>,
    pub display_album: Option<String>,
}
impl Default for Snapshot {
    fn default() -> Self {
        Self {
            phase: Phase::Stopped,
            title: String::new(),
            artist: String::new(),
            album: String::new(),
            track_id: String::new(),
            artwork_url: String::new(),
            lyrics_text: String::new(),
            duration_ms: None,
            position_ms: None,
            controls_available: false,
            volume: 50,
            message: "接收器未启动".into(),
            address: String::new(),
            output: String::new(),
            queue_ms: 0.0,
            output_latency_ms: 0.0,
            schedule_error_ms: 0.0,
            underruns: 0,
            dropped_frames: 0,
            resyncs: 0,
            display_title: None,
            display_artist: None,
            display_album: None,
        }
    }
}
#[derive(Clone, Debug, Serialize, uniffi::Record)]
pub struct NetworkInterface {
    pub name: String,
    pub address: String,
}
#[derive(Clone, Debug, Serialize, uniffi::Record)]
pub struct AudioDevice {
    pub id: String,
    pub name: String,
    pub is_default: bool,
}

#[uniffi::export]
pub fn network_interfaces() -> Result<Vec<NetworkInterface>> {
    let mut interfaces: Vec<_> = if_addrs::get_if_addrs()
        .map_err(receiver_error)?
        .into_iter()
        .filter(|i| i.is_oper_up() && !i.is_loopback() && !i.is_p2p() && !i.is_link_local())
        // Wi-Fi and USB-C Ethernet use an en* interface. Do not advertise a
        // cellular or VPN address as the LAN receiver on iPhone and iPad.
        .filter(|i| !cfg!(target_os = "ios") || i.name.starts_with("en"))
        .filter_map(|i| match i.ip() {
            std::net::IpAddr::V4(ip) => Some(NetworkInterface {
                name: i.name,
                address: ip.to_string(),
            }),
            _ => None,
        })
        .collect();
    #[cfg(not(windows))]
    interfaces.sort_by_key(|i| (!i.name.starts_with("en"), i.name.clone(), i.address.clone()));
    #[cfg(windows)]
    {
        let gateways: std::collections::HashSet<_> = getifs::gateway_ipv4_addrs()
            .unwrap_or_default()
            .iter()
            .filter_map(|g| g.name().ok().map(|n| n.to_string()))
            .collect();
        interfaces.sort_by_key(|i| {
            (
                !network_identity::physical_lan_interface(&i.name),
                !gateways.contains(&i.name),
                network_identity::interface_hardware_address(&i.name).is_none(),
                i.name.clone(),
                i.address.clone(),
            )
        });
    }
    Ok(interfaces)
}
#[uniffi::export]
pub fn audio_devices() -> Result<Vec<AudioDevice>> {
    #[cfg(any(target_os = "macos", windows))]
    {
        use cpal::traits::{DeviceTrait, HostTrait};
        let host = cpal::default_host();
        let default_id = host
            .default_output_device()
            .and_then(|d| d.id().ok())
            .map(|i| i.to_string());
        host.output_devices()
            .map_err(receiver_error)?
            .map(|d| {
                let id = d.id().map_err(receiver_error)?.to_string();
                Ok(AudioDevice {
                    is_default: default_id.as_ref() == Some(&id),
                    id,
                    name: d.description().map_err(receiver_error)?.name().into(),
                })
            })
            .collect()
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        Ok(Vec::new())
    }
}

#[uniffi::export(callback_interface)]
pub trait StateListener: Send + Sync {
    fn on_state(&self, state: Snapshot);
}

#[derive(Serialize, Deserialize)]
struct Identity {
    idm: String,
    lyra: String,
    media: String,
    #[cfg(any(target_os = "macos", target_os = "ios"))]
    #[serde(default)]
    control_port: u16,
}
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn new_control_port() -> u16 {
    49152 + (uuid::Uuid::new_v4().as_u128() % 16384) as u16
}
fn load_identity(dir: &Path) -> Result<Identity> {
    let path = dir.join("identity.json");
    if path.exists() {
        let mut identity: Identity = serde_json::from_slice(&fs::read(&path).map_err(storage)?).map_err(storage)?;
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        if identity.control_port == 0 || identity.control_port == 8899 {
            identity.control_port = new_control_port();
            save_json(&path, &identity)?;
        }
        return Ok(identity);
    }
    let identity = Identity {
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        control_port: new_control_port(),
        idm: uuid::Uuid::new_v4().to_string(),
        lyra: uuid::Uuid::new_v4().simple().to_string()[..8].to_uppercase(),
        media: uuid::Uuid::new_v4().simple().to_string()[..8].to_uppercase(),
    };
    save_json(&path, &identity)?;
    Ok(identity)
}
fn private_options() -> OpenOptions {
    #[cfg(unix)]
    let mut options = OpenOptions::new();
    #[cfg(not(unix))]
    let options = OpenOptions::new();
    #[cfg(unix)]
    options.mode(0o600);
    options
}

fn save_json(path: &Path, value: &impl Serialize) -> Result<()> {
    let tmp = path.with_extension("tmp");
    let mut file = private_options()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&tmp)
        .map_err(storage)?;
    file.write_all(&serde_json::to_vec_pretty(value).map_err(storage)?)
        .map_err(storage)?;
    file.sync_all().map_err(storage)?;
    fs::rename(tmp, path).map_err(storage)
}
struct Shared {
    state: Mutex<Snapshot>,
    revision: AtomicU64,
    listeners: Mutex<BTreeMap<u64, Arc<dyn StateListener>>>,
    generation: AtomicU64,
    shutdown: AtomicBool,
}
struct Event {
    generation: u64,
    value: Value,
}
#[derive(uniffi::Object)]
pub struct Receiver {
    shared: Arc<Shared>,
    core: Mutex<Option<MiPlayReceiver>>,
    settings: Mutex<Settings>,
    operations: Mutex<()>,
    data: PathBuf,
    _lock: File,
    tx: mpsc::SyncSender<Event>,
    worker: Mutex<Option<thread::JoinHandle<()>>>,
    next_listener: AtomicU64,
}

#[uniffi::export]
impl Receiver {
    #[uniffi::constructor]
    pub fn new(data_directory: String) -> Result<Arc<Self>> {
        let data = PathBuf::from(data_directory);
        if !data.is_absolute() {
            return Err(HostError::InvalidConfig {
                message: "Data directory must be absolute".into(),
            });
        }
        fs::create_dir_all(&data).map_err(storage)?;
        #[cfg(unix)]
        fs::set_permissions(&data, fs::Permissions::from_mode(0o700)).map_err(storage)?;
        let lock = private_options()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(data.join("receiver.lock"))
            .map_err(storage)?;
        // The OS releases this portable data-directory lock on process exit.
        if lock.try_lock().is_err() {
            return Err(HostError::AlreadyRunning);
        }
        load_identity(&data)?;
        let settings: Settings = if data.join("settings.json").exists() {
            serde_json::from_slice(&fs::read(data.join("settings.json")).map_err(storage)?)
                .map_err(storage)?
        } else {
            Settings::default()
        };
        let shared = Arc::new(Shared {
            state: Mutex::new(Snapshot {
                volume: settings.volume,
                ..Snapshot::default()
            }),
            revision: AtomicU64::new(1),
            listeners: Mutex::new(BTreeMap::new()),
            generation: AtomicU64::new(0),
            shutdown: AtomicBool::new(false),
        });
        let (tx, rx) = mpsc::sync_channel::<Event>(512);
        let log_dir = data.parent().unwrap_or(&data).join("logs");
        fs::create_dir_all(&log_dir).map_err(storage)?;
        let worker_shared = shared.clone();
        let worker = thread::Builder::new()
            .name("fusionplay-events".into())
            .spawn(move || {
                let mut receiver_generation = 0;
                let mut media_generation = 0;
                while !worker_shared.shutdown.load(Ordering::Acquire) {
                    match rx.recv_timeout(Duration::from_millis(100)) {
                        Ok(event) => {
                            if event.generation != worker_shared.generation.load(Ordering::Acquire)
                            {
                                continue;
                            }
                            if receiver_generation != event.generation {
                                receiver_generation = event.generation;
                                media_generation = 0;
                            }
                            if !accept_media_generation(&mut media_generation, &event.value) {
                                continue;
                            }
                            let (snapshot, changed) = {
                                let mut state = worker_shared.state.lock().unwrap();
                                if event.generation
                                    != worker_shared.generation.load(Ordering::Acquire)
                                {
                                    continue;
                                }
                                let previous = state.clone();
                                reduce(&mut state, &event.value);
                                let changed = *state != previous;
                                if changed {
                                    worker_shared.revision.fetch_add(1, Ordering::Release);
                                }
                                (state.clone(), changed)
                            };
                            write_diagnostic(&log_dir, &event.value);
                            if !changed && event.value["event"] != "host_stopped" {
                                continue;
                            }
                            let listeners: Vec<_> = worker_shared
                                .listeners
                                .lock()
                                .unwrap()
                                .values()
                                .cloned()
                                .collect();
                            for listener in listeners {
                                listener.on_state(snapshot.clone());
                            }
                        }
                        Err(mpsc::RecvTimeoutError::Disconnected) => break,
                        Err(mpsc::RecvTimeoutError::Timeout) => {}
                    }
                }
            })
            .map_err(storage)?;
        Ok(Arc::new(Self {
            shared,
            core: Mutex::new(None),
            settings: Mutex::new(settings),
            operations: Mutex::new(()),
            data,
            _lock: lock,
            tx,
            worker: Mutex::new(Some(worker)),
            next_listener: AtomicU64::new(1),
        }))
    }
    pub fn settings(&self) -> Settings {
        self.settings.lock().unwrap().clone()
    }
    pub fn snapshot(&self) -> Snapshot {
        self.shared.state.lock().unwrap().clone()
    }
    pub fn subscribe(&self, listener: Box<dyn StateListener>) -> u64 {
        let id = self.next_listener.fetch_add(1, Ordering::Relaxed);
        self.shared
            .listeners
            .lock()
            .unwrap()
            .insert(id, Arc::from(listener));
        id
    }
    pub fn unsubscribe(&self, token: u64) {
        self.shared.listeners.lock().unwrap().remove(&token);
    }
    pub fn start(&self, settings: Settings) -> Result<()> {
        let _operation = self.operations.lock().unwrap();
        self.stop_inner();
        if settings.name.trim().is_empty()
            || settings.name.chars().count() > 64
            || settings.volume > 100
        {
            return Err(HostError::InvalidConfig {
                message: "Name must contain 1–64 characters; volume must be 0–100".into(),
            });
        }
        let result = self.start_inner(settings);
        if let Err(error) = &result {
            self.emit(serde_json::json!({"event":"host_error", "message": error.to_string()}));
        }
        result
    }
    pub fn stop(&self) {
        let _operation = self.operations.lock().unwrap();
        self.stop_inner();
    }
    pub fn control(&self, command: PlaybackCommand) -> Result<CommandOutcome> {
        let _operation = self.operations.lock().unwrap();
        if !self.snapshot().controls_available {
            return Err(receiver_error("No active media session"));
        }
        let controller = self
            .core
            .lock()
            .unwrap()
            .as_ref()
            .ok_or_else(|| receiver_error("Receiver is stopped"))?
            .controller();
        let outcome = controller
            .send_confirmed(command.into(), Duration::from_millis(1500))
            .map_err(receiver_error)?;
        // The SDK immediately gates local output after a dispatched pause. A
        // remote confirmation is reported separately, never fabricated.
        if outcome.dispatched || outcome.confirmed {
            match command {
                PlaybackCommand::Pause => self.emit(serde_json::json!({
                    "event":"host_control_pause", "confirmed": outcome.confirmed
                })),
                PlaybackCommand::Play => {
                    self.emit(serde_json::json!({"event":"host_control_resume"}))
                }
                _ => {}
            }
        }
        Ok(CommandOutcome {
            dispatched: outcome.dispatched,
            confirmed: outcome.confirmed,
        })
    }
    /// Request a phone-side seek; never fabricate local playback progress.
    pub fn seek(&self, position_ms: u64, expected_track_id: String, expected_title: String) -> Result<CommandOutcome> {
        let _operation = self.operations.lock().map_err(storage)?;
        let state = self.snapshot();
        if !state.controls_available || !matches_expected_track(&state, &expected_track_id, &expected_title)
            || !matches!(state.duration_ms, Some(duration) if duration > 0 && position_ms <= duration) {
            return Err(HostError::InvalidConfig { message: "Track changed, duration unavailable, or seek target out of range".into() });
        }
        let controller = self.core.lock().map_err(storage)?.as_ref()
            .ok_or_else(|| receiver_error("Receiver is stopped"))?.controller();
        let outcome = controller.send_confirmed(MediaAction::Seek(position_ms), Duration::from_millis(1500))
            .map_err(receiver_error)?;
        // A confirmation can arrive as the sender changes tracks. Preserve the
        // fact that the request was dispatched, but do not claim that a new
        // track's state confirms this request against the preceding metadata.
        let current = self.snapshot();
        let confirmed = outcome.confirmed && current.controls_available
            && matches_expected_track(&current, &expected_track_id, &expected_title);
        Ok(CommandOutcome { dispatched: outcome.dispatched, confirmed })
    }
    pub fn set_volume(&self, volume: u32) -> Result<()> {
        let _operation = self.operations.lock().unwrap();
        if volume > 100 {
            return Err(HostError::InvalidConfig {
                message: "Volume exceeds 100".into(),
            });
        }
        if let Some(core) = self.core.lock().unwrap().as_ref() {
            core.controller()
                .set_volume(volume as u8)
                .map_err(receiver_error)?;
        }
        let mut settings = self.settings.lock().unwrap();
        settings.volume = volume;
        save_json(&self.data.join("settings.json"), &*settings)?;
        self.emit(serde_json::json!({"event":"volume", "percent":volume}));
        Ok(())
    }
}
impl Receiver {
    fn start_inner(&self, settings: Settings) -> Result<()> {
        let interface = network_interfaces()?
            .into_iter()
            .find(|i| settings.interface_name.is_empty() || i.name == settings.interface_name)
            .ok_or_else(|| HostError::InvalidConfig {
                message: "No active LAN interface; reconnect Wi-Fi or select an interface".into(),
            })?;
        if !settings.output_device.is_empty()
            && !audio_devices()?
                .iter()
                .any(|d| d.id == settings.output_device)
        {
            return Err(HostError::InvalidConfig {
                message: "Selected audio output is unavailable".into(),
            });
        }
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        apple_sync::apply(&self.data)?;
        let mut identity = load_identity(&self.data)?;
        #[cfg(windows)]
        windows_calibration::apply(&self.data, &settings)?;
        let hardware_address = network_identity::interface_hardware_address(&interface.name);
        let config = ReceiverConfig::new(
            settings.name.trim(),
            ReceiverIdentity::new(identity.idm.clone(), identity.lyra.clone(), identity.media.clone()),
            interface
                .address
                .parse::<Ipv4Addr>()
                .map_err(receiver_error)?,
            interface.name,
        )
        .with_output_device(
            (!settings.output_device.is_empty()).then(|| settings.output_device.clone()),
        )
        .with_initial_volume_percent(settings.volume)
        .with_hardware_address(hardware_address);
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        let config = config.with_preferred_control_port(Some(identity.control_port));
        #[cfg(windows)]
        let config = config.with_preferred_control_port(
            fs::read(self.data.join("control-port.json"))
                .ok()
                .and_then(|bytes| serde_json::from_slice::<u16>(&bytes).ok())
                // Isolate this app from the vendor's well-known 8899 route,
                // even when the vendor receiver is temporarily not listening.
                .filter(|port| *port > 0 && *port != 8899)
                .or(Some(18899)),
        );
        save_json(&self.data.join("settings.json"), &settings)?;
        *self.settings.lock().unwrap() = settings;
        self.shared.state.lock().unwrap().phase = Phase::Starting;
        self.shared.revision.fetch_add(1, Ordering::Release);
        let tx = self.tx.clone();
        let generation = self.shared.generation.load(Ordering::Acquire);
        let core = MiPlayReceiver::start(
            config,
            Arc::new(move |value| {
                let _ = tx.try_send(Event { generation, value });
            }),
        )
        .map_err(receiver_error)?;
        #[cfg(windows)]
        save_json(&self.data.join("control-port.json"), &core.control_port())?;
        #[cfg(any(target_os = "macos", target_os = "ios"))]
        {
            identity.control_port = core.control_port();
            if let Err(error) = save_json(&self.data.join("identity.json"), &identity) {
                core.controller().stop();
                return Err(error);
            }
        }
        *self.core.lock().unwrap() = Some(core);
        Ok(())
    }
    fn emit(&self, value: Value) {
        let _ = self.tx.try_send(Event {
            generation: self.shared.generation.load(Ordering::Acquire),
            value,
        });
    }
    fn stop_inner(&self) {
        self.shared.generation.fetch_add(1, Ordering::AcqRel);
        if let Some(core) = self.core.lock().unwrap().take() {
            core.controller().stop();
            drop(core);
        }
        let volume = self.settings.lock().unwrap().volume;
        *self.shared.state.lock().unwrap() = Snapshot {
            volume,
            ..Snapshot::default()
        };
        self.shared.revision.fetch_add(1, Ordering::Release);
        self.emit(serde_json::json!({"event":"host_stopped"}));
    }
}
impl Drop for Receiver {
    fn drop(&mut self) {
        self.stop_inner();
        self.shared.shutdown.store(true, Ordering::Release);
        self.shared.listeners.lock().unwrap().clear();
        if let Some(worker) = self.worker.lock().unwrap().take() {
            let _ = worker.join();
        }
    }
}

fn is_control_connection_error(value: &Value) -> bool {
    value["event"] == "error"
        && matches!(
            value["code"].as_str(),
            Some("miplay_control_session_failed" | "miplay_control_write_failed")
        )
}

// Classify known parser failures without persisting packet bytes or arbitrary
// exception text. This is a diagnostic hint, not an inferred root cause.
fn control_error_hint(value: &Value) -> &'static str {
    let message = value["message"].as_str().unwrap_or("");
    if message.contains("invalid MiPlay control header") {
        "invalid_control_header"
    } else if message.contains("invalid MiPlay body length")
        || message.contains("body is too large")
    {
        "invalid_body_length"
    } else if message.contains("Broken pipe") {
        "broken_pipe"
    } else {
        "unclassified"
    }
}

fn accept_media_generation(active: &mut u64, value: &Value) -> bool {
    let Some(generation) = value["media_generation"].as_u64().filter(|v| *v > 0) else {
        return true;
    };
    if generation < *active {
        return false;
    }
    if value["event"] == "interconnect_stage" && value["stage"] == "media_session_established" {
        *active = generation;
    }
    true
}

fn matches_expected_track(state: &Snapshot, id: &str, title: &str) -> bool {
    if !id.is_empty() { state.track_id == id }
    else { state.track_id.is_empty() && state.title == title }
}

fn reduce(state: &mut Snapshot, value: &Value) {
    let text = |key| value[key].as_str().unwrap_or("").to_owned();
    match value["event"].as_str().unwrap_or("") {
        "receiver_ready" => {
            state.phase = Phase::Ready;
            state.address = text("address");
            state.message = "等待手机连接".into();
        }
        "interconnect_stage" if text("stage") == "media_session_established" => {
            state.controls_available = true;
            state.phase = Phase::Connected;
            state.message = "媒体会话已连接，等待声音".into();
        }
        "audio_output_signal_started" => {
            state.phase = Phase::Playing;
            state.message = "正在播放".into();
        }
        "audio_health" => {
            state.queue_ms = value["queue_ms"].as_f64().unwrap_or(0.0);
            state.output_latency_ms = value["output_latency_ms"].as_f64().unwrap_or(0.0);
            state.schedule_error_ms = value["schedule_error_ms"].as_f64().unwrap_or(0.0);
            state.underruns = value["underruns"].as_u64().unwrap_or(0);
            state.dropped_frames = value["dropped_frames"].as_u64().unwrap_or(0);
            state.resyncs = value["resyncs"].as_u64().unwrap_or(0);
            if value["rendering"].as_bool() == Some(true)
                && matches!(state.phase, Phase::Connected | Phase::Playing)
            {
                state.phase = Phase::Playing;
                state.message = "正在播放".into();
            } else if state.phase == Phase::Playing {
                state.phase = Phase::Connected;
                state.message = "等待音频数据".into();
            }
        }
        "playback_state" if value["playing"].as_bool() == Some(false) => {
            state.phase = if value["session_active"].as_bool() == Some(false) {
                Phase::Ready
            } else {
                Phase::Paused
            };
            state.message = if state.phase == Phase::Paused {
                "已暂停"
            } else {
                "等待手机连接"
            }
            .into();
            if state.phase == Phase::Ready {
                clear_media(state);
            }
        }
        "playback_state" if value["playing"].as_bool() == Some(true) => {
            if state.controls_available && state.phase == Phase::Paused {
                state.phase = Phase::Connected;
                state.message = "等待音频数据".into();
            }
        }
        "host_control_pause" if state.controls_available => {
            state.phase = Phase::Paused;
            state.message = if value["confirmed"] == true {
                "已暂停"
            } else {
                "本机输出已暂停，手机状态待确认"
            }
            .into();
        }
        "host_control_resume" if state.controls_available => {
            if state.phase == Phase::Paused {
                state.phase = Phase::Connected;
                state.message = "已请求播放，等待音频数据".into();
            }
        }
        "media_channel_closed" | "stream_stopped" => {
            clear_media(state);
            state.phase = Phase::Ready;
            state.message = "音频会话已结束，等待重新投送".into();
        }
        "media_info" => {
            let mut id = text("track_id");
            let incoming_lyrics = value["lyrics_text"].as_str().filter(|text| !text.is_empty());
            let changed_lyrics = incoming_lyrics.is_some_and(|text| !state.lyrics_text.is_empty() && text != state.lyrics_text);
            let projected = matches!(value["track_transition"].as_str(), Some("same" | "new"));
            let fallback = !projected && value["track_id_source"].as_str().is_some_and(|source| source != "explicit");
            let same_metadata = !state.title.is_empty() && value["title"].as_str() == Some(state.title.as_str())
                && [("artist", &state.artist), ("album", &state.album)].into_iter().all(|(key, existing)| {
                    value[key].as_str().is_none_or(|text| text.is_empty() || existing.is_empty() || text == existing)
                });
            let caption = !projected && !changed_lyrics && (fallback || id.is_empty() || id == state.track_id)
                && fusionplay_miplay_sdk::protocol::is_lyric_caption(value["title"].as_str().unwrap_or(""), &state.lyrics_text);
            // A phone can omit id/mLrc in its per-line caption refresh. Keep the
            // current identity rather than treating the caption hash as a song.
            if fallback && !state.track_id.is_empty() && !changed_lyrics && (same_metadata || caption
                || incoming_lyrics.is_some_and(|text| text == state.lyrics_text)) {
                id = state.track_id.clone();
            }
            if !id.is_empty() && id != state.track_id {
                state.title.clear();
                state.artist.clear();
                state.album.clear();
                state.artwork_url.clear();
                state.lyrics_text.clear();
                state.display_title = None;
                state.display_artist = None;
                state.display_album = None;
                state.duration_ms = None;
                state.position_ms = None;
                state.track_id = id;
            }
            let caption_lyrics = if caption { state.lyrics_text.clone() } else { String::new() };
            for (field, key) in [
                (&mut state.title, "title"),
                (&mut state.artist, "artist"),
                (&mut state.album, "album"),
                (&mut state.artwork_url, "artwork"),
                (&mut state.lyrics_text, "lyrics_text"),
            ] {
                let caption_header = if caption {
                    match key { "title" => Some("ti"), "artist" => Some("ar"), "album" => Some("al"), _ => None }
                } else { None };
                if let Some(header) = caption_header {
                    if let Some(canonical) = fusionplay_miplay_sdk::protocol::lyric_header(&caption_lyrics, header) { *field = canonical.into(); }
                } else if let Some(value) = value[key].as_str().filter(|v| !v.is_empty()) {
                    *field = value.into();
                }
            }
            for (field, key) in [
                (&mut state.display_title, "display_title"),
                (&mut state.display_artist, "display_artist"),
                (&mut state.display_album, "display_album"),
            ] {
                if let Some(display) = value[key].as_str() { *field = Some(display.to_owned()); }
            }
            if let Some(ms) = value["duration_ms"].as_u64().filter(|v| *v > 0) {
                state.duration_ms = Some(ms);
            }
            if let Some(ms) = value["position_ms"].as_u64() {
                state.position_ms = Some(ms);
            }
        }
        "progress" if state.controls_available => {
            if let Some(position) = value["position_ms"].as_u64() {
                state.position_ms = Some(position);
            }
        }
        "volume" => state.volume = value["percent"].as_u64().unwrap_or(50).min(100) as u32,
        "audio_output_ready" => state.output = text("device_name"),
        // Discovery/control sockets are independent of the media stream. The
        // SDK closes the failed connection while its listener keeps accepting.
        // Do not infer that the active audio session ended from an unscoped
        // control error; actual media-close/output events still govern it.
        "error" if is_control_connection_error(value) => {}
        "host_error" | "error" => {
            clear_media(state);
            state.phase = Phase::Failed;
            state.message = text("message");
        }
        _ => {}
    }
}
fn clear_media(state: &mut Snapshot) {
    state.controls_available = false;
    state.title.clear();
    state.artist.clear();
    state.album.clear();
    state.track_id.clear();
    state.artwork_url.clear();
    state.lyrics_text.clear();
    state.display_title = None;
    state.display_artist = None;
    state.display_album = None;
    state.duration_ms = None;
    state.position_ms = None;
}
// Allowlist: never persist authentication, packets, artwork or source addresses.
fn write_diagnostic(dir: &Path, event: &Value) {
    let name = event["event"].as_str().unwrap_or("unknown");
    if !matches!(
        name,
        "receiver_ready"
            | "audio_health"
            | "clock_synchronized"
            | "audio_output_ready"
            | "host_stopped"
            | "error"
            | "host_error"
            | "stream_started"
            | "stream_stopped"
            | "interconnect_stage"
            | "media_channel_closed"
            | "playback_state"
            | "volume"
            | "audio_pcm_decoded"
            | "ios_output_transport"
            | "ios_output_transport_error"
    ) {
        return;
    }
    let path = dir.join("receiver.jsonl");
    if fs::metadata(&path)
        .map(|m| m.len() > 5_000_000)
        .unwrap_or(false)
    {
        let _ = fs::rename(&path, dir.join("receiver.previous.jsonl"));
    }
    let mut record = serde_json::json!({"time_ms": SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis(), "event": name});
    if name == "error" || name == "host_error" {
        let local = is_control_connection_error(event);
        record["scope"] = if local {
            "control_connection"
        } else {
            "receiver"
        }
        .into();
        record["recovery"] = if local {
            "keep_listening"
        } else {
            "restart_receiver"
        }
        .into();
        if local {
            record["reason_hint"] = control_error_hint(event).into();
        }
    }
    for key in [
        "queue_ms",
        "output_latency_ms",
        "schedule_error_ms",
        "underruns",
        "dropped_frames",
        "resyncs",
        "rendering",
        "callback_frames",
        "silence_frames",
        "lock_contentions",
        "phase_error_us",
        "network_rtt_us",
        "sample_rate",
        "code",
        "stage",
        "media_generation",
        "playing",
        "session_active",
        "percent",
        "output_peak",
        "output_advance_ms",
        "receiver_volume",
        "peak",
        "rms",
        "non_silent",
    ] {
        if let Some(value) = event.get(key) {
            record[key] = value.clone();
        }
    }
    if let Ok(mut file) = private_options().create(true).append(true).open(path) {
        let _ = writeln!(file, "{record}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn projected_lyrics_title_keeps_raw_and_resets_with_the_track() {
        let mut state = Snapshot::default();
        reduce(&mut state, &serde_json::json!({
            "event":"media_info", "track_id":"one", "track_transition":"new",
            "title":"going home", "display_title":"Night Walk", "artwork":"cover",
            "lyrics_text":"[00:01]we are going home", "duration_ms":120000,
        }));
        reduce(&mut state, &serde_json::json!({
            "event":"media_info", "track_id":"one", "track_transition":"same",
            "title":"home", "display_title":"Night Walk", "position_ms":1000,
        }));
        assert_eq!(state.title, "home");
        assert_eq!(state.display_title.as_deref(), Some("Night Walk"));
        assert_eq!(state.artwork_url, "cover");
        assert_eq!(state.lyrics_text, "[00:01]we are going home");
        assert_eq!(state.duration_ms, Some(120000));
        reduce(&mut state, &serde_json::json!({
            "event":"media_info", "track_id":"two", "track_transition":"new",
            "title":"Home", "display_title":"",
        }));
        assert_eq!(state.title, "Home");
        assert_eq!(state.display_title.as_deref(), Some(""));
        assert!(state.artwork_url.is_empty() && state.lyrics_text.is_empty());
        clear_media(&mut state);
        assert_eq!(state.display_title, None);
    }

    #[test]
    fn seek_rejects_disconnected_unknown_duration_stale_track_and_out_of_range() {
        let dir = std::env::temp_dir().join(format!("fusionplay-seek-{}", uuid::Uuid::new_v4()));
        let r = Receiver::new(dir.to_string_lossy().into()).unwrap();
        assert!(matches!(r.seek(0, "a".into(), "Song".into()), Err(HostError::InvalidConfig { .. })));
        {
            let mut state = r.shared.state.lock().unwrap();
            state.controls_available = true; state.track_id = "a".into(); state.title = "Song".into();
        }
        assert!(matches!(r.seek(0, "a".into(), "Song".into()), Err(HostError::InvalidConfig { .. })));
        r.shared.state.lock().unwrap().duration_ms = Some(1000);
        for (position, track, title) in [(1001, "a", "Song"), (0, "b", "Song")] {
            assert!(matches!(r.seek(position, track.into(), title.into()), Err(HostError::InvalidConfig { .. })));
        }
        // Valid boundaries and changed display captions with the same stable ID
        // reach the controller rather than being rejected as a different song.
        for (position, title) in [(0, "Song"), (1000, "Song"), (0, "New caption")] {
            assert!(matches!(r.seek(position, "a".into(), title.into()), Err(HostError::Receiver { .. })));
        }
        drop(r); fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn closing_an_old_media_generation_cannot_clear_the_new_track() {
        let mut active = 0;
        let open = |generation| serde_json::json!({"event":"interconnect_stage","stage":"media_session_established","media_generation":generation});
        assert!(accept_media_generation(&mut active, &open(1)));
        assert!(accept_media_generation(&mut active, &open(2)));
        assert!(!accept_media_generation(
            &mut active,
            &serde_json::json!({"event":"media_channel_closed","media_generation":1})
        ));
        assert!(!accept_media_generation(
            &mut active,
            &serde_json::json!({"event":"stream_stopped","media_generation":1})
        ));
        assert!(accept_media_generation(
            &mut active,
            &serde_json::json!({"event":"media_channel_closed","media_generation":2})
        ));
        assert!(accept_media_generation(
            &mut active,
            &serde_json::json!({"event":"volume","percent":50})
        ));
    }
    #[test]
    #[cfg(target_os = "macos")]
    #[ignore = "requires LAN sockets and an available audio output"]
    fn port_conflict_and_missing_output_recover() {
        let root = std::env::temp_dir().join(format!("fusionplay-recover-{}", uuid::Uuid::new_v4()));
        let data = root.join("data");
        let r = Receiver::new(data.to_string_lossy().into()).unwrap();
        let ip: Ipv4Addr = network_interfaces().unwrap()[0].address.parse().unwrap();
        let occupied = std::net::TcpListener::bind((ip, 0)).unwrap();
        let mut identity = load_identity(&data).unwrap();
        identity.control_port = occupied.local_addr().unwrap().port();
        save_json(&data.join("identity.json"), &identity).unwrap();
        let settings = r.settings();
        r.start(settings.clone()).unwrap();
        let port = r.core.lock().unwrap().as_ref().unwrap().control_port();
        assert_ne!(port, identity.control_port);
        assert_eq!(load_identity(&data).unwrap().control_port, port);
        r.stop();
        drop(occupied);
        r.start(settings.clone()).unwrap();
        assert_eq!(r.core.lock().unwrap().as_ref().unwrap().control_port(), port);
        let mut missing = settings.clone();
        missing.output_device = "nonexistent-fusionplay-test-device".into();
        assert!(r.start(missing).is_err());
        assert!(r.core.lock().unwrap().is_none());
        r.start(settings).unwrap();
        assert_eq!(r.core.lock().unwrap().as_ref().unwrap().control_port(), port);
        r.stop(); drop(r);
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    #[ignore = "requires local LAN sockets; run explicitly with the app stopped"]
    fn malformed_control_probe_keeps_live_listener_and_redacts_diagnostic() {
        use std::net::TcpStream;
        let root = std::env::temp_dir().join(format!("fusionplay-probe-{}", uuid::Uuid::new_v4()));
        let r = Receiver::new(root.join("data").to_string_lossy().into()).unwrap();
        let mut settings = r.settings();
        settings.name = "FusionPlay-Mac-Diagnostic".into();
        r.start(settings).unwrap();
        for _ in 0..100 {
            if r.snapshot().phase == Phase::Ready {
                break;
            }
            thread::sleep(Duration::from_millis(30));
        }
        assert_eq!(r.snapshot().phase, Phase::Ready);
        let generation = r.shared.generation.load(Ordering::Acquire);
        let port = r.core.lock().unwrap().as_ref().unwrap().control_port();
        let address: Ipv4Addr = r.snapshot().address.parse().unwrap();
        {
            let mut socket = TcpStream::connect((address, port)).unwrap();
            socket.write_all(b"BADHEADER").unwrap();
        }
        let log = root.join("logs/receiver.jsonl");
        let mut observed = None;
        for _ in 0..100 {
            observed = fs::read_to_string(&log)
                .unwrap_or_default()
                .lines()
                .filter_map(|line| serde_json::from_str::<Value>(line).ok())
                .find(|v| v["code"] == "miplay_control_session_failed");
            if observed.is_some() {
                break;
            }
            thread::sleep(Duration::from_millis(30));
        }
        let diagnostic = observed.expect("expected the malformed probe to reach the real SDK");
        assert_eq!(diagnostic["scope"], "control_connection");
        assert_eq!(diagnostic["recovery"], "keep_listening");
        assert_eq!(diagnostic["reason_hint"], "invalid_control_header");
        assert!(diagnostic.get("message").is_none());
        assert!(diagnostic.get("remote").is_none());
        assert_eq!(r.snapshot().phase, Phase::Ready);
        assert_eq!(r.shared.generation.load(Ordering::Acquire), generation);
        // A subsequent connection must still be accepted on the same listener.
        let mut next = TcpStream::connect((address, port)).unwrap();
        next.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        let mut greeting = [0u8; 1];
        std::io::Read::read_exact(&mut next, &mut greeting).unwrap();
        assert_eq!(greeting[0], b'$');
        drop(next);
        r.stop();
        drop(r);
        fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn control_connection_failures_do_not_restart_the_receiver_or_clear_playback() {
        for phase in [
            Phase::Ready,
            Phase::Connected,
            Phase::Playing,
            Phase::Paused,
        ] {
            for code in [
                "miplay_control_session_failed",
                "miplay_control_write_failed",
            ] {
                let mut state = Snapshot {
                    controls_available: phase != Phase::Ready,
                    phase: phase.clone(),
                    title: "Keep current track".into(),
                    track_id: "current".into(),
                    position_ms: Some(1234),
                    ..Snapshot::default()
                };
                let before = state.clone();
                reduce(
                    &mut state,
                    &serde_json::json!({"event":"error", "code":code,
                    "message":"A single control connection failed"}),
                );
                assert_eq!(state, before, "{code} must not destroy {phase:?}");
            }
        }
    }
    #[test]
    fn fatal_output_errors_still_fail_and_real_media_end_still_clears_playback() {
        for code in [
            "miplay_audio_output_failed",
            "miplay_control_accept_failed",
            "unknown_error",
        ] {
            let mut state = Snapshot {
                phase: Phase::Playing,
                controls_available: true,
                title: "Track".into(),
                ..Snapshot::default()
            };
            reduce(
                &mut state,
                &serde_json::json!({"event":"error", "code":code, "message":"failed"}),
            );
            assert_eq!(state.phase, Phase::Failed);
            assert!(!state.controls_available);
        }
        let mut state = Snapshot {
            phase: Phase::Playing,
            controls_available: true,
            title: "Track".into(),
            ..Snapshot::default()
        };
        reduce(
            &mut state,
            &serde_json::json!({"event":"error", "code":"miplay_control_session_failed"}),
        );
        reduce(
            &mut state,
            &serde_json::json!({"event":"media_channel_closed"}),
        );
        assert_eq!(state.phase, Phase::Ready);
        assert!(!state.controls_available);
        assert!(state.title.is_empty());
    }
    #[test]
    fn media_lifecycle_preserves_partial_updates_and_clears_old_tracks() {
        let mut state = Snapshot::default();
        reduce(
            &mut state,
            &serde_json::json!({"event":"interconnect_stage", "stage":"media_session_established"}),
        );
        assert!(state.controls_available);
        reduce(
            &mut state,
            &serde_json::json!({"event":"media_info", "track_id":"one", "title":"First", "duration_ms":120000, "position_ms":5000, "artwork":"https://example.invalid/a.jpg"}),
        );
        reduce(
            &mut state,
            &serde_json::json!({"event":"media_info", "track_id":"one", "duration_ms":0, "position_ms":null}),
        );
        assert_eq!(state.title, "First");
        assert_eq!(state.duration_ms, Some(120000));
        assert_eq!(state.position_ms, Some(5000));
        reduce(
            &mut state,
            &serde_json::json!({"event":"media_info", "track_id":"two", "title":"Second"}),
        );
        assert_eq!(state.title, "Second");
        assert_eq!(state.duration_ms, None);
        assert_eq!(state.position_ms, None);
        assert!(state.artwork_url.is_empty());
        reduce(
            &mut state,
            &serde_json::json!({"event":"progress", "position_ms":8000}),
        );
        assert_eq!(state.position_ms, Some(8000));
        for update in [
            serde_json::json!({"event":"progress"}),
            serde_json::json!({"event":"progress", "position_ms":null}),
        ] {
            reduce(&mut state, &update);
            assert_eq!(state.position_ms, Some(8000));
        }
        reduce(&mut state, &serde_json::json!({"event":"progress", "position_ms":0}));
        assert_eq!(state.position_ms, Some(0));
        reduce(
            &mut state,
            &serde_json::json!({"event":"media_channel_closed"}),
        );
        assert!(!state.controls_available);
        assert!(state.title.is_empty());
        reduce(
            &mut state,
            &serde_json::json!({"event":"progress", "position_ms":9000}),
        );
        assert_eq!(state.position_ms, None);
    }
    #[test]
    fn lyrics_follow_track_and_session_without_empty_update_flicker() {
        let mut state = Snapshot::default();
        reduce(
            &mut state,
            &serde_json::json!({"event":"interconnect_stage", "stage":"media_session_established"}),
        );
        reduce(
            &mut state,
            &serde_json::json!({"event":"media_info", "track_id":"one", "lyrics_text":"[00:01.00]First"}),
        );
        for update in [
            serde_json::json!({"event":"media_info", "track_id":"one", "lyrics_text":""}),
            serde_json::json!({"event":"media_info", "lyrics_text":null}),
            serde_json::json!({"event":"media_info", "track_id":"one", "position_ms":2000}),
        ] {
            reduce(&mut state, &update);
            assert_eq!(state.lyrics_text, "[00:01.00]First");
        }
        reduce(
            &mut state,
            &serde_json::json!({"event":"media_info", "track_id":"two", "title":"Second"}),
        );
        assert!(state.lyrics_text.is_empty());
        reduce(
            &mut state,
            &serde_json::json!({"event":"media_info", "lyrics_text":"[00:02.00]Second"}),
        );
        assert_eq!(state.track_id, "two");
        assert_eq!(state.lyrics_text, "[00:02.00]Second");
        let populated = state;
        for event in [
            serde_json::json!({"event":"media_channel_closed"}),
            serde_json::json!({"event":"stream_stopped"}),
            serde_json::json!({"event":"playback_state", "playing":false, "session_active":false}),
            serde_json::json!({"event":"host_error", "message":"example"}),
        ] {
            let mut state = populated.clone();
            reduce(&mut state, &event);
            assert!(state.lyrics_text.is_empty());
        }
    }

    #[test]
    fn caption_partial_updates_keep_track_metadata_progress_and_lyrics() {
        let mut state = Snapshot { track_id: "stable-song".into(), title: "Synthetic Song".into(),
            artist: "Artist".into(), album: "Album".into(), duration_ms: Some(180_000), position_ms: Some(60_000),
            lyrics_text: "[ti:Synthetic Song]\n[ar:Artist]\n[al:Album]\n[00:01]First caption\n[00:03]Second caption".into(),
            controls_available: true, ..Snapshot::default() };
        for update in [
            serde_json::json!({"event":"media_info", "track_id":"stable-song", "track_id_source":"explicit", "title":"First caption", "lyrics_text":null}),
            serde_json::json!({"event":"media_info", "track_id":"metadata:caption-hash", "track_id_source":"metadata", "title":"Second caption", "lyrics_text":""}),
            serde_json::json!({"event":"media_info", "track_id":"metadata:other-hash", "track_id_source":"metadata", "title":"Synthetic Song", "artist":"Artist", "album":"Album"}),
        ] {
            reduce(&mut state, &update);
            assert_eq!(state.track_id, "stable-song");
            assert_eq!(state.title, "Synthetic Song");
            assert_eq!(state.artist, "Artist");
            assert_eq!(state.duration_ms, Some(180_000));
            assert_eq!(state.position_ms, Some(60_000));
            assert!(!state.lyrics_text.is_empty());
        }
        reduce(&mut state, &serde_json::json!({"event":"media_info", "track_id":"metadata:new-document", "track_id_source":"lyrics_metadata",
            "title":"Next Song", "lyrics_text":"[ti:Next Song]\n[00:01]Next caption"}));
        assert_eq!(state.track_id, "metadata:new-document");
        assert_eq!(state.title, "Next Song");
        assert_eq!(state.position_ms, None);
        // A real new explicit ID must not be swallowed just because its title
        // happens to appear in the preceding song's lyrics.
        reduce(&mut state, &serde_json::json!({"event":"media_info", "track_id":"explicit-new", "track_id_source":"explicit", "title":"Next caption"}));
        assert_eq!(state.track_id, "explicit-new");
        assert_eq!(state.title, "Next caption");
        assert!(state.lyrics_text.is_empty());
    }

    #[test]
    fn seek_identity_prefers_stable_id_and_uses_title_only_without_one() {
        let mut state = Snapshot { track_id: "stable".into(), title: "Current caption".into(), ..Snapshot::default() };
        assert!(super::matches_expected_track(&state, "stable", "Earlier caption"));
        assert!(!super::matches_expected_track(&state, "different", "Current caption"));
        assert!(!super::matches_expected_track(&state, "", "Current caption"));
        state.track_id.clear();
        assert!(super::matches_expected_track(&state, "", "Current caption"));
        assert!(!super::matches_expected_track(&state, "", "Earlier caption"));
    }

    #[test]
    fn pause_survives_buffered_audio_and_resume_waits_for_output() {
        let mut state = Snapshot {
            controls_available: true,
            phase: Phase::Playing,
            ..Snapshot::default()
        };
        reduce(
            &mut state,
            &serde_json::json!({"event":"host_control_pause", "confirmed":false}),
        );
        assert_eq!(state.phase, Phase::Paused);
        assert!(state.message.contains("待确认"));
        reduce(
            &mut state,
            &serde_json::json!({"event":"audio_health", "rendering":true}),
        );
        assert_eq!(state.phase, Phase::Paused);
        reduce(
            &mut state,
            &serde_json::json!({"event":"host_control_resume"}),
        );
        assert_eq!(state.phase, Phase::Connected);
        reduce(
            &mut state,
            &serde_json::json!({"event":"audio_health", "rendering":true}),
        );
        assert_eq!(state.phase, Phase::Playing);
        reduce(
            &mut state,
            &serde_json::json!({"event":"playback_state", "playing":false, "session_active":false}),
        );
        assert!(!state.controls_available);
        assert_eq!(state.phase, Phase::Ready);
    }
    #[test]
    fn handshake_is_not_playback() {
        let mut s = Snapshot::default();
        reduce(&mut s, &serde_json::json!({"event":"receiver_ready"}));
        reduce(
            &mut s,
            &serde_json::json!({"event":"interconnect_stage", "stage":"transport_connected"}),
        );
        assert_eq!(s.phase, Phase::Ready);
        reduce(
            &mut s,
            &serde_json::json!({"event":"playback_state", "playing":true}),
        );
        assert_eq!(s.phase, Phase::Ready);
        reduce(
            &mut s,
            &serde_json::json!({"event":"audio_output_signal_started"}),
        );
        assert_eq!(s.phase, Phase::Playing);
    }
    #[test]
    #[cfg(target_os = "macos")]
    fn legacy_identity_keeps_device_ids_and_allocates_port() {
        let dir = std::env::temp_dir().join(format!("fusionplay-migrate-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("identity.json"), br#"{"idm":"old-id","lyra":"old-lyra","media":"old-media"}"#).unwrap();
        let first = load_identity(&dir).unwrap();
        assert_eq!(first.idm, "old-id");
        assert_eq!(first.lyra, "old-lyra");
        assert_eq!(first.media, "old-media");
        assert!(first.control_port >= 49152);
        assert_eq!(first.control_port, load_identity(&dir).unwrap().control_port);
        fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn identity_persistence_and_exclusive_ownership() {
        let dir = std::env::temp_dir().join(format!("fusionplay-test-{}", uuid::Uuid::new_v4()));
        let r = Receiver::new(dir.to_string_lossy().into()).unwrap();
        for command in [
            PlaybackCommand::Play,
            PlaybackCommand::Pause,
            PlaybackCommand::Previous,
            PlaybackCommand::Next,
        ] {
            assert!(r.control(command).is_err());
        }
        let first = load_identity(&dir).unwrap();
        assert!(matches!(
            Receiver::new(dir.to_string_lossy().into()),
            Err(HostError::AlreadyRunning)
        ));
        r.stop();
        r.stop();
        drop(r);
        let r = Receiver::new(dir.to_string_lossy().into()).unwrap();
        assert_eq!(first.idm, load_identity(&dir).unwrap().idm);
        r.set_volume(23).unwrap();
        drop(r);
        let r = Receiver::new(dir.to_string_lossy().into()).unwrap();
        assert_eq!(r.settings().volume, 23);
        drop(r);
        fs::remove_dir_all(dir).unwrap();
    }
}
