//! TCP endpoint parsing and DNS-aware connection helpers for RustDesk.

use std::io;
use std::net::{TcpStream, ToSocketAddrs};
use std::str::FromStr;
use std::time::{Duration, Instant};

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
    let host = normalize_host(host, stage)?;
    validate_port(port, stage, &host)?;
    connect_parsed_endpoint(ParsedEndpoint { host, port }, stage, timeout)
}

/// Connect to an endpoint that may contain an explicit port.
pub(crate) fn connect_tcp_endpoint(
    endpoint: &str,
    default_port: u16,
    stage: &str,
    timeout: Duration,
) -> io::Result<TcpStream> {
    let parsed = parse_endpoint(endpoint, default_port, stage)?;
    connect_parsed_endpoint(parsed, stage, timeout)
}

fn normalize_host(host: &str, stage: &str) -> io::Result<String> {
    let host = host.trim();
    if host.is_empty() {
        return Err(invalid_endpoint(stage, host, "host is empty"));
    }
    if has_uri_or_path(host) {
        return Err(invalid_endpoint(
            stage,
            host,
            "URL schemes and paths are not valid TCP hosts",
        ));
    }
    if host.starts_with('[') || host.ends_with(']') {
        if host.starts_with('[') && host.ends_with(']') && host.len() > 2 {
            return Ok(host[1..host.len() - 1].to_string());
        }
        return Err(invalid_endpoint(stage, host, "invalid bracketed host"));
    }
    if host.chars().any(char::is_whitespace) {
        return Err(invalid_endpoint(stage, host, "host contains whitespace"));
    }
    if host.contains(':') && host.parse::<std::net::SocketAddr>().is_ok() {
        return Err(invalid_endpoint(
            stage,
            host,
            "host must not include a port; pass port separately",
        ));
    }
    Ok(host.to_string())
}

fn parse_endpoint(endpoint: &str, default_port: u16, stage: &str) -> io::Result<ParsedEndpoint> {
    let endpoint = endpoint.trim();
    if endpoint.is_empty() {
        return Err(invalid_endpoint(stage, endpoint, "endpoint is empty"));
    }
    if has_uri_or_path(endpoint) || endpoint.chars().any(char::is_whitespace) {
        return Err(invalid_endpoint(
            stage,
            endpoint,
            "URL schemes, paths, and whitespace are not valid TCP endpoints",
        ));
    }

    if endpoint.starts_with('[') {
        let close = endpoint.find(']').ok_or_else(|| {
            invalid_endpoint(stage, endpoint, "missing closing bracket for IPv6 host")
        })?;
        let host = &endpoint[1..close];
        if host.is_empty() {
            return Err(invalid_endpoint(stage, endpoint, "IPv6 host is empty"));
        }
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
        return Ok(ParsedEndpoint {
            host: host.to_string(),
            port,
        });
    }

    let colon_count = endpoint.chars().filter(|c| *c == ':').count();
    if colon_count == 0 {
        return Ok(ParsedEndpoint {
            host: endpoint.to_string(),
            port: default_port,
        });
    }
    if colon_count == 1 {
        let (host, port_text) = endpoint.split_once(':').expect("one colon must split");
        if host.is_empty() {
            return Err(invalid_endpoint(stage, endpoint, "host is empty"));
        }
        return Ok(ParsedEndpoint {
            host: host.to_string(),
            port: parse_port(port_text, stage, endpoint)?,
        });
    }

    // An unbracketed multi-colon value is accepted only as a raw IPv6 host;
    // an explicit IPv6 port must use [addr]:port to remain unambiguous.
    if std::net::Ipv6Addr::from_str(endpoint).is_ok() {
        return Ok(ParsedEndpoint {
            host: endpoint.to_string(),
            port: default_port,
        });
    }
    Err(invalid_endpoint(
        stage,
        endpoint,
        "IPv6 endpoints with an explicit port must use [addr]:port",
    ))
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
    value.contains("://") || value.contains('/') || value.contains('?') || value.contains('#')
}

fn invalid_endpoint(stage: &str, endpoint: &str, reason: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        format!("{} endpoint invalid '{}': {}", stage, endpoint, reason),
    )
}

fn connect_parsed_endpoint(
    endpoint: ParsedEndpoint,
    stage: &str,
    timeout: Duration,
) -> io::Result<TcpStream> {
    let display = format!("{}:{}", endpoint.host, endpoint.port);
    let candidates: Vec<_> = (endpoint.host.as_str(), endpoint.port)
        .to_socket_addrs()
        .map_err(|error| {
            io::Error::new(
                io::ErrorKind::AddrNotAvailable,
                format!(
                    "{} resolve failed endpoint={} error={}",
                    stage, display, error
                ),
            )
        })?
        .collect();
    if candidates.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::AddrNotAvailable,
            format!(
                "{} resolve returned no addresses endpoint={}",
                stage, display
            ),
        ));
    }
    eprintln!(
        "[RustDesk-FFI] {} resolved endpoint={} addresses={}",
        stage,
        display,
        candidates.len()
    );

    let deadline = Instant::now() + timeout;
    let mut last_error = None;
    for address in candidates {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        match TcpStream::connect_timeout(&address, remaining) {
            Ok(stream) => {
                eprintln!(
                    "[RustDesk-FFI] {} connected endpoint={} address={}",
                    stage, display, address
                );
                return Ok(stream);
            }
            Err(error) => last_error = Some((address, error)),
        }
    }

    let (address, error) = match last_error {
        Some(value) => value,
        None => {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!("{} connect timed out endpoint={}", stage, display),
            ));
        }
    };
    Err(io::Error::new(
        error.kind(),
        format!(
            "{} connect failed endpoint={} address={} error={}",
            stage, display, address, error
        ),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_endpoint_supports_hostname_and_explicit_port() {
        assert_eq!(
            parse_endpoint("hbbs.example.com:21116", 21117, "test").unwrap(),
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
            parse_endpoint("2001:db8::1", 21116, "test").unwrap(),
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
        assert!(error.to_string().contains("URL schemes"));
    }
}
