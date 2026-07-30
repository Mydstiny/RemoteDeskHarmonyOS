//! Stable, non-reversible identifiers for values that must never be emitted
//! verbatim in diagnostics (peer IDs, endpoints, paths, account data, keys).

use sha2::{Digest, Sha256};

pub(crate) fn sensitive_id(value: &str) -> String {
    let digest = Sha256::digest(value.as_bytes());
    let mut result = String::with_capacity(12);
    for byte in digest.iter().take(6) {
        use std::fmt::Write as _;
        let _ = write!(&mut result, "{byte:02x}");
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sensitive_ids_are_stable_and_do_not_reveal_the_source() {
        let source = r"C:\Users\Alice\Secret\quarterly-plan.txt";
        let first = sensitive_id(source);
        assert_eq!(first, sensitive_id(source));
        assert_ne!(first, sensitive_id("different"));
        assert_eq!(first.len(), 12);
        assert!(!first.contains("Alice"));
        assert!(!first.contains("quarterly"));
        assert!(!first.contains('\\'));
    }
}
