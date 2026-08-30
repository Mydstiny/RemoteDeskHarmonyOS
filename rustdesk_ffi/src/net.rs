//! TCP endpoint parsing and DNS-aware connection helpers for RustDesk.

use std::ffi::CString;
use std::io;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV6, TcpStream, ToSocketAddrs};
use std::os::fd::{FromRawFd, RawFd};
use std::str::FromStr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

const MAX_ENDPOINT_LENGTH: usize = 512;
const CONNECT_CANCEL_SLICE: Duration = Duration::from_millis(200);
const CONNECT_POLL_SLICE: Duration = Duration::from_millis(50);
const HAPPY_EYEBALLS_DELAY: Duration = Duration::from_millis(250);
const MAX_CONNECT_CANDIDATES: usize = 16;
const MAX_RESOLVER_WORKERS: usize = 8;
static ACTIVE_RESOLVER_WORKERS: AtomicUsize = AtomicUsize::new(0);

#[derive(Debug)]
struct ResolverWorkerPermit {
    counter: &'static AtomicUsize,
}

impl ResolverWorkerPermit {
    fn acquire(counter: &'static AtomicUsize, limit: usize) -> io::Result<Self> {
        let mut active = counter.load(Ordering::Acquire);
        loop {
            if active >= limit {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "resolver worker limit reached",
                ));
            }
            match counter.compare_exchange_weak(
                active,
                active + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return Ok(Self { counter }),
                Err(actual) => active = actual,
            }
        }
    }
}

impl Drop for ResolverWorkerPermit {
    fn drop(&mut self) {
        self.counter.fetch_sub(1, Ordering::AcqRel);
    }
}

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
    connect_tcp_socket_addresses_cancellable(&[*address], stage, timeout, cancel_epoch)
}

pub(crate) fn connect_tcp_socket_addresses_cancellable(
    addresses: &[SocketAddr],
    stage: &str,
    timeout: Duration,
    cancel_epoch: u64,
) -> io::Result<TcpStream> {
    connect_tcp_socket_addresses_inner(addresses, None, stage, timeout, cancel_epoch)
}

pub(crate) fn connect_tcp_socket_addresses(
    addresses: &[SocketAddr],
    stage: &str,
    timeout: Duration,
) -> io::Result<TcpStream> {
    connect_tcp_socket_addresses_inner_optional(addresses, None, stage, timeout, None)
}

pub(crate) fn connect_tcp_socket_addresses_bound_cancellable(
    addresses: &[SocketAddr],
    local_address: SocketAddr,
    stage: &str,
    timeout: Duration,
    cancel_epoch: u64,
) -> io::Result<TcpStream> {
    connect_tcp_socket_addresses_inner_optional(
        addresses,
        Some(local_address),
        stage,
        timeout,
        Some(cancel_epoch),
    )
}

fn connect_tcp_socket_addresses_inner(
    addresses: &[SocketAddr],
    local_address: Option<SocketAddr>,
    stage: &str,
    timeout: Duration,
    cancel_epoch: u64,
) -> io::Result<TcpStream> {
    connect_tcp_socket_addresses_inner_optional(
        addresses,
        local_address,
        stage,
        timeout,
        Some(cancel_epoch),
    )
}

