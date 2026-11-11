//! Поднятые интерфейсы Windows.
//!
//! Имя — `FriendlyName` адаптера («Wi-Fi», «Ethernet», имя туннеля WireGuard):
//! тем же именем интерфейс называет проба маршрута (`if-addrs` на Windows
//! берёт `FriendlyName`), и разойтись им нельзя — туннель, названный
//! пользователем, сверяется по этому имени.
//!
//! «Поднят» — `OperStatus == IfOperStatusUp`: адаптер включён и несёт трафик.
//! Включённый адаптер туннеля, чей процесс умер, этот статус теряет.

use windows_sys::Win32::Foundation::{ERROR_BUFFER_OVERFLOW, ERROR_SUCCESS};
use windows_sys::Win32::NetworkManagement::IpHelper::{
    GetAdaptersAddresses, GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_DNS_SERVER, GAA_FLAG_SKIP_MULTICAST,
    IP_ADAPTER_ADDRESSES_LH,
};
use windows_sys::Win32::NetworkManagement::Ndis::IfOperStatusUp;
use windows_sys::Win32::Networking::WinSock::AF_UNSPEC;

use weto_sys::network_snapshot::InterfaceListing;

use crate::wide;

#[derive(Debug, Default, Clone, Copy)]
pub struct AdapterInterfaces;

impl InterfaceListing for AdapterInterfaces {
    fn up_interfaces(&self) -> Vec<String> {
        let mut names = Vec::new();
        let Some(buffer) = adapters() else {
            return names;
        };
        let mut cursor = buffer.as_ptr().cast::<IP_ADAPTER_ADDRESSES_LH>();
        while !cursor.is_null() {
            // SAFETY: узел списка, записанного `GetAdaptersAddresses` в наш буфер,
            // который жив до конца функции.
            let adapter = unsafe { &*cursor };
            if adapter.OperStatus == IfOperStatusUp {
                // SAFETY: `FriendlyName` — строка с нулём внутри того же буфера.
                let name = unsafe { wide::from_pointer(adapter.FriendlyName) };
                if !name.is_empty() && !names.contains(&name) {
                    names.push(name);
                }
            }
            cursor = adapter.Next;
        }
        names
    }
}

/// Буфер со списком адаптеров. Выровнен по 8 байтам — структуры в нём
/// содержат 64-битные поля и читаются по ссылке.
fn adapters() -> Option<Vec<u64>> {
    let flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
    let mut size: u32 = 16 * 1024;
    for _ in 0..4 {
        let mut buffer = vec![0u64; (size as usize).div_ceil(8)];
        // SAFETY: буфер наш и не короче `size` байт.
        let status = unsafe {
            GetAdaptersAddresses(
                AF_UNSPEC as u32,
                flags,
                std::ptr::null(),
                buffer.as_mut_ptr().cast(),
                &mut size,
            )
        };
        match status {
            ERROR_SUCCESS => return Some(buffer),
            ERROR_BUFFER_OVERFLOW => continue,
            _ => return None,
        }
    }
    None
}
