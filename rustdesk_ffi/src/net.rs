//! TCP endpoint parsing and DNS-aware connection helpers for RustDesk.

use std::io;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, TcpStream, ToSocketAddrs};
use std::str::FromStr;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

const MAX_ENDPOINT_LENGTH: usize = 512;
const CONNECT_CANCEL_SLICE: Duration = Duration::from_millis(200);

#[derive(Debug, Clone, PartialEq, Eq)]
struct ParsedEndpoint {
    host: String,
    port: u16,
}

/// Connect to a host and port, resolving DNS and trying every candidate address.
pub(crate) fn connect_tcp_host(
    host: &str,
    port: u16,
    stage: &str,
    timeout: Duration,
) -> io::Result<TcpStream> {
    connect_tcp_host_inner(host, port, stage, timeout, None)
}

/// Connect with the session-scoped cancellation epoch used by desktop and
/// file-transfer connection attempts.
pub(crate) fn connect_tcp_host_cancellable(
    host: &str,
    port: u16,
    stage: &str,
    timeout: Duration,
    cancel_epoch: u64,
) -> io::Result<TcpStream> {
    connect_tcp_host_inner(host, port, stage, timeout, Some(cancel_epoch))
}

fn connect_tcp_host_inner(
    host: &str,
    port: u16,
    stage: &str,
    timeout: Duration,
    cancel_epoch: Option<u64>,
) -> io::Result<TcpStream> {
    let host = canonicalize_tcp_host(host, stage)?;
    validate_port(port, stage, &host)?;
    connect_parsed_endpoint(ParsedEndpoint { host, port }, stage, timeout, cancel_epoch)
}

/// Connect to an endpoint that may contain an explicit port.
pub(crate) fn connect_tcp_endpoint(
    endpoint: &str,
    default_port: u16,
    stage: &str,
    timeout: Duration,
) -> io::Result<TcpStream> {
    let parsed = parse_endpoint(endpoint, default_port, stage)?;
    connect_parsed_endpoint(parsed, stage, timeout, None)
}

pub(crate) fn connect_tcp_endpoint_cancellable(
    endpoint: &str,
    default_port: u16,
    stage: &str,
    timeout: Duration,
    cancel_epoch: u64,
) -> io::Result<TcpStream> {
    let parsed = parse_endpoint(endpoint, default_port, stage)?;
    connect_parsed_endpoint(parsed, stage, timeout, Some(cancel_epoch))
}

pub(crate) fn connect_tcp_socket_address_cancellable(
    address: &std::net::SocketAddr,
    stage: &str,
    timeout: Duration,
    cancel_epoch: u64,
) -> io::Result<TcpStream> {
    let endpoint_id = crate::safe_diagnostics::sensitive_id(&address.to_string());
    let deadline = Instant::now() + timeout;
    connect_candidate(address, deadline, Some(cancel_epoch), stage, &endpoint_id)
}

pub(crate) fn canonicalize_tcp_host(host: &str, stage: &str) -> io::Result<String> {
    validate_endpoint_text(host, stage, "host")?;
    if host.starts_with('[') || host.ends_with(']') {
        if host.starts_with('[') && host.ends_with(']') && host.len() > 2 {
            return canonicalize_bracketed_ipv6(&host[1..host.len() - 1], stage, host);
        }
        return Err(invalid_endpoint(stage, host, "invalid bracketed host"));
    }
    if host.contains(':') && host.parse::<std::net::SocketAddr>().is_ok() {
        return Err(invalid_endpoint(
            stage,
            host,
            "host must not include a port; pass port separately",
        ));
    }
    canonicalize_host(host, stage, host)
}