fn connect_tcp_socket_addresses_inner_optional(
    addresses: &[SocketAddr],
    local_address: Option<SocketAddr>,
    stage: &str,
    timeout: Duration,
    cancel_epoch: Option<u64>,
) -> io::Result<TcpStream> {
    let family_summary = format!(
        "count={},v4={},v6={},bound={}",
        addresses.len(),
        addresses.iter().filter(|address| address.is_ipv4()).count(),
        addresses.iter().filter(|address| address.is_ipv6()).count(),
        local_address.is_some()
    );
    let endpoint_id = crate::safe_diagnostics::sensitive_id(&family_summary);
    let deadline = Instant::now() + timeout;
    connect_candidates_happy_eyeballs(
        addresses.to_vec(),
        local_address,
        deadline,
        cancel_epoch,
        stage,
        &endpoint_id,
    )
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
    let canonical = canonicalize_host(endpoint, stage, endpoint)?;
    let address = canonical
        .split_once('%')
        .map_or(canonical.as_str(), |value| value.0);
    if Ipv6Addr::from_str(address).is_ok() {
        return Ok(ParsedEndpoint {
            host: canonical,
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
    let address = canonical
        .split_once('%')
        .map_or(canonical.as_str(), |value| value.0);
    if address.parse::<Ipv6Addr>().is_err() {
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
    let (address_host, scope) = split_ipv6_scope(host, stage, original)?;

    if scope.is_none() {
        if let Ok(ipv4) = address_host.parse::<Ipv4Addr>() {
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
    }

    if let Ok(ipv6) = address_host.parse::<Ipv6Addr>() {
        let octets = ipv6.octets();
        let ipv4_mapped =
            octets[..10].iter().all(|byte| *byte == 0) && octets[10] == 0xff && octets[11] == 0xff;
        let link_local = octets[0] == 0xfe && (octets[1] & 0xc0) == 0x80;
        if ipv6.is_unspecified() || ipv6.is_multicast() || ipv4_mapped {
            return Err(invalid_endpoint(
                stage,
                original,
                "IPv6 address is not connectable by this transport",
            ));
        }
        if link_local && scope.is_none() {
            return Err(invalid_endpoint(
                stage,
                original,
                "link-local IPv6 requires an interface scope",
            ));
        }
        if !link_local && scope.is_some() {
            return Err(invalid_endpoint(
                stage,
                original,
                "scope is valid only for link-local IPv6",
            ));
        }
        return Ok(match scope {
            Some(scope) => format!("{}%{}", ipv6, scope),
            None => ipv6.to_string(),
        });
    }

    if scope.is_some() {
        return Err(invalid_endpoint(
            stage,
            original,
            "invalid scoped IPv6 host",
        ));
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

fn split_ipv6_scope<'a>(
    host: &'a str,
    stage: &str,
    original: &str,
) -> io::Result<(&'a str, Option<&'a str>)> {
    let Some((address, scope)) = host.split_once('%') else {
        return Ok((host, None));
    };
    if address.is_empty()
        || scope.is_empty()
        || scope.len() > 32
        || scope.contains('%')
        || scope.bytes().all(|byte| byte.is_ascii_digit())
        || !scope.as_bytes()[0].is_ascii_alphabetic()
        || !scope.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'.' || byte == b'-'
        })
    {
        return Err(invalid_endpoint(
            stage,
            original,
            "IPv6 interface scope is invalid or non-portable",
        ));
    }
    Ok((address, Some(scope)))
}

fn numeric_socket_address(
    host: &str,
    port: u16,
    stage: &str,
    endpoint_id: &str,
) -> io::Result<Option<SocketAddr>> {
    if let Ok(ipv4) = host.parse::<Ipv4Addr>() {
        return Ok(Some(SocketAddr::from((ipv4, port))));
    }
    let (address, scope) = split_ipv6_scope(host, stage, host)?;
    let Ok(ipv6) = address.parse::<Ipv6Addr>() else {
        return Ok(None);
    };
    let scope_id = match scope {
        Some(interface) => {
            let interface = CString::new(interface)
                .map_err(|_| invalid_endpoint(stage, host, "IPv6 interface scope contains NUL"))?;
            // SAFETY: CString guarantees a NUL-terminated interface name.
            let index = unsafe { libc::if_nametoindex(interface.as_ptr()) };
            if index == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::AddrNotAvailable,
                    format!("{} scope unavailable endpoint_id={}", stage, endpoint_id),
                ));
            }
            index
        }
        None => 0,
    };
    Ok(Some(SocketAddr::V6(SocketAddrV6::new(
        ipv6, port, 0, scope_id,
    ))))
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
        (host.as_str(), port).to_socket_addrs()
    })
}

