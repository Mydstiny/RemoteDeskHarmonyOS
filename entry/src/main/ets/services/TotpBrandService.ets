/**
 * TOTP issuer branding.
 *
 * Logos are resolved from the Simple Icons CDN only after the user enables
 * real-logo mode.  The URL contains a normalized brand slug, never the TOTP
 * secret or the account name.  Unknown issuers stay fully local and use the
 * deterministic initials avatar.
 */

export interface TotpBrandVisual {
  slug: string;
  background: string;
  foreground: string;
}

const BRAND_SLUGS: Record<string, string> = {
  'google': 'google', 'google cloud': 'googlecloud', 'google workspace': 'google',
  'github': 'github', 'gitlab': 'gitlab', 'bitbucket': 'bitbucket',
  'microsoft': 'microsoft', 'microsoft 365': 'microsoft365', 'azure': 'microsoftazure',
  'entra': 'microsoftentra', 'aws': 'amazonwebservices', 'amazon web services': 'amazonwebservices',
  'amazon': 'amazon', 'apple': 'apple', 'icloud': 'icloud',
  'facebook': 'facebook', 'meta': 'meta', 'instagram': 'instagram', 'whatsapp': 'whatsapp',
  'x': 'x', 'twitter': 'x', 'linkedin': 'linkedin', 'tiktok': 'tiktok',
  'discord': 'discord', 'slack': 'slack', 'zoom': 'zoom', 'teams': 'microsoftteams',
  'dropbox': 'dropbox', 'box': 'box', 'notion': 'notion', 'figma': 'figma',
  'adobe': 'adobe', 'canva': 'canva', 'atlassian': 'atlassian', 'jira': 'jira',
  'trello': 'trello', 'linear': 'linear', 'salesforce': 'salesforce',
  'cloudflare': 'cloudflare', 'digitalocean': 'digitalocean', 'heroku': 'heroku',
  'vercel': 'vercel', 'netlify': 'netlify', 'docker': 'docker', 'kubernetes': 'kubernetes',
  'npm': 'npm', 'pypi': 'pypi', 'sentry': 'sentry',
  'spotify': 'spotify', 'netflix': 'netflix', 'reddit': 'reddit', 'pinterest': 'pinterest',
  'snapchat': 'snapchat', 'tumblr': 'tumblr', 'twitch': 'twitch',
  'paypal': 'paypal', 'stripe': 'stripe', 'square': 'square', 'shopify': 'shopify',
  'twilio': 'twilio', 'sendgrid': 'sendgrid', 'namecheap': 'namecheap', 'godaddy': 'godaddy',
  'wordpress': 'wordpress', 'steam': 'steam', 'epic games': 'epicgames',
  'cloudmusic': 'neteasecloudmusic', 'netease': 'neteasecloudmusic',
  'binance': 'binance', 'coinbase': 'coinbase', 'okx': 'okx', 'kraken': 'kraken',
  'huawei': 'huawei', 'huawei cloud': 'huaweicloud', 'alibaba cloud': 'alibabacloud',
  'alipay': 'alipay', 'wechat': 'wechat', 'wecom': 'wechatwork', 'dingtalk': 'dingtalk',
  'feishu': 'feishu', 'baidu': 'baidu', 'bilibili': 'bilibili', '京东': 'jd', 'jd': 'jd',
  '淘宝': 'taobao', 'taobao': 'taobao', '腾讯': 'tencentqq', 'qq': 'tencentqq',
  '1password': '1password', 'bitwarden': 'bitwarden', 'authy': 'authy',
  'okta': 'okta', 'duo': 'duolingo', 'duo security': 'duosecurity',
  'lastpass': 'lastpass', 'proton': 'proton', 'protonmail': 'protonmail',
  'rustdesk': 'rustdesk'
};