fn parse_endpoint(endpoint: &str, default_port: u16, stage: &str) -> io::Result<ParsedEndpoint> {
    validate_endpoint_text(endpoint, stage, "endpoint")?;

    if endpoint.starts_with('[') {
        let close = endpoint.find(']').ok_or_else(|| {
            invalid_endpoint(stage, endpoint, "missing closing bracket for IPv6 host")
        })?;
        let host = canonicalize_bracketed_ipv6(&endpoint[1..close], stage, endpoint)?;
        let suffix = &endpoint[close + 1..];
        let port = if suffix.is_empty() {
            default_port
        } else if let Some(port_text) = suffix.strip_prefix(':') {
            parse_port(port_text, stage, endpoint)?
        } else {
            return Err(invalid_endpoint(
                stage,
                endpoint,
                "unexpected text after bracketed IPv6 host",
            ));
        };
        return Ok(ParsedEndpoint { host, port });
    }

    let colon_count = endpoint.chars().filter(|c| *c == ':').count();
    if colon_count == 0 {
        return Ok(ParsedEndpoint {
            host: canonicalize_host(endpoint, stage, endpoint)?,
            port: default_port,
        });
    }
    if colon_count == 1 {
        let (host, port_text) = endpoint.split_once(':').expect("one colon must split");
        if host.is_empty() {
            return Err(invalid_endpoint(stage, endpoint, "host is empty"));
        }
        return Ok(ParsedEndpoint {
            host: canonicalize_host(host, stage, endpoint)?,
            port: parse_port(port_text, stage, endpoint)?,
        });
    }

    // An unbracketed multi-colon value is accepted only as a raw IPv6 host;
    // an explicit IPv6 port must use [addr]:port to remain unambiguous.
    if Ipv6Addr::from_str(endpoint).is_ok() {
        return Ok(ParsedEndpoint {
            host: canonicalize_host(endpoint, stage, endpoint)?,
            port: default_port,
        });
    }
    Err(invalid_endpoint(
        stage,
        endpoint,
        "IPv6 endpoints with an explicit port must use [addr]:port",
    ))
}

fn validate_endpoint_text(value: &str, stage: &str, kind: &str) -> io::Result<()> {
    if value.is_empty() {
        return Err(invalid_endpoint(
            stage,
            value,
            &format!("{} is empty", kind),
        ));
    }
    if value.len() > MAX_ENDPOINT_LENGTH {
        return Err(invalid_endpoint(
            stage,
            value,
            "endpoint exceeds maximum length",
        ));
    }
    if has_uri_or_path(value)
        || value
            .as_bytes()
            .iter()
            .any(|byte| *byte < 0x21 || *byte > 0x7e)
    {
        return Err(invalid_endpoint(
            stage,
            value,
            "URL syntax, paths, whitespace, and non-ASCII text are not valid TCP endpoints",
        ));
    }
    Ok(())
}

fn canonicalize_bracketed_ipv6(host: &str, stage: &str, original: &str) -> io::Result<String> {
    if host.is_empty() {
        return Err(invalid_endpoint(stage, original, "IPv6 host is empty"));
    }
    let canonical = canonicalize_host(host, stage, original)?;
    if canonical.parse::<Ipv6Addr>().is_err() {
        return Err(invalid_endpoint(
            stage,
            original,
            "brackets are valid only for IPv6 hosts",
        ));
    }
    Ok(canonical)
}

fn canonicalize_host(host: &str, stage: &str, original: &str) -> io::Result<String> {
    if host.is_empty() {
        return Err(invalid_endpoint(stage, original, "host is empty"));
    }
    if host.contains('%') {
        return Err(invalid_endpoint(
            stage,
            original,
            "scoped IPv6 addresses are not supported by this transport",
        ));
    }

    if let Ok(ipv4) = host.parse::<Ipv4Addr>() {
        let first = ipv4.octets()[0];
        if first == 0 || first >= 224 {
            return Err(invalid_endpoint(
                stage,
                original,
                "IPv4 address is not connectable",
            ));
        }
        return Ok(ipv4.to_string());
    }

    if let Ok(ipv6) = host.parse::<Ipv6Addr>() {
        let octets = ipv6.octets();
        let ipv4_mapped =
            octets[..10].iter().all(|byte| *byte == 0) && octets[10] == 0xff && octets[11] == 0xff;
        let link_local = octets[0] == 0xfe && (octets[1] & 0xc0) == 0x80;
        if ipv6.is_unspecified() || ipv6.is_multicast() || ipv4_mapped || link_local {
            return Err(invalid_endpoint(
                stage,
                original,
                "IPv6 address is not connectable by this transport",
            ));
        }
        return Ok(ipv6.to_string());
    }

    if host.contains(':') {
        return Err(invalid_endpoint(stage, original, "invalid IPv6 host"));
    }
    if legacy_numeric_host(host) {
        return Err(invalid_endpoint(stage, original, "invalid IPv4 host"));
    }

    let hostname = host.strip_suffix('.').unwrap_or(host);
    if hostname.is_empty()
        || hostname.len() > 253
        || hostname.starts_with('.')
        || hostname.ends_with('.')
        || hostname.contains("..")
    {
        return Err(invalid_endpoint(stage, original, "invalid DNS hostname"));
    }
    for label in hostname.split('.') {
        if label.is_empty()
            || label.len() > 63
            || label.starts_with('-')
            || label.ends_with('-')
            || !label
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        {
            return Err(invalid_endpoint(stage, original, "invalid DNS hostname"));
        }
    }
    Ok(hostname.to_ascii_lowercase())
}

