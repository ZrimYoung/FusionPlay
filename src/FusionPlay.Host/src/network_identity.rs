//! Publish the selected adapter's address, independently of the persistent
//! IDM/Lyra/control IDs. The eight-character media ID is not a MAC address and
//! caused the SDK to silently omit Mi Connect's `mac` field on this host.

#[cfg(windows)]
pub(crate) fn physical_lan_interface(name: &str) -> bool {
    use windows_sys::Win32::NetworkManagement::IpHelper::{GetIfEntry2, MIB_IF_ROW2};
    let Some(adapter) = getifs::interface_by_name(name).ok().flatten() else {
        return false;
    };
    let mut row = MIB_IF_ROW2 {
        InterfaceIndex: adapter.index(),
        ..Default::default()
    };
    // HardwareInterface is bit 0 of the Windows SDK status flags.
    (unsafe { GetIfEntry2(&mut row) }) == 0
        && physical_lan_flags(row.Type, row.InterfaceAndOperStatusFlags._bitfield)
}

#[cfg(any(windows, test))]
fn physical_lan_flags(interface_type: u32, flags: u8) -> bool {
    matches!(interface_type, 6 | 71) && flags & 1 != 0
}

#[cfg(any(target_os = "macos", windows))]
pub(crate) fn interface_hardware_address(name: &str) -> Option<String> {
    let adapter = getifs::interface_by_name(name).ok()??;
    normalize_hardware_address(adapter.mac_addr()?.octets())
}

#[cfg(not(any(target_os = "macos", windows)))]
pub(crate) fn interface_hardware_address(_name: &str) -> Option<String> {
    None
}

#[cfg(any(target_os = "macos", windows, test))]
fn normalize_hardware_address(address: [u8; 6]) -> Option<String> {
    if address[0] & 1 != 0 || address == [0; 6] || address == [2, 0, 0, 0, 0, 0] {
        return None;
    }
    Some(address.iter().map(|byte| format!("{byte:02X}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn automatic_selection_prefers_hardware_ethernet_and_wifi_over_tunnels() {
        assert!(physical_lan_flags(6, 1));
        assert!(physical_lan_flags(71, 1));
        assert!(!physical_lan_flags(53, 0));
        assert!(!physical_lan_flags(131, 1));
        assert!(!physical_lan_flags(6, 0));
    }

    #[test]
    fn discovery_uses_six_byte_unicast_addresses() {
        assert_eq!(
            normalize_hardware_address([0x8a, 0x01, 0x23, 0x45, 0x67, 0x89]),
            Some("8A0123456789".into())
        );
        assert_eq!(normalize_hardware_address([0; 6]), None);
        assert_eq!(normalize_hardware_address([0xff; 6]), None);
        assert_eq!(normalize_hardware_address([1, 2, 3, 4, 5, 6]), None);
        assert_eq!(normalize_hardware_address([2, 0, 0, 0, 0, 0]), None);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn missing_adapter_never_uses_another_devices_address() {
        assert_eq!(interface_hardware_address("fusionplay-nonexistent"), None);
        assert_eq!(interface_hardware_address("lo0"), None);
    }
}
