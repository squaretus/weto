//! Разбор и проверка текстового IP-адреса и CIDR-диапазона.
//!
//! Порт `IPAddress` и `IPRange` из macOS-версии. Нужен не только чёрному списку:
//! строку, пришедшую от ipinfo, нельзя подставлять в URL подтверждающих сервисов
//! без проверки.

use serde::{Deserialize, Serialize};
use std::net::IpAddr;
use std::str::FromStr;

/// Разбирает текстовый адрес в байты и признак семейства.
///
/// Строгость обязательна: `Ipv4Addr::from_str` отвергает и лишние октеты,
/// и ведущие нули, и мусор после адреса — ровно как `inet_pton` на macOS.
pub fn parse_address(text: &str) -> Option<(Vec<u8>, bool)> {
    match IpAddr::from_str(text.trim()) {
        Ok(IpAddr::V4(v4)) => Some((v4.octets().to_vec(), false)),
        Ok(IpAddr::V6(v6)) => Some((v6.octets().to_vec(), true)),
        Err(_) => None,
    }
}

/// Проверка без разбора — для мест, где нужен только ответ «адрес ли это».
pub fn is_valid_address(text: &str) -> bool {
    parse_address(text).is_some()
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct IpRange {
    pub network_bytes: Vec<u8>,
    pub prefix_length: u8,
    pub is_ipv6: bool,
    pub text: String,
}

impl IpRange {
    pub fn parse(text: &str) -> Option<IpRange> {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return None;
        }

        let mut parts = trimmed.split('/');
        let address = parts.next()?;
        let prefix_part = parts.next();
        if parts.next().is_some() {
            return None;
        }

        let (bytes, is_ipv6) = parse_address(address)?;
        let max_prefix: u8 = if is_ipv6 { 128 } else { 32 };

        // Голый адрес — это диапазон из одного адреса, а не «весь интернет».
        let prefix_length = match prefix_part {
            None => max_prefix,
            Some(raw) => {
                let parsed: u8 = raw.parse().ok()?;
                if parsed > max_prefix {
                    return None;
                }
                parsed
            }
        };

        Some(IpRange {
            network_bytes: masked(&bytes, prefix_length),
            prefix_length,
            is_ipv6,
            text: trimmed.to_string(),
        })
    }

    pub fn contains(&self, ip: &str) -> bool {
        match parse_address(ip) {
            Some((bytes, is_ipv6)) if is_ipv6 == self.is_ipv6 => {
                masked(&bytes, self.prefix_length) == self.network_bytes
            }
            _ => false,
        }
    }
}

/// Обнуляет биты за пределами префикса, чтобы `10.5.5.5/8` и `10.0.0.0/8`
/// давали одну и ту же сеть.
fn masked(bytes: &[u8], prefix_length: u8) -> Vec<u8> {
    let prefix = usize::from(prefix_length);
    bytes
        .iter()
        .enumerate()
        .map(|(index, byte)| {
            let bits_before = index * 8;
            if prefix >= bits_before + 8 {
                *byte
            } else if prefix <= bits_before {
                0
            } else {
                let keep = prefix - bits_before;
                *byte & (0xFFu8 << (8 - keep))
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bare_ipv4_matches_only_itself() {
        let range = IpRange::parse("203.0.113.28").unwrap();
        assert_eq!(range.prefix_length, 32);
        assert!(range.contains("203.0.113.28"));
        assert!(!range.contains("203.0.113.29"));
    }

    #[test]
    fn ipv4_prefix_matches_whole_subnet() {
        let range = IpRange::parse("10.0.0.0/8").unwrap();
        assert!(range.contains("10.0.0.1"));
        assert!(range.contains("10.255.255.255"));
        assert!(!range.contains("11.0.0.1"));
        assert!(!range.contains("9.255.255.255"));
    }

    #[test]
    fn non_byte_aligned_prefix_is_respected() {
        let range = IpRange::parse("192.168.0.0/20").unwrap();
        assert!(range.contains("192.168.15.255"));
        assert!(!range.contains("192.168.16.0"));
    }

    #[test]
    fn zero_prefix_matches_every_address_of_same_family() {
        let range = IpRange::parse("0.0.0.0/0").unwrap();
        assert!(range.contains("1.2.3.4"));
        assert!(range.contains("255.255.255.255"));
        assert!(!range.contains("2606:2040::1"));
    }

    #[test]
    fn host_bits_outside_prefix_are_ignored() {
        assert_eq!(
            IpRange::parse("10.5.5.5/8").unwrap().network_bytes,
            IpRange::parse("10.0.0.0/8").unwrap().network_bytes
        );
    }

    #[test]
    fn ipv6_prefix_is_supported() {
        let range = IpRange::parse("2606:2040::/32").unwrap();
        assert!(range.contains("2606:2040::1"));
        assert!(!range.contains("2606:2041::1"));
        assert!(!range.contains("1.2.3.4"));
    }

    #[test]
    fn malformed_input_is_rejected() {
        assert!(IpRange::parse("").is_none());
        assert!(IpRange::parse("10.0.0.0/33").is_none());
        assert!(IpRange::parse("10.0.0.0/-1").is_none());
        assert!(IpRange::parse("10.0.0.0/8/8").is_none());
        assert!(IpRange::parse("не адрес").is_none());
    }

    /// Строка приходит из сети и уезжает в URL подтверждающего сервиса.
    /// Проверять её обязательно, и проверка обязана быть строгой.
    #[test]
    fn address_from_the_network_is_validated_not_trusted() {
        assert!(parse_address("1.2.3.4").is_some());
        assert!(parse_address("2001:db8::1").is_some());
        assert!(parse_address("1.2.3.4/../../etc/passwd").is_none());
        assert!(parse_address("1.2.3.4 ").is_some(), "пробелы по краям отсекаются");
        assert!(parse_address("1.2.3.4.5").is_none());
    }
}
