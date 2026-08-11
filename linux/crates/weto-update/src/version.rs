//! Семантическая версия ровно в том объёме, который нужен обновлению.

use std::cmp::Ordering;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Version {
    pub major: u32,
    pub minor: u32,
    pub patch: u32,
}

impl Version {
    /// Ведущая `v` отсекается: теги пишут `v1.2.3`, а релизы отдают то же
    /// самое без неё, и разбирать оба вида должен один код.
    pub fn parse(text: &str) -> Option<Version> {
        let trimmed = text.trim().trim_start_matches('v');
        let mut parts = trimmed.split('.');

        let version = Version {
            major: parts.next()?.parse().ok()?,
            minor: parts.next()?.parse().ok()?,
            patch: parts.next()?.parse().ok()?,
        };
        if parts.next().is_some() {
            return None;
        }
        Some(version)
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

impl Ord for Version {
    fn cmp(&self, other: &Self) -> Ordering {
        (self.major, self.minor, self.patch).cmp(&(other.major, other.minor, other.patch))
    }
}

impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_and_bare_versions_parse_the_same() {
        assert_eq!(Version::parse("v1.2.3"), Version::parse("1.2.3"));
        assert_eq!(Version::parse("1.2.3").unwrap().to_string(), "1.2.3");
    }

    #[test]
    fn comparison_goes_component_by_component() {
        let older = Version::parse("0.9.9").unwrap();
        let newer = Version::parse("0.10.0").unwrap();

        assert!(newer > older, "минор сравнивается числом, а не строкой");
        assert!(Version::parse("1.0.0").unwrap() > newer);
        assert_eq!(Version::parse("1.0.0"), Version::parse("1.0.0"));
    }

    #[test]
    fn malformed_versions_are_rejected() {
        assert!(Version::parse("").is_none());
        assert!(Version::parse("1.2").is_none());
        assert!(Version::parse("1.2.3.4").is_none());
        assert!(Version::parse("1.2.x").is_none());
    }
}