fn legacy_numeric_host(host: &str) -> bool {
    let value = host.strip_suffix('.').unwrap_or(host);
    if !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte == b'.' || byte.is_ascii_digit())
    {
        return true;
    }
    !value.is_empty()
        && value.split('.').all(|label| {
            !label.is_empty()
                && (label.bytes().all(|byte| byte.is_ascii_digit())
                    || (label.len() > 2
                        && (label.starts_with("0x") || label.starts_with("0X"))
                        && label[2..].bytes().all(|byte| byte.is_ascii_hexdigit())))
        })
}

fn parse_port(port_text: &str, stage: &str, endpoint: &str) -> io::Result<u16> {
    let port = port_text.parse::<u16>().map_err(|_| {
        invalid_endpoint(
            stage,
            endpoint,
            "port must be an integer between 1 and 65535",
        )
    })?;
    validate_port(port, stage, endpoint)
}

fn validate_port(port: u16, stage: &str, endpoint: &str) -> io::Result<u16> {
    if port == 0 {
        return Err(invalid_endpoint(
            stage,
            endpoint,
            "port must be an integer between 1 and 65535",
        ));
    }
    Ok(port)
}

fn has_uri_or_path(value: &str) -> bool {
    value.contains("://")
        || value.contains('/')
        || value.contains('\\')
        || value.contains('@')
        || value.contains('?')
        || value.contains('#')
}

fn invalid_endpoint(stage: &str, endpoint: &str, reason: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        format!(
            "{} endpoint invalid endpoint_id={} reason={}",
            stage,
            crate::safe_diagnostics::sensitive_id(endpoint),
            reason
        ),
    )
}

fn connect_parsed_endpoint(
    endpoint: ParsedEndpoint,
    stage: &str,
    timeout: Duration,
    cancel_epoch: Option<u64>,
) -> io::Result<TcpStream> {
    connect_parsed_endpoint_with_resolver(endpoint, stage, timeout, cancel_epoch, |host, port| {
        (host.as_str(), port)
            .to_socket_addrs()
            .map(|values| values.collect())
    })
}

fn connect_parsed_endpoint_with_resolver<F>(
    endpoint: ParsedEndpoint,
    stage: &str,
    timeout: Duration,
    cancel_epoch: Option<u64>,
    resolver: F,
) -> io::Result<TcpStream>
where
    F: FnOnce(String, u16) -> io::Result<Vec<SocketAddr>> + Send + 'static,
{
    let endpoint_id =
        crate::safe_diagnostics::sensitive_id(&format!("{}:{}", endpoint.host, endpoint.port));
    let deadline = Instant::now() + timeout;
    ensure_not_cancelled(cancel_epoch, stage, &endpoint_id)?;
    let resolve_host = endpoint.host.clone();
    let resolve_port = endpoint.port;
    let candidates = run_blocking_operation(
        deadline,
        cancel_epoch,
        stage,
        &endpoint_id,
        "resolve",
        move || resolver(resolve_host, resolve_port),
    )
    .map_err(|error| {
        io::Error::new(
            if matches!(
                error.kind(),
                io::ErrorKind::Interrupted | io::ErrorKind::TimedOut
            ) {
                error.kind()
            } else {
                io::ErrorKind::AddrNotAvailable
            },
            format!(
                "{} resolve failed endpoint_id={} error_kind={:?}",
                stage,
                endpoint_id,
                error.kind()
            ),
        )
    })?;
    if candidates.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::AddrNotAvailable,
            format!(
                "{} resolve returned no addresses endpoint_id={}",
                stage, endpoint_id
            ),
        ));
    }
    eprintln!(
        "[RustDesk-FFI] {} resolved endpoint_id={} addresses={}",
        stage,
        endpoint_id,
        candidates.len()
    );

    let mut last_error = None;
    let candidate_count = candidates.len();
    for (index, address) in candidates.into_iter().enumerate() {
        ensure_not_cancelled(cancel_epoch, stage, &endpoint_id)?;
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        // M1 remains sequential, but one unreachable candidate must not consume
        // the entire shared deadline and starve the remaining A/AAAA results.
        // M2 will replace this fair sequential budget with Happy Eyeballs racing.
        let candidates_left = candidate_count.saturating_sub(index).max(1) as u32;
        let candidate_budget = remaining / candidates_left;
        let candidate_deadline = Instant::now() + candidate_budget.max(CONNECT_CANCEL_SLICE);
        match connect_candidate(
            &address,
            candidate_deadline.min(deadline),
            cancel_epoch,
            stage,
            &endpoint_id,
        ) {
            Ok(stream) => {
                eprintln!(
                    "[RustDesk-FFI] {} connected endpoint_id={}",
                    stage, endpoint_id
                );
                return Ok(stream);
            }
            Err(error) => last_error = Some(error),
        }
    }

    let error = match last_error {
        Some(value) => value,
        None => {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!("{} connect timed out endpoint_id={}", stage, endpoint_id),
            ));
        }
    };
    Err(io::Error::new(
        error.kind(),
        format!(
            "{} connect failed endpoint_id={} error_kind={:?}",
            stage,
            endpoint_id,
            error.kind()
        ),
    ))
}

