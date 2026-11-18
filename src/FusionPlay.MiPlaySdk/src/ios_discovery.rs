//! iOS uses the system Bonjour responder. Opening a raw multicast socket
//! would require the restricted multicast entitlement on physical devices.

use super::EventEmitter;
use anyhow::{Context, Result, bail};
use serde_json::json;
use std::{
    cell::Cell,
    ffi::{CString, c_char, c_void},
    io,
    ptr::{self, NonNull},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

type ServiceRef = *mut c_void;
type RegisterReply = unsafe extern "C" fn(
    ServiceRef,
    u32,
    i32,
    *const c_char,
    *const c_char,
    *const c_char,
    *mut c_void,
);

// These public dns_sd.h functions are exported by libSystem on iOS.
unsafe extern "C" {
    fn DNSServiceRegister(
        reference: *mut ServiceRef,
        flags: u32,
        interface_index: u32,
        name: *const c_char,
        kind: *const c_char,
        domain: *const c_char,
        host: *const c_char,
        port: u16,
        txt_length: u16,
        txt_record: *const c_void,
        callback: Option<RegisterReply>,
        context: *mut c_void,
    ) -> i32;
    fn DNSServiceRefSockFD(reference: ServiceRef) -> libc::c_int;
    fn DNSServiceProcessResult(reference: ServiceRef) -> i32;
    fn DNSServiceRefDeallocate(reference: ServiceRef);
}

const NO_AUTO_RENAME: u32 = 0x8; // Refuse ambiguous ownership of the protocol instance ID.
const LOCAL_NETWORK_POLICY_DENIED: i32 = -65570;
const REGISTER_TIMEOUT: Duration = Duration::from_secs(8);

pub(super) struct Service {
    pub name: String,
    pub kind: &'static str,
    pub port: u16,
    pub txt: Vec<u8>,
}

pub(super) fn spawn(
    services: [Service; 2],
    interface_name: &str,
    shutdown: Arc<AtomicBool>,
    events: EventEmitter,
) -> Result<JoinHandle<()>> {
    let interface = CString::new(interface_name).context("invalid iOS LAN interface name")?;
    // SAFETY: the interface name is a live, NUL-terminated C string.
    let interface_index = unsafe { libc::if_nametoindex(interface.as_ptr()) };
    if interface_index == 0 {
        bail!("The selected iOS LAN interface is no longer available");
    }
    let (startup, result) = mpsc::sync_channel(1);
    let worker_shutdown = Arc::clone(&shutdown);
    let worker = thread::Builder::new()
        .name("miplay-ios-bonjour".into())
        .spawn(move || {
            let mut startup = Some(startup);
            let outcome = run(
                &services,
                interface_index,
                &worker_shutdown,
                &events,
                &mut startup,
            );
            if let Err(error) = outcome {
                if let Some(startup) = startup {
                    let _ = startup.send(Err(error));
                } else {
                    events(json!({
                        "event": "discovery_backend_failed",
                        "protocol": "xiaomi_miplay",
                        "backend": "ios_bonjour",
                        "error": error.to_string(),
                    }));
                }
            }
        })
        .context("start iOS Bonjour worker")?;
    // Always withdraw any partially registered service if the second one fails.
    let error = match result.recv_timeout(REGISTER_TIMEOUT + Duration::from_secs(1)) {
        Ok(Ok(())) => return Ok(worker),
        Ok(Err(error)) => error,
        Err(error) => anyhow::Error::new(error).context("iOS Bonjour did not finish starting"),
    };
    shutdown.store(true, Ordering::Release);
    let _ = worker.join();
    Err(error)
}

fn run(
    services: &[Service; 2],
    interface_index: u32,
    shutdown: &AtomicBool,
    events: &EventEmitter,
    startup: &mut Option<mpsc::SyncSender<Result<()>>>,
) -> Result<()> {
    let registrations = [
        Registration::new(&services[0], interface_index)?,
        Registration::new(&services[1], interface_index)?,
    ];
    let mut poll_descriptors = [
        registrations[0].descriptor()?,
        registrations[1].descriptor()?,
    ];
    let deadline = Instant::now() + REGISTER_TIMEOUT;
    while !shutdown.load(Ordering::Acquire) {
        // Each reference and its callback context stay on this thread.
        // Polling bounds shutdown latency while preserving dns_sd.h's
        // requirement to call DNSServiceProcessResult only on a readable FD.
        let ready = unsafe {
            libc::poll(
                poll_descriptors.as_mut_ptr(),
                poll_descriptors.len() as libc::nfds_t,
                150,
            )
        };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error).context("poll iOS Bonjour");
        }
        for ((service, registration), descriptor) in
            services.iter().zip(&registrations).zip(&poll_descriptors)
        {
            if descriptor.revents & libc::POLLIN != 0 {
                registration
                    .process()
                    .with_context(|| format!("register {}", service.kind))?;
            }
            if descriptor.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
                bail!("iOS Bonjour responder disconnected");
            }
        }
        if startup.is_some() && registrations.iter().all(Registration::registered) {
            events(json!({
                "event": "discovery_backend_ready",
                "protocol": "xiaomi_miplay",
                "backend": "ios_bonjour",
                "interface_index": interface_index,
            }));
            if let Some(startup) = startup.take() {
                let _ = startup.send(Ok(()));
            }
        }
        if startup.is_some() && Instant::now() >= deadline {
            bail!("iOS Bonjour timed out; allow Local Network access in Settings and try again");
        }
    }
    Ok(())
}

