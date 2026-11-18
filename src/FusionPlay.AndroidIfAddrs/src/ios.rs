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
        let mask = address.and_then(|address| ip_netmask(entry.ifa_netmask, address));
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

fn ip_netmask(address: *const libc::sockaddr, interface: IpAddr) -> Option<IpAddr> {
    match interface {
        IpAddr::V4(_) => netmask_bytes(
            address,
            libc::AF_INET,
            std::mem::offset_of!(libc::sockaddr_in, sin_addr),
        )
        .map(|bytes: [u8; 4]| std::net::Ipv4Addr::from(bytes).into()),
        IpAddr::V6(_) => netmask_bytes(
            address,
            libc::AF_INET6,
            std::mem::offset_of!(libc::sockaddr_in6, sin6_addr),
        )
        .map(|bytes: [u8; 16]| std::net::Ipv6Addr::from(bytes).into()),
    }
}

/// Darwin may omit trailing zeros from netmask sockaddrs, even when the
/// interface address is a full sockaddr_in or sockaddr_in6 of the same family.
fn netmask_bytes<const N: usize>(
    address: *const libc::sockaddr,
    expected_family: libc::c_int,
    offset: usize,
) -> Option<[u8; N]> {
    if address.is_null() {
        return None;
    }

    // SAFETY: getifaddrs supplies at least the length byte. Only read the
    // family when it fits and copy no more than the bytes reported by sa_len.
    let length = unsafe { ptr::addr_of!((*address).sa_len).read() } as usize;
    if length >= 2 {
        let family = i32::from(unsafe { ptr::addr_of!((*address).sa_family).read() });
        if family != expected_family && family != libc::AF_UNSPEC {
            return None;
        }
    }

    let mut bytes = [0; N];
    let available = length.saturating_sub(offset).min(N);
    if available > 0 {
        // SAFETY: the source region is wholly within the reported length and
        // the destination is a separate stack array of at least that size.
        unsafe {
            ptr::copy_nonoverlapping(
                address.cast::<u8>().add(offset),
                bytes.as_mut_ptr(),
                available,
            );
        }
    }
    Some(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, Ipv6Addr};

    #[test]
    fn finds_the_darwin_ipv4_loopback_interface() {
        let interfaces = get_if_addrs().expect("getifaddrs");
        assert!(interfaces.iter().any(|interface| {
            interface.is_oper_up() && interface.ip() == IpAddr::from(Ipv4Addr::LOCALHOST)
        }));
    }

    #[test]
    fn reads_darwins_compressed_ipv4_masks() {
        let interface = Ipv4Addr::new(192, 168, 0, 5).into();
        let lan = [7, libc::AF_INET as u8, 0, 0, 255, 255, 255];
        let eight = [5, libc::AF_INET as u8, 0, 0, 255];
        assert_eq!(
            ip_netmask(lan.as_ptr().cast(), interface),
            Some(Ipv4Addr::new(255, 255, 255, 0).into())
        );
        assert_eq!(
            ip_netmask(eight.as_ptr().cast(), interface),
            Some(Ipv4Addr::new(255, 0, 0, 0).into())
        );
        // Compressed masks are never accepted as interface addresses.
        assert_eq!(ip_address(lan.as_ptr().cast()), None);
    }

    #[test]
    fn reads_an_unspecified_family_and_zero_length() {
        let interface = Ipv4Addr::new(192, 168, 0, 5).into();
        let mask = [6, libc::AF_UNSPEC as u8, 0, 0, 255, 255];
        assert_eq!(
            ip_netmask(mask.as_ptr().cast(), interface),
            Some(Ipv4Addr::new(255, 255, 0, 0).into())
        );
        assert_eq!(
            ip_netmask([0_u8].as_ptr().cast(), interface),
            Some(Ipv4Addr::UNSPECIFIED.into())
        );
        assert_eq!(
            ip_netmask([2, libc::AF_INET as u8].as_ptr().cast(), interface),
            Some(Ipv4Addr::UNSPECIFIED.into())
        );
        assert_eq!(
            ip_netmask([2, libc::AF_INET6 as u8].as_ptr().cast(), interface),
            None
        );
        assert_eq!(ip_netmask(ptr::null(), interface), None);
    }

    #[test]
    fn zero_extends_an_ipv6_mask_after_its_last_nonzero_byte() {
        let interface = Ipv6Addr::LOCALHOST.into();
        let offset = std::mem::offset_of!(libc::sockaddr_in6, sin6_addr);
        let mut mask = vec![0; offset + 9];
        mask[0] = mask.len() as u8;
        mask[1] = libc::AF_INET6 as u8;
        mask[offset..offset + 8].fill(255);
        mask[offset + 8] = 128;
        assert_eq!(
            ip_netmask(mask.as_ptr().cast(), interface),
            Some(Ipv6Addr::new(65535, 65535, 65535, 65535, 32768, 0, 0, 0).into())
        );
    }
}