fn connect_candidate(
    address: &SocketAddr,
    deadline: Instant,
    cancel_epoch: Option<u64>,
    stage: &str,
    endpoint_id: &str,
) -> io::Result<TcpStream> {
    let address = *address;
    let connect_timeout = deadline.saturating_duration_since(Instant::now());
    if connect_timeout.is_zero() {
        return Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "candidate timed out",
        ));
    }
    run_blocking_operation(
        deadline,
        cancel_epoch,
        stage,
        endpoint_id,
        "connect",
        move || TcpStream::connect_timeout(&address, connect_timeout),
    )
}

fn run_blocking_operation<T, F>(
    deadline: Instant,
    cancel_epoch: Option<u64>,
    stage: &str,
    endpoint_id: &str,
    operation: &str,
    task: F,
) -> io::Result<T>
where
    T: Send + 'static,
    F: FnOnce() -> io::Result<T> + Send + 'static,
{
    ensure_not_cancelled(cancel_epoch, stage, endpoint_id)?;
    if deadline.saturating_duration_since(Instant::now()).is_zero() {
        return Err(io::Error::new(
            io::ErrorKind::TimedOut,
            format!(
                "{} {} timed out endpoint_id={}",
                stage, operation, endpoint_id
            ),
        ));
    }
    let (sender, receiver) = mpsc::sync_channel(1);
    thread::Builder::new()
        .name(format!("rustdesk-{}", operation))
        .spawn(move || {
            let _ = sender.send(task());
        })
        .map_err(|error| {
            io::Error::new(
                error.kind(),
                format!(
                    "{} {} worker start failed endpoint_id={}",
                    stage, operation, endpoint_id
                ),
            )
        })?;

    loop {
        ensure_not_cancelled(cancel_epoch, stage, endpoint_id)?;
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!(
                    "{} {} timed out endpoint_id={}",
                    stage, operation, endpoint_id
                ),
            ));
        }
        match receiver.recv_timeout(remaining.min(CONNECT_CANCEL_SLICE)) {
            Ok(result) => return result,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err(io::Error::new(
                    io::ErrorKind::Other,
                    format!(
                        "{} {} worker stopped endpoint_id={}",
                        stage, operation, endpoint_id
                    ),
                ));
            }
        }
    }
}

