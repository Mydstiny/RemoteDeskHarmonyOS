import { DiagnosticAiAdapterFamily } from './DiagnosticAiModels';

export interface DiagnosticAiEndpointDecision { ok: boolean; message: string; normalized: string; }
interface ParsedEndpoint { scheme: string; authority: string; host: string; path: string; }
interface ParsedAuthority { host: string; valid: boolean; }

function parseAuthority(value: string): ParsedAuthority {
  if (value.startsWith('[')) {
    const close: number = value.indexOf(']');
    if (close < 0) { return { host: '', valid: false }; }
    const host: string = value.slice(0, close + 1).toLowerCase();
    const tail: string = value.slice(close + 1);
    if (tail !== '' && !/^:[0-9]{1,5}$/.test(tail)) { return { host: '', valid: false }; }
    if (tail !== '' && Number(tail.slice(1)) > 65535) { return { host: '', valid: false }; }
    return { host, valid: true };
  }
  const firstColon: number = value.indexOf(':');
  if (firstColon < 0) { return { host: value.toLowerCase(), valid: value !== '' }; }
  if (value.indexOf(':', firstColon + 1) >= 0) { return { host: '', valid: false }; }
  const host: string = value.slice(0, firstColon).toLowerCase();
  const port: string = value.slice(firstColon + 1);
  if (host === '' || !/^[0-9]{1,5}$/.test(port) || Number(port) > 65535) {
    return { host: '', valid: false };
  }
  return { host, valid: true };
}

function parseEndpoint(value: string): ParsedEndpoint | null {
  const schemeEnd = value.indexOf('://'); if (schemeEnd <= 0) { return null; }
  const scheme = value.slice(0, schemeEnd).toLowerCase(); const rest = value.slice(schemeEnd + 3);
  const slash = rest.indexOf('/'); const question = rest.indexOf('?'); const hash = rest.indexOf('#');
  let authorityEnd = rest.length;
  if (slash >= 0 && slash < authorityEnd) { authorityEnd = slash; }
  if (question >= 0 && question < authorityEnd) { authorityEnd = question; }
  if (hash >= 0 && hash < authorityEnd) { authorityEnd = hash; }
  const authority = rest.slice(0, authorityEnd); if (authority === '') { return null; }
  if (authority.lastIndexOf('@') >= 0) { return null; }
  const authorityParts: ParsedAuthority = parseAuthority(authority);
  if (!authorityParts.valid) { return null; }
  const pathStart = rest.indexOf('/', authorityEnd);
  const path = pathStart >= 0 ? rest.slice(pathStart).split('?')[0].split('#')[0].replace(/\/+$/, '') : '';
  return { scheme, authority, host: authorityParts.host, path };
}

function isLoopback(host: string): boolean {
  return host === 'localhost' || host === '127.0.0.1' || host === '[::1]' || host === '::1';
}

export function validateDiagnosticAiEndpoint(urlText: string, family: DiagnosticAiAdapterFamily,
  allowLan: boolean = false): DiagnosticAiEndpointDecision {
  const raw = urlText.trim();
  if (raw.length === 0 || raw.length > 2048) { return { ok: false, message: 'Provider 地址不能为空且不能超过 2048 个字符', normalized: '' }; }
  const parsed = parseEndpoint(raw);
  if (parsed === null || raw.indexOf('?') >= 0 || raw.indexOf('#') >= 0) { return { ok: false, message: 'Provider 地址格式无效', normalized: '' }; }
  const loopback = isLoopback(parsed.host);
  if (parsed.scheme !== 'https' && !(parsed.scheme === 'http' && loopback)) {
    return { ok: false, message: '仅允许 HTTPS；HTTP 只允许本机回环地址', normalized: '' };
  }
  if (family === 'ollama_local' && !loopback && !allowLan) { return { ok: false, message: 'Ollama 默认只允许本机回环地址', normalized: '' }; }
  if (!loopback && !allowLan && parsed.host.indexOf('.') < 0) { return { ok: false, message: '自定义局域网 Provider 需要显式开启局域网信任', normalized: '' }; }
  return { ok: true, message: '', normalized: parsed.scheme + '://' + parsed.authority + parsed.path };
}

function endpointOrigin(value: string): string {
  const parsed = parseEndpoint(value); return parsed === null ? '' : parsed.scheme + '://' + parsed.authority;
}

export function sameOriginRedirectAllowed(origin: string, target: string): boolean {
  const left = endpointOrigin(origin); const right = endpointOrigin(target); return left !== '' && left === right;
}