fn connect_parsed_endpoint_with_resolver<F, I>(
    endpoint: ParsedEndpoint,
    stage: &str,
    timeout: Duration,
    cancel_epoch: Option<u64>,
    resolver: F,
) -> io::Result<TcpStream>
where
    F: FnOnce(String, u16) -> io::Result<I> + Send + 'static,
    I: IntoIterator<Item = SocketAddr>,
{
    let endpoint_id =
        crate::safe_diagnostics::sensitive_id(&format!("{}:{}", endpoint.host, endpoint.port));
    let deadline = Instant::now() + timeout;
    ensure_not_cancelled(cancel_epoch, stage, &endpoint_id)?;
    if let Some(address) =
        numeric_socket_address(&endpoint.host, endpoint.port, stage, &endpoint_id)?
    {
        return connect_candidates_happy_eyeballs(
            vec![address],
            None,
            deadline,
            cancel_epoch,
            stage,
            &endpoint_id,
        );
    }
    let resolve_host = endpoint.host.clone();
    let resolve_port = endpoint.port;
    // libc does not provide portable getaddrinfo cancellation. Keep timed-out
    // workers lifetime-safe and cap their process-wide concurrency so repeated
    // bad resolvers cannot create an unbounded detached-thread backlog.
    let resolver_permit =
        ResolverWorkerPermit::acquire(&ACTIVE_RESOLVER_WORKERS, MAX_RESOLVER_WORKERS)?;
    let candidates = run_blocking_operation(
        deadline,
        cancel_epoch,
        stage,
        &endpoint_id,
        "resolve",
        move || {
            let _resolver_permit = resolver_permit;
            resolver(resolve_host, resolve_port).map(collect_bounded_candidates)
        },
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

    let stream = connect_candidates_happy_eyeballs(
        candidates,
        None,
        deadline,
        cancel_epoch,
        stage,
        &endpoint_id,
    )?;
    eprintln!(
        "[RustDesk-FFI] {} connected endpoint_id={}",
        stage, endpoint_id
    );
    Ok(stream)
}

#[derive(Debug)]
struct ActiveCandidate {
    descriptor: RawFd,
    original_flags: libc::c_int,
    address: SocketAddr,
}

fn collect_bounded_candidates<I>(candidates: I) -> Vec<SocketAddr>
where
    I: IntoIterator<Item = SocketAddr>,
{
    let mut first_is_ipv6 = None;
    let mut first_family = Vec::with_capacity(MAX_CONNECT_CANDIDATES);
    let mut second_family = Vec::with_capacity(MAX_CONNECT_CANDIDATES);
    for address in candidates {
        let preferred_family = *first_is_ipv6.get_or_insert_with(|| address.is_ipv6());
        let family = if address.is_ipv6() == preferred_family {
            &mut first_family
        } else {
            &mut second_family
        };
        if family.len() < MAX_CONNECT_CANDIDATES && !family.contains(&address) {
            family.push(address);
        }
    }
    let mut result = Vec::with_capacity(MAX_CONNECT_CANDIDATES);
    for index in 0..first_family.len().max(second_family.len()) {
        if let Some(address) = first_family.get(index) {
            result.push(*address);
        }
        if result.len() >= MAX_CONNECT_CANDIDATES {
            break;
        }
        if let Some(address) = second_family.get(index) {
            result.push(*address);
        }
        if result.len() >= MAX_CONNECT_CANDIDATES {
            break;
        }
    }
    result
}

fn close_candidates(candidates: &mut Vec<ActiveCandidate>, except: Option<RawFd>) {
    for candidate in candidates.drain(..) {
        if Some(candidate.descriptor) != except {
            // SAFETY: every descriptor in this vector is uniquely owned by
            // the candidate state machine until it is selected or closed.
            unsafe { libc::close(candidate.descriptor) };
        }
    }
}

fn socket_address_storage(address: SocketAddr) -> (libc::sockaddr_storage, libc::socklen_t) {
    // SAFETY: sockaddr_storage is plain old data and is fully initialized to
    // zero before the selected family view is populated.
    let mut storage: libc::sockaddr_storage = unsafe { std::mem::zeroed() };
    match address {
        SocketAddr::V4(address) => {
            // SAFETY: sockaddr_storage is aligned and large enough for sockaddr_in.
            let value = unsafe { &mut *(&mut storage as *mut _ as *mut libc::sockaddr_in) };
            value.sin_family = libc::AF_INET as libc::sa_family_t;
            #[cfg(any(
                target_os = "macos",
                target_os = "ios",
                target_os = "freebsd",
                target_os = "openbsd",
                target_os = "netbsd"
            ))]
            {
                value.sin_len = std::mem::size_of::<libc::sockaddr_in>() as u8;
            }
            value.sin_port = address.port().to_be();
            value.sin_addr = libc::in_addr {
                s_addr: u32::from_ne_bytes(address.ip().octets()),
            };
            (
                storage,
                std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
            )
        }
        SocketAddr::V6(address) => {
            // SAFETY: sockaddr_storage is aligned and large enough for sockaddr_in6.
            let value = unsafe { &mut *(&mut storage as *mut _ as *mut libc::sockaddr_in6) };
            value.sin6_family = libc::AF_INET6 as libc::sa_family_t;
            #[cfg(any(
                target_os = "macos",
                target_os = "ios",
                target_os = "freebsd",
                target_os = "openbsd",
                target_os = "netbsd"
            ))]
            {
                value.sin6_len = std::mem::size_of::<libc::sockaddr_in6>() as u8;
            }
            value.sin6_port = address.port().to_be();
            value.sin6_flowinfo = address.flowinfo();
            value.sin6_addr = libc::in6_addr {
                s6_addr: address.ip().octets(),
            };
            value.sin6_scope_id = address.scope_id();
            (
                storage,
                std::mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t,
            )
        }
    }
}