const BRAND_COLORS: Record<string, string> = {
  'google': '#4285F4', 'github': '#24292F', 'gitlab': '#FC6D26',
  'microsoft': '#0078D4', 'azure': '#0078D4', 'aws': '#232F3E', 'amazon': '#232F3E',
  'apple': '#1D1D1F', 'facebook': '#1877F2', 'meta': '#0467DF', 'instagram': '#C13584',
  'x': '#111111', 'twitter': '#1DA1F2', 'linkedin': '#0A66C2', 'tiktok': '#111111',
  'discord': '#5865F2', 'slack': '#4A154B', 'zoom': '#2D8CFF', 'dropbox': '#0061FF',
  'notion': '#111111', 'figma': '#F24E1E', 'adobe': '#D90000', 'canva': '#00C4CC',
  'atlassian': '#0052CC', 'jira': '#1868DB', 'cloudflare': '#F38020',
  'digitalocean': '#0080FF', 'heroku': '#430098', 'vercel': '#111111', 'docker': '#2496ED',
  'spotify': '#1DB954', 'netflix': '#E50914', 'reddit': '#FF4500', 'pinterest': '#E60023',
  'paypal': '#003087', 'stripe': '#635BFF', 'shopify': '#008060', 'twilio': '#F22F46',
  'steam': '#171A21', 'binance': '#B88600', 'coinbase': '#0052FF', 'huawei': '#CF0A2C',
  'alipay': '#1677FF', 'wechat': '#07C160', 'baidu': '#2932E1', 'bilibili': '#00AEEC',
  '1password': '#0094F0', 'bitwarden': '#175DDC', 'authy': '#EC1C24', 'okta': '#007DC1',
  'rustdesk': '#2B7FFF'
};

const FALLBACK_COLORS: string[] = [
  '#1F3A5F', '#234E52', '#3B2F63', '#5A2A3A', '#304B36', '#4A3B25', '#263238', '#3A3F5C'
];

function normalize(value: string): string {
  return value.trim().toLowerCase().replace(/[._-]+/g, ' ').replace(/\s+/g, ' ');
}

function lookupSlug(issuer: string, account: string): string {
  const key: string = normalize(issuer);
  if (BRAND_SLUGS[key]) { return BRAND_SLUGS[key]; }
  const names: string[] = Object.keys(BRAND_SLUGS);
  for (let i = 0; i < names.length; i++) {
    const name: string = names[i];
    if (key.includes(name) || name.includes(key)) { return BRAND_SLUGS[name]; }
  }
  const at: number = account.indexOf('@');
  if (at >= 0) {
    const domain: string = normalize(account.substring(at + 1).split('.')[0]);
    if (BRAND_SLUGS[domain]) { return BRAND_SLUGS[domain]; }
  }
  return '';
}

function colorFor(issuer: string, account: string): string {
  const key: string = normalize(issuer);
  const names: string[] = Object.keys(BRAND_COLORS);
  for (let i = 0; i < names.length; i++) {
    if (key === names[i] || key.includes(names[i]) || names[i].includes(key)) {
      return BRAND_COLORS[names[i]];
    }
  }
  const slug: string = lookupSlug(issuer, account);
  if (slug !== '') {
    const slugNames: string[] = Object.keys(BRAND_COLORS);
    for (let i = 0; i < slugNames.length; i++) {
      if (slug.includes(slugNames[i])) { return BRAND_COLORS[slugNames[i]]; }
    }
  }
  let hash: number = 0;
  const source: string = key + '|' + normalize(account);
  for (let i = 0; i < source.length; i++) {
    hash = source.charCodeAt(i) + ((hash << 5) - hash);
  }
  return FALLBACK_COLORS[Math.abs(hash) % FALLBACK_COLORS.length];
}

function channel(value: string): number {
  return parseInt(value, 16);
}

function foregroundFor(background: string): string {
  if (!background.startsWith('#') || background.length !== 7) { return '#FFFFFF'; }
  const red: number = channel(background.substring(1, 3));
  const green: number = channel(background.substring(3, 5));
  const blue: number = channel(background.substring(5, 7));
  const luminance: number = (red * 299 + green * 587 + blue * 114) / 1000;
  return luminance >= 168 ? '#111827' : '#FFFFFF';
}

export function totpBrandVisual(issuer: string, account: string): TotpBrandVisual {
  const background: string = colorFor(issuer, account);
  return {
    slug: lookupSlug(issuer, account),
    background,
    foreground: foregroundFor(background)
  };
}

export function totpBrandLogoUrl(issuer: string, account: string): string {
  const slug: string = lookupSlug(issuer, account);
  return slug === '' ? '' : 'https://cdn.simpleicons.org/' + slug;
}

export function totpInitialOf(name: string): string {
  const text: string = name.trim();
  if (text.length === 0) { return '?'; }
  const first: string = text.charAt(0);
  return /[A-Za-z]/.test(first) ? first.toUpperCase() : first;
}