struct Registration {
    reference: NonNull<c_void>,
    // The allocation is the callback context. Deallocate the Bonjour reference
    // first in Drop, before Rust releases the context.
    status: Box<Cell<Option<i32>>>,
}

impl Registration {
    fn new(service: &Service, interface_index: u32) -> Result<Self> {
        let name = CString::new(service.name.as_str()).context("invalid iOS Bonjour instance")?;
        let kind = CString::new(service.kind).context("invalid iOS Bonjour service type")?;
        let length = u16::try_from(service.txt.len()).context("iOS Bonjour TXT record too long")?;
        let mut reference = ptr::null_mut();
        let status = Box::new(Cell::new(None));
        let context = ptr::from_ref(&*status).cast_mut().cast();
        // SAFETY: all inputs are owned and valid for the call. Bonjour copies
        // the names and TXT bytes. The boxed context lives until after Drop.
        let error = unsafe {
            DNSServiceRegister(
                &mut reference,
                NO_AUTO_RENAME,
                interface_index,
                name.as_ptr(),
                kind.as_ptr(),
                c"local.".as_ptr(),
                ptr::null(), // Let the system publish its host and A/AAAA records.
                service.port.to_be(),
                length,
                service.txt.as_ptr().cast(),
                Some(register_reply),
                context,
            )
        };
        check(error).with_context(|| format!("register {}", service.kind))?;
        let reference = NonNull::new(reference).context("iOS Bonjour returned an empty service")?;
        Ok(Self { reference, status })
    }

    fn descriptor(&self) -> Result<libc::pollfd> {
        // SAFETY: the reference remains owned by this Registration.
        let fd = unsafe { DNSServiceRefSockFD(self.reference.as_ptr()) };
        if fd < 0 {
            bail!("iOS Bonjour returned an invalid service descriptor");
        }
        Ok(libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        })
    }

    fn process(&self) -> Result<()> {
        // SAFETY: only the worker thread calls this on the readable descriptor.
        check(unsafe { DNSServiceProcessResult(self.reference.as_ptr()) })?;
        check(self.status.get().unwrap_or(0))
    }

    fn registered(&self) -> bool {
        self.status.get() == Some(0)
    }
}

impl Drop for Registration {
    fn drop(&mut self) {
        // SAFETY: owned reference, released once on the originating thread.
        unsafe { DNSServiceRefDeallocate(self.reference.as_ptr()) };
    }
}

unsafe extern "C" fn register_reply(
    _reference: ServiceRef,
    _flags: u32,
    error: i32,
    _name: *const c_char,
    _kind: *const c_char,
    _domain: *const c_char,
    context: *mut c_void,
) {
    // SAFETY: registration associates this pointer with a live Cell and
    // callbacks execute synchronously on the thread pumping the reference.
    unsafe { &*context.cast::<Cell<Option<i32>>>() }.set(Some(error));
}

fn check(error: i32) -> Result<()> {
    match error {
        0 => Ok(()),
        LOCAL_NETWORK_POLICY_DENIED => {
            bail!("Local Network access denied; allow FusionPlay in iOS Settings")
        }
        _ => bail!("iOS Bonjour error {error}"),
    }
}