fn start_candidate(
    address: SocketAddr,
    local_address: Option<SocketAddr>,
) -> io::Result<(ActiveCandidate, bool)> {
    let family = if address.is_ipv6() {
        libc::AF_INET6
    } else {
        libc::AF_INET
    };
    // SAFETY: arguments are fixed POSIX socket constants and ownership of a
    // successful descriptor is immediately transferred to ActiveCandidate.
    let descriptor = unsafe { libc::socket(family, libc::SOCK_STREAM, libc::IPPROTO_TCP) };
    if descriptor < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fcntl operates on the uniquely owned descriptor.
    let original_flags = unsafe { libc::fcntl(descriptor, libc::F_GETFL) };
    let descriptor_flags = unsafe { libc::fcntl(descriptor, libc::F_GETFD) };
    if original_flags < 0
        || unsafe { libc::fcntl(descriptor, libc::F_SETFL, original_flags | libc::O_NONBLOCK) } < 0
    {
        let error = io::Error::last_os_error();
        unsafe { libc::close(descriptor) };
        return Err(error);
    }
    if descriptor_flags >= 0 {
        unsafe {
            libc::fcntl(
                descriptor,
                libc::F_SETFD,
                descriptor_flags | libc::FD_CLOEXEC,
            )
        };
    }
    if let Some(local_address) =
        local_address.and_then(|value| candidate_bind_address(value, address))
    {
        let reuse: libc::c_int = 1;
        // SAFETY: the option pointer is valid for the declared integer size.
        let reuse_status = unsafe {
            libc::setsockopt(
                descriptor,
                libc::SOL_SOCKET,
                libc::SO_REUSEADDR,
                &reuse as *const _ as *const libc::c_void,
                std::mem::size_of_val(&reuse) as libc::socklen_t,
            )
        };
        if reuse_status < 0 {
            let error = io::Error::last_os_error();
            unsafe { libc::close(descriptor) };
            return Err(error);
        }
        let (local_storage, local_length) = socket_address_storage(local_address);
        // SAFETY: local_storage contains a complete sockaddr matching the descriptor family.
        if unsafe {
            libc::bind(
                descriptor,
                &local_storage as *const _ as *const libc::sockaddr,
                local_length,
            )
        } < 0
        {
            let error = io::Error::last_os_error();
            unsafe { libc::close(descriptor) };
            return Err(error);
        }
    }
    let (storage, length) = socket_address_storage(address);
    // SAFETY: storage contains a fully initialized sockaddr for its family.
    let result = unsafe {
        libc::connect(
            descriptor,
            &storage as *const _ as *const libc::sockaddr,
            length,
        )
    };
    let candidate = ActiveCandidate {
        descriptor,
        original_flags,
        address,
    };
    if result == 0 {
        return Ok((candidate, true));
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error().is_some_and(|code| {
        code == libc::EINPROGRESS
            || code == libc::EALREADY
            || code == libc::EINTR
            || code == libc::EWOULDBLOCK
    }) {
        Ok((candidate, false))
    } else {
        unsafe { libc::close(descriptor) };
        Err(error)
    }
}

fn candidate_bind_address(
    local_address: SocketAddr,
    remote_address: SocketAddr,
) -> Option<SocketAddr> {
    // Reuse the hbbs source address only for a peer candidate in the same
    // address family. A control connection can be IPv4 while the peer is
    // IPv6 (or vice versa); binding that address to the other-family socket
    // is invalid and must not suppress the otherwise reachable candidate.
    (local_address.is_ipv4() == remote_address.is_ipv4()).then_some(local_address)
}

fn finish_candidate(
    winner: ActiveCandidate,
    active: &mut Vec<ActiveCandidate>,
    cancel_epoch: Option<u64>,
    stage: &str,
    endpoint_id: &str,
) -> io::Result<TcpStream> {
    finish_candidate_with_post_restore(winner, active, cancel_epoch, stage, endpoint_id, || {})
}

fn finish_candidate_with_post_restore<F>(
    winner: ActiveCandidate,
    active: &mut Vec<ActiveCandidate>,
    cancel_epoch: Option<u64>,
    stage: &str,
    endpoint_id: &str,
    post_restore: F,
) -> io::Result<TcpStream>
where
    F: FnOnce(),
{
    if let Err(error) = ensure_not_cancelled(cancel_epoch, stage, endpoint_id) {
        close_candidates(active, None);
        // SAFETY: winner has already been removed from active and remains
        // uniquely owned by this function until it is handed to TcpStream.
        unsafe { libc::close(winner.descriptor) };
        return Err(error);
    }
    close_candidates(active, Some(winner.descriptor));
    // SAFETY: the winning descriptor is uniquely owned by winner.
    if unsafe { libc::fcntl(winner.descriptor, libc::F_SETFL, winner.original_flags) } < 0 {
        let error = io::Error::last_os_error();
        unsafe { libc::close(winner.descriptor) };
        return Err(error);
    }
    post_restore();
    if let Err(error) = ensure_not_cancelled(cancel_epoch, stage, endpoint_id) {
        unsafe { libc::close(winner.descriptor) };
        return Err(error);
    }
    // SAFETY: the winning descriptor is uniquely owned and removed from the
    // active vector; TcpStream assumes that ownership exactly once.
    let stream = unsafe { TcpStream::from_raw_fd(winner.descriptor) };
    Ok(stream)
}

fn connect_candidates_happy_eyeballs(
    candidates: Vec<SocketAddr>,
    local_address: Option<SocketAddr>,
    deadline: Instant,
    cancel_epoch: Option<u64>,
    stage: &str,
    endpoint_id: &str,
) -> io::Result<TcpStream> {
    let candidates = collect_bounded_candidates(candidates);
    if candidates.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::AddrNotAvailable,
            format!(
                "{} has no dial candidates endpoint_id={}",
                stage, endpoint_id
            ),
        ));
    }
    let mut active = Vec::<ActiveCandidate>::new();
    let mut next_index = 0usize;
    let mut next_launch = Instant::now();
    let mut last_error = None;

    loop {
        if let Err(error) = ensure_not_cancelled(cancel_epoch, stage, endpoint_id) {
            close_candidates(&mut active, None);
            return Err(error);
        }
        let mut now = Instant::now();
        if now >= deadline {
            close_candidates(&mut active, None);
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!("{} connect timed out endpoint_id={}", stage, endpoint_id),
            ));
        }

        while next_index < candidates.len() && (active.is_empty() || now >= next_launch) {
            let address = candidates[next_index];
            next_index += 1;
            match start_candidate(address, local_address) {
                Ok((candidate, true)) => {
                    let descriptor = candidate.descriptor;
                    active.push(candidate);
                    let winner_index = active
                        .iter()
                        .position(|value| value.descriptor == descriptor)
                        .expect("new winner must be active");
                    let winner = active.remove(winner_index);
                    return finish_candidate(winner, &mut active, cancel_epoch, stage, endpoint_id);
                }
                Ok((candidate, false)) => {
                    active.push(candidate);
                    next_launch = Instant::now() + HAPPY_EYEBALLS_DELAY;
                    break;
                }
                Err(error) => {
                    last_error = Some(error);
                    now = Instant::now();
                }
            }
        }

        if active.is_empty() && next_index >= candidates.len() {
            let error = last_error.unwrap_or_else(|| {
                io::Error::new(io::ErrorKind::NotConnected, "all candidates failed")
            });
            return Err(io::Error::new(
                error.kind(),
                format!(
                    "{} connect failed endpoint_id={} error_kind={:?}",
                    stage,
                    endpoint_id,
                    error.kind()
                ),
            ));
        }

        let mut descriptors: Vec<libc::pollfd> = active
            .iter()
            .map(|candidate| libc::pollfd {
                fd: candidate.descriptor,
                events: libc::POLLOUT | libc::POLLERR | libc::POLLHUP,
                revents: 0,
            })
            .collect();
        now = Instant::now();
        let mut wait = deadline
            .saturating_duration_since(now)
            .min(CONNECT_POLL_SLICE);
        if next_index < candidates.len() {
            wait = wait.min(next_launch.saturating_duration_since(now));
        }
        // SAFETY: poll owns no descriptors and the vector remains alive and
        // immovable for the duration of the call.
        let poll_result = unsafe {
            libc::poll(
                descriptors.as_mut_ptr(),
                descriptors.len() as libc::nfds_t,
                wait.as_millis().min(libc::c_int::MAX as u128) as libc::c_int,
            )
        };
        if poll_result < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            close_candidates(&mut active, None);
            return Err(error);
        }
        if poll_result == 0 {
            continue;
        }

        let mut index = 0usize;
        while index < active.len() {
            if descriptors[index].revents == 0 {
                index += 1;
                continue;
            }
            let mut socket_error: libc::c_int = 0;
            let mut error_length = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
            // SAFETY: output pointers are valid for error_length bytes and
            // the descriptor remains owned by active[index].
            let status = unsafe {
                libc::getsockopt(
                    active[index].descriptor,
                    libc::SOL_SOCKET,
                    libc::SO_ERROR,
                    &mut socket_error as *mut _ as *mut libc::c_void,
                    &mut error_length,
                )
            };
            if status == 0 && socket_error == 0 {
                let winner = active.remove(index);
                return finish_candidate(winner, &mut active, cancel_epoch, stage, endpoint_id);
            }
            let error = if socket_error != 0 {
                io::Error::from_raw_os_error(socket_error)
            } else {
                io::Error::last_os_error()
            };
            last_error = Some(error);
            let failed = active.remove(index);
            unsafe { libc::close(failed.descriptor) };
            descriptors.remove(index);
        }
        if active.is_empty() && next_index < candidates.len() {
            next_launch = Instant::now();
        }
    }
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
    use std::sync::Arc;

    #[test]
    fn happy_eyeballs_interleaves_families_and_removes_duplicates() {
        let v6_first: SocketAddr = "[2001:db8::1]:21116".parse().unwrap();
        let v6_second: SocketAddr = "[2001:db8::2]:21116".parse().unwrap();
        let v4_first: SocketAddr = "192.0.2.1:21116".parse().unwrap();
        let v4_second: SocketAddr = "192.0.2.2:21116".parse().unwrap();
        assert_eq!(
            collect_bounded_candidates(vec![v6_first, v6_first, v6_second, v4_first, v4_second,]),
            vec![v6_first, v4_first, v6_second, v4_second]
        );

        assert_eq!(
            collect_bounded_candidates(vec![v4_first, v4_second, v6_first, v6_second]),
            vec![v4_first, v6_first, v4_second, v6_second]
        );
    }

    #[test]
    fn happy_eyeballs_keeps_late_alternate_family_before_candidate_cap() {
        let mut candidates = (1..=MAX_CONNECT_CANDIDATES)
            .map(|suffix| format!("[2001:db8::{suffix:x}]:21116").parse().unwrap())
            .collect::<Vec<SocketAddr>>();
        let ipv4: SocketAddr = "192.0.2.1:21116".parse().unwrap();
        candidates.push(ipv4);

        let ordered = collect_bounded_candidates(candidates);
        assert_eq!(ordered.len(), MAX_CONNECT_CANDIDATES);
        assert!(ordered[0].is_ipv6());
        assert_eq!(ordered[1], ipv4);
    }

    #[test]
    fn resolver_candidate_collection_has_a_hard_allocation_bound() {
        let candidates = (1..=(MAX_CONNECT_CANDIDATES * 64)).map(|suffix| {
            SocketAddr::V6(SocketAddrV6::new(
                Ipv6Addr::from(suffix as u128),
                21116,
                0,
                0,
            ))
        });

        let bounded = collect_bounded_candidates(candidates);
        assert_eq!(bounded.len(), MAX_CONNECT_CANDIDATES);
        assert!(bounded.iter().all(SocketAddr::is_ipv6));
    }

    #[test]
    fn peer_candidate_bind_is_reused_only_within_the_same_family() {
        let local_v4: SocketAddr = "127.0.0.1:41001".parse().unwrap();
        let local_v6: SocketAddr = "[::1]:41002".parse().unwrap();
        let remote_v4: SocketAddr = "192.0.2.20:21118".parse().unwrap();
        let remote_v6: SocketAddr = "[2001:db8::20]:21118".parse().unwrap();
        assert_eq!(candidate_bind_address(local_v4, remote_v4), Some(local_v4));
        assert_eq!(candidate_bind_address(local_v6, remote_v6), Some(local_v6));
        assert_eq!(candidate_bind_address(local_v4, remote_v6), None);
        assert_eq!(candidate_bind_address(local_v6, remote_v4), None);
    }

    #[test]
    fn happy_eyeballs_closes_winner_when_cancellation_wins_race() {
        let mut descriptors = [-1; 2];
        // SAFETY: descriptors points to storage for the two socketpair outputs.
        assert_eq!(
            unsafe {
                libc::socketpair(
                    libc::AF_UNIX,
                    libc::SOCK_STREAM,
                    0,
                    descriptors.as_mut_ptr(),
                )
            },
            0
        );
        let epoch = crate::begin_connect_epoch(90_021);
        crate::cancel_connect_epoch(epoch);
        let winner = ActiveCandidate {
            descriptor: descriptors[0],
            original_flags: unsafe { libc::fcntl(descriptors[0], libc::F_GETFL) },
            address: "127.0.0.1:9".parse().unwrap(),
        };

        let error = finish_candidate(
            winner,
            &mut Vec::new(),
            Some(epoch),
            "test",
            "cancelled-winner",
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Interrupted);
        assert_eq!(unsafe { libc::fcntl(descriptors[0], libc::F_GETFD) }, -1);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EBADF));

        unsafe { libc::close(descriptors[1]) };
        crate::finish_connect_epoch(epoch, 90_021);
    }

    #[test]
    fn happy_eyeballs_closes_winner_when_cancelled_after_flag_restore() {
        let mut descriptors = [-1; 2];
        // SAFETY: descriptors points to storage for the two socketpair outputs.
        assert_eq!(
            unsafe {
                libc::socketpair(
                    libc::AF_UNIX,
                    libc::SOCK_STREAM,
                    0,
                    descriptors.as_mut_ptr(),
                )
            },
            0
        );
        let epoch = crate::begin_connect_epoch(90_022);
        let winner = ActiveCandidate {
            descriptor: descriptors[0],
            original_flags: unsafe { libc::fcntl(descriptors[0], libc::F_GETFL) },
            address: "127.0.0.1:9".parse().unwrap(),
        };

        let error = finish_candidate_with_post_restore(
            winner,
            &mut Vec::new(),
            Some(epoch),
            "test",
            "post-restore-cancelled-winner",
            || crate::cancel_connect_epoch(epoch),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::Interrupted);
        assert_eq!(unsafe { libc::fcntl(descriptors[0], libc::F_GETFD) }, -1);
        assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::EBADF));

        unsafe { libc::close(descriptors[1]) };
        crate::finish_connect_epoch(epoch, 90_022);
    }

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
    fn parse_endpoint_supports_interface_scoped_link_local_ipv6() {
        assert_eq!(
            parse_endpoint("[fe80:0:0:0:0:0:0:1%en0]:21117", 21116, "test").unwrap(),
            ParsedEndpoint {
                host: "fe80::1%en0".to_string(),
                port: 21117,
            }
        );
        assert_eq!(
            parse_endpoint("fe80::1%en0", 21116, "test").unwrap(),
            ParsedEndpoint {
                host: "fe80::1%en0".to_string(),
                port: 21116,
            }
        );
    }

    #[test]
    fn scoped_link_local_maps_interface_name_at_transport_boundary() {
        let interface = ["lo0", "lo"].into_iter().find(|name| {
            let name = CString::new(*name).unwrap();
            (unsafe { libc::if_nametoindex(name.as_ptr()) }) != 0
        });
        let Some(interface) = interface else {
            return;
        };
        let host = format!("fe80::1%{interface}");
        let address = numeric_socket_address(&host, 21116, "test", "scope").unwrap();
        let SocketAddr::V6(address) = address.unwrap() else {
            panic!("scoped address must remain IPv6");
        };
        assert_ne!(address.scope_id(), 0);
        assert_eq!(*address.ip(), "fe80::1".parse::<Ipv6Addr>().unwrap());
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
            "[fe80::1]",
            "[fe80::1%2]",
            "[fe80::1%_bad]",
            "[2001:db8::1%en0]",
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

    #[test]
    fn resolver_worker_permit_enforces_a_hard_concurrency_limit() {
        static TEST_ACTIVE: AtomicUsize = AtomicUsize::new(0);
        let first = ResolverWorkerPermit::acquire(&TEST_ACTIVE, 2).unwrap();
        let second = ResolverWorkerPermit::acquire(&TEST_ACTIVE, 2).unwrap();
        let error = ResolverWorkerPermit::acquire(&TEST_ACTIVE, 2).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
        drop(first);
        let replacement = ResolverWorkerPermit::acquire(&TEST_ACTIVE, 2).unwrap();
        drop(second);
        drop(replacement);
        assert_eq!(TEST_ACTIVE.load(Ordering::Acquire), 0);
    }
}
