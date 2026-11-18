//! iOS exposes getifaddrs but does not expose the routing-table API
//! used by the desktop getifs backend.

use super::{IfAddr, IfOperStatus, Ifv4Addr, Ifv6Addr, Interface};
use std::{ffi::CStr, io, net::IpAddr, ptr};

struct InterfaceList(*mut libc::ifaddrs);

impl Drop for InterfaceList {
    fn drop(&mut self) {
        // SAFETY: only getifaddrs initialized this list, which this guard owns.
        unsafe { libc::freeifaddrs(self.0) };
    }
}

pub fn get_if_addrs() -> io::Result<Vec<Interface>> {
    let mut head = ptr::null_mut();
    // SAFETY: head points to writable storage for the returned list.
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return Err(io::Error::last_os_error());
    }
    let list = InterfaceList(head);
    let mut interfaces = Vec::new();
    let mut next = list.0;
    // SAFETY: each node and the referenced C strings and addresses remain
    // owned by the getifaddrs list until the end of this function.
    while let Some(entry) = unsafe { next.as_ref() } {
        next = entry.ifa_next;
        if entry.ifa_name.is_null() {
            continue;
        }
        let flags = entry.ifa_flags as libc::c_int;
        let address = ip_address(entry.ifa_addr);
        let mask = ip_address(entry.ifa_netmask);
        let addr = match (address, mask) {
            (Some(IpAddr::V4(ip)), Some(IpAddr::V4(netmask))) => {
                let broadcast = if flags & libc::IFF_BROADCAST != 0 {
                    match ip_address(entry.ifa_dstaddr) {
                        Some(IpAddr::V4(address)) => Some(address),
                        _ => None,
                    }
                } else {
                    None
                };
                IfAddr::V4(Ifv4Addr {
                    ip,
                    netmask,
                    prefixlen: u32::from(netmask).count_ones() as u8,
                    broadcast,
                })
            }
            (Some(IpAddr::V6(ip)), Some(IpAddr::V6(netmask))) => IfAddr::V6(Ifv6Addr {
                ip,
                netmask,
                prefixlen: u128::from(netmask).count_ones() as u8,
                broadcast: None,
            }),
            _ => continue,
        };
        let name = unsafe { CStr::from_ptr(entry.ifa_name) }
            .to_string_lossy()
            .into_owned();
        let index = unsafe { libc::if_nametoindex(entry.ifa_name) };
        interfaces.push(Interface {
            name,
            addr,
            index: (index != 0).then_some(index),
            oper_status: if flags & libc::IFF_UP != 0 {
                IfOperStatus::Up
            } else {
                IfOperStatus::Down
            },
            is_p2p: flags & libc::IFF_POINTOPOINT != 0,
        });
    }
    Ok(interfaces)
}

fn ip_address(address: *const libc::sockaddr) -> Option<IpAddr> {
    // SAFETY: pointers come from getifaddrs, are checked for null, and are
    // cast only to the address structure indicated by family and length.
    if address.is_null() {
        return None;
    }
    // Read Darwin's two-byte header first. Some other address families
    // may be shorter than a full sockaddr, so avoid borrowing the whole struct.
    let length = unsafe { ptr::addr_of!((*address).sa_len).read() } as usize;
    let family = unsafe { ptr::addr_of!((*address).sa_family).read() };
    match i32::from(family) {
        libc::AF_INET if length >= size_of::<libc::sockaddr_in>() => {
            let ip = unsafe {
                ptr::addr_of!((*address.cast::<libc::sockaddr_in>()).sin_addr).read_unaligned()
            };
            Some(std::net::Ipv4Addr::from(ip.s_addr.to_ne_bytes()).into())
        }
        libc::AF_INET6 if length >= size_of::<libc::sockaddr_in6>() => {
            let ip = unsafe {
                ptr::addr_of!((*address.cast::<libc::sockaddr_in6>()).sin6_addr).read_unaligned()
            };
            Some(std::net::Ipv6Addr::from(ip.s6_addr).into())
        }
        _ => None,
    }
}
