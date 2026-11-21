pub const MINIMUM_MS: u64 = 20;
pub const MAX_BACKOFF_MS: u64 = 600;

pub fn milliseconds(last_latency_ms: Option<u64>, configured_ms: u64, consumed_ms: u64) -> u64 {
    let fallback = configured_ms.max(MINIMUM_MS);
    let total = match last_latency_ms {
        Some(last) if last > 0 => fallback.max((last / 2).min(MAX_BACKOFF_MS)),
        _ => fallback,
    };
    total.saturating_sub(consumed_ms)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn follows_the_model_server_profile() {
        assert_eq!(milliseconds(None, 20, 0), 20);
        assert_eq!(milliseconds(None, 5, 0), 20);
        assert_eq!(milliseconds(None, 150, 0), 150);
        assert_eq!(milliseconds(Some(120), 150, 0), 150);
        assert_eq!(milliseconds(Some(800), 150, 0), 400);
        assert_eq!(milliseconds(Some(4_000), 150, 0), 600);
        assert_eq!(milliseconds(None, 150, 40), 110);
        assert_eq!(milliseconds(Some(200), 150, 400), 0);
    }
}
