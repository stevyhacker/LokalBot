//! Release versions: the macOS marketing version (`0.10.11`), which the Linux
//! and Windows workspace repeats so one tag ships all three platforms.

use std::fmt;
use std::str::FromStr;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Version {
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
}

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
#[error("{0:?} is not a version like 0.10.11")]
pub struct InvalidVersion(pub String);

impl Version {
    pub const fn new(major: u64, minor: u64, patch: u64) -> Self {
        Self {
            major,
            minor,
            patch,
        }
    }

    /// The version of this build.
    pub fn current() -> Self {
        env!("CARGO_PKG_VERSION")
            .parse()
            .expect("the workspace version has the form 0.10.11")
    }
}

impl FromStr for Version {
    type Err = InvalidVersion;

    /// Exactly three decimal numbers, as `release-preflight.py` requires of
    /// the marketing version. Pre-release tags never reach a feed.
    fn from_str(text: &str) -> Result<Self, Self::Err> {
        let invalid = || InvalidVersion(text.to_string());
        let mut parts = text.split('.');
        let mut next = || -> Result<u64, InvalidVersion> {
            let part = parts.next().ok_or_else(invalid)?;
            if part.is_empty() || part.len() > 9 || !part.bytes().all(|b| b.is_ascii_digit()) {
                return Err(invalid());
            }
            part.parse().map_err(|_| invalid())
        };
        let version = Version::new(next()?, next()?, next()?);
        if parts.next().is_some() {
            return Err(invalid());
        }
        Ok(version)
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_orders_numerically() {
        let v = |s: &str| s.parse::<Version>().unwrap();
        assert_eq!(v("0.10.11"), Version::new(0, 10, 11));
        assert!(v("0.10.11") > v("0.10.9"));
        assert!(v("0.11.0") > v("0.10.99"));
        assert!(v("1.0.0") > v("0.99.99"));
        assert_eq!(v("0.10.10").to_string(), "0.10.10");
    }

    #[test]
    fn rejects_anything_else() {
        for text in [
            "",
            "1",
            "1.2",
            "1.2.3.4",
            "v1.2.3",
            "1.2.3-beta",
            "1..3",
            "1.2.x",
            " 1.2.3",
            "1.2.+3",
            "1.2.3 ",
            "1234567890.0.0",
        ] {
            assert!(text.parse::<Version>().is_err(), "{text:?}");
        }
    }

    #[test]
    fn this_build_has_a_release_version() {
        assert!(Version::current() >= Version::new(0, 10, 10));
    }
}
