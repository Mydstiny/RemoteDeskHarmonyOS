function keepEdges(value: string): string {
  const text: string = value.trim();
  if (text.length === 0) {
    return '<empty>';
  }
  if (text.length <= 2) {
    return text.substring(0, 1) + '*';
  }
  return text.substring(0, 1) + '***' + text.substring(text.length - 1);
}

function isIpv4(host: string): boolean {
  const parts: string[] = host.split('.');
  if (parts.length !== 4) {
    return false;
  }
  for (let i = 0; i < parts.length; i++) {
    const n: number = Number(parts[i]);
    if (!Number.isInteger(n) || n < 0 || n > 255) {
      return false;
    }
  }
  return true;
}

function redactSensitiveTokens(text: string): string {
  return text
    .replace(/password\s*=\s*[^,\s;]+/gi, 'password=<redacted>')
    .replace(/secret\s*=\s*[^,\s;]+/gi, 'secret=<redacted>')
    .replace(/token\s*=\s*[^,\s;]+/gi, 'token=<redacted>')
    .replace(/apiKey\s*=\s*[^,\s;]+/gi, 'apiKey=<redacted>')
    .replace(/apiPassword\s*=\s*[^,\s;]+/gi, 'apiPassword=<redacted>');
}

export function maskHost(host: string): string {
  const text: string = host.trim();
  if (text.length === 0) {
    return '<empty>';
  }
  if (isIpv4(text)) {
    const parts: string[] = text.split('.');
    return parts[0] + '.' + parts[1] + '.*.' + parts[3];
  }
  const domainParts: string[] = text.split('.');
  if (domainParts.length >= 3) {
    return domainParts[0] + '...' + domainParts[domainParts.length - 1];
  }
  return keepEdges(text);
}

export function maskUser(user: string): string {
  const text: string = user.trim();
  if (text.length === 0) {
    return '<empty>';
  }
  const slashIndex: number = text.indexOf('\\');
  if (slashIndex > 0) {
    return keepEdges(text.substring(0, slashIndex)) + '\\' + keepEdges(text.substring(slashIndex + 1));
  }
  const atIndex: number = text.indexOf('@');
  if (atIndex > 0) {
    const local: string = text.substring(0, atIndex);
    const domain: string = text.substring(atIndex + 1);
    const domainParts: string[] = domain.split('.');
    if (domainParts.length >= 2) {
      return keepEdges(local) + '@' + keepEdges(domainParts[0]) + '.' + domainParts.slice(1).join('.');
    }
    return keepEdges(local) + '@' + keepEdges(domain);
  }
  return keepEdges(text);
}

export function maskSecret(value: string): string {
  if (value.length === 0) {
    return '<empty>';
  }
  return '<secret:' + value.length.toString() + '>';
}

export function hashForLog(value: string): string {
  let hash: number = 2166136261;
  for (let i = 0; i < value.length; i++) {
    hash = (hash ^ value.charCodeAt(i)) >>> 0;
    hash = Math.imul(hash, 16777619) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

export function safeError(err: Error | object | string | null | undefined): string {
  if (err === null || err === undefined) {
    return '<empty-error>';
  }
  if (typeof err === 'string') {
    return redactSensitiveTokens(err);
  }
  if (err instanceof Error) {
    return redactSensitiveTokens(err.message);
  }
  const record: Record<string, Object> = err as Record<string, Object>;
  const code: Object | undefined = record['code'];
  const message: Object | undefined = record['message'];
  if (code !== undefined || message !== undefined) {
    return 'code=' + String(code ?? '') + ' message=' + redactSensitiveTokens(String(message ?? ''));
  }
  return '<object-error>';
}