fn ensure_not_cancelled(
    cancel_epoch: Option<u64>,
    stage: &str,
    endpoint_id: &str,
) -> io::Result<()> {
    if cancel_epoch.is_some_and(crate::connect_cancelled) {
        return Err(io::Error::new(
            io::ErrorKind::Interrupted,
            format!("{} connect cancelled endpoint_id={}", stage, endpoint_id),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    #[test]
    fn parse_endpoint_supports_hostname_and_explicit_port() {
        assert_eq!(
            parse_endpoint("HBBS.Example.COM.:21116", 21117, "test").unwrap(),
            ParsedEndpoint {
                host: "hbbs.example.com".to_string(),
                port: 21116,
            }
        );
    }

    #[test]
    fn parse_endpoint_supports_bracketed_ipv6() {
        assert_eq!(
            parse_endpoint("[::1]:21117", 21116, "test").unwrap(),
            ParsedEndpoint {
                host: "::1".to_string(),
                port: 21117,
            }
        );
    }

    #[test]
    fn parse_endpoint_supports_raw_ipv6_with_default_port() {
        assert_eq!(
            parse_endpoint("2001:0db8:0:0:0:0:0:1", 21116, "test").unwrap(),
            ParsedEndpoint {
                host: "2001:db8::1".to_string(),
                port: 21116,
            }
        );
    }

    #[test]
    fn parse_endpoint_rejects_zero_port() {
        let error = parse_endpoint("hbbs.example.com:0", 21116, "test").unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        assert!(error.to_string().contains("between 1 and 65535"));
    }

    #[test]
    fn parse_endpoint_rejects_url_scheme() {
        let error = parse_endpoint("https://hbbs.example.com", 21116, "test").unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        assert!(error.to_string().contains("URL syntax"));
        assert!(!error.to_string().contains("hbbs.example.com"));
        assert!(!error.to_string().contains("https://"));
        assert!(error.to_string().contains("endpoint_id="));
    }

    #[test]
    fn parse_endpoint_rejects_non_canonical_or_unsafe_inputs() {
        for endpoint in [
            " hbbs.example.com",
            "hbbs.example.com ",
            "user@hbbs.example.com",
            "127.1",
            "0x7f.0.0.1",
            "224.0.0.1",
            "[::]",
            "[::ffff:192.0.2.1]",
            "[ff02::1]",
            "[fe80::1%en0]",
        ] {
            let error = parse_endpoint(endpoint, 21116, "test").unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::InvalidInput, "{endpoint}");
            assert!(error.to_string().contains("endpoint_id="), "{endpoint}");
        }
    }

    #[test]
    fn canonicalize_tcp_host_rejects_embedded_port_and_non_ipv6_brackets() {
        assert!(canonicalize_tcp_host("hbbs.example.com:21116", "test").is_err());
        assert!(canonicalize_tcp_host("[hbbs.example.com]", "test").is_err());
    }

    #[test]
    fn cancellable_connect_observes_session_epoch_before_network_io() {
        let epoch = crate::begin_connect_epoch(9001);
        crate::cancel_pending_connect_for_session(9001);
        let error =
            connect_tcp_host_cancellable("127.0.0.1", 9, "test", Duration::from_secs(1), epoch)
                .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Interrupted);
        assert!(error.to_string().contains("connect cancelled"));
        crate::finish_connect_epoch(epoch, 9001);
    }

    #[test]
    fn aaaa_only_resolution_connects_to_ipv6_loopback() {
        let listener = match TcpListener::bind("[::1]:0") {
            Ok(value) => value,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::AddrNotAvailable | io::ErrorKind::PermissionDenied
                ) =>
            {
                return;
            }
            Err(error) => panic!("IPv6 loopback bind failed: {error}"),
        };
        let address = listener.local_addr().unwrap();
        assert!(address.is_ipv6());
        let accepter = thread::spawn(move || listener.accept().unwrap());
        let stream = connect_parsed_endpoint_with_resolver(
            ParsedEndpoint {
                host: "aaaa-only.example.test".to_string(),
                port: address.port(),
            },
            "test-aaaa",
            Duration::from_secs(2),
            None,
            move |host, port| {
                assert_eq!(host, "aaaa-only.example.test");
                assert_eq!(port, address.port());
                Ok(vec![address])
            },
        )
        .expect("AAAA-only candidate should connect over IPv6");
        assert!(stream.peer_addr().unwrap().is_ipv6());
        drop(stream);
        accepter.join().unwrap();
    }

    #[test]
    fn slow_resolution_is_bounded_by_the_shared_deadline() {
        let invocations = Arc::new(AtomicUsize::new(0));
        let worker_invocations = Arc::clone(&invocations);
        let started = Instant::now();
        let error = connect_parsed_endpoint_with_resolver(
            ParsedEndpoint {
                host: "slow-resolver.example.test".to_string(),
                port: 21116,
            },
            "test-resolve-timeout",
            Duration::from_millis(80),
            None,
            move |_, _| {
                worker_invocations.fetch_add(1, Ordering::SeqCst);
                thread::sleep(Duration::from_millis(300));
                Ok(Vec::new())
            },
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_millis(250));
        assert_eq!(invocations.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn cancellable_blocking_operation_starts_the_dialer_once() {
        let session_id = 9002;
        let epoch = crate::begin_connect_epoch(session_id);
        let invocations = Arc::new(AtomicUsize::new(0));
        let worker_invocations = Arc::clone(&invocations);
        let canceller = thread::spawn(move || {
            thread::sleep(Duration::from_millis(40));
            crate::cancel_pending_connect_for_session(session_id);
        });
        let started = Instant::now();
        let error = run_blocking_operation(
            Instant::now() + Duration::from_secs(2),
            Some(epoch),
            "test-cancel",
            "test-endpoint",
            "connect",
            move || {
                worker_invocations.fetch_add(1, Ordering::SeqCst);
                thread::sleep(Duration::from_millis(400));
                Ok(())
            },
        )
        .unwrap_err();
        canceller.join().unwrap();
        assert_eq!(error.kind(), io::ErrorKind::Interrupted);
        assert!(started.elapsed() < Duration::from_millis(600));
        assert_eq!(invocations.load(Ordering::SeqCst), 1);
        crate::finish_connect_epoch(epoch, session_id);
    }
}
