/** RDP client identity is independent from the transport peer and TLS/NLA server identity. */
export function normalizeRdpClientHostname(value: string): string | null {
  if (value === '') { return ''; }
  if (value.length > 253 || !/^[A-Za-z0-9.-]+$/.test(value)) {
    return null;
  }
  const labels: string[] = value.split('.');
  for (let index = 0; index < labels.length; index++) {
    const label: string = labels[index];
    if (label.length < 1 || label.length > 63 || label.startsWith('-') || label.endsWith('-')) {
      return null;
    }
  }
  return value;
}
