import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const WEB_TIMEOUT_MS: number = 15000;
const WEB_MAX_BYTES: number = 3 * 1024 * 1024;
const PAGE_CHARS: number = 6000;
const USER_AGENT: string = 'Mozilla/5.0 (Linux; HarmonyOS 6.0; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/120.0.0.0 Mobile Safari/537.36';

/** HTML to readable text: scripts, styles and tags dropped, entities decoded, whitespace folded. */
export function aiHtmlText(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, ' ')
    .replace(/<(br|\/p|\/div|\/li|\/h[1-6]|\/tr)[^>]*>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"').replace(/&#39;|&#x27;/g, '\'').replace(/&ensp;|&emsp;/g, ' ')
    .replace(/&#x?[0-9a-fA-F]+;/g, ' ')
    .replace(/[ \t\r\f\v]+/g, ' ')
    .replace(/\n\s*\n+/g, '\n')
    .trim();
}

/** One search result as the model reads it. */
export class AiWebResult {
  title: string;
  url: string;
  snippet: string;

  constructor(title: string, url: string, snippet: string) {
    this.title = title;
    this.url = url;
    this.snippet = snippet;
  }
}

/** Results out of a Bing result page (each result is an <li class="b_algo"> with an <h2> link and a caption). */
export function aiParseBingResults(html: string, limit: number): AiWebResult[] {
  const results: AiWebResult[] = [];
  const blocks: string[] = html.split(/<li class="b_algo"/i).slice(1);
  for (const block of blocks) {
    if (results.length >= limit) { break; }
    const link: RegExpMatchArray | null = block.match(/<h2[^>]*>\s*<a[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>/i);
    if (link === null) { continue; }
    const url: string = link[1].replace(/&amp;/g, '&');
    if (!url.startsWith('http')) { continue; }
    const caption: RegExpMatchArray | null = block.match(/<p[^>]*>([\s\S]*?)<\/p>/i);
    results.push(new AiWebResult(aiHtmlText(link[2]).slice(0, 120), url, caption !== null ? aiHtmlText(caption[1]).slice(0, 240) : ''));
  }
  return results;
}

async function getText(url: string): Promise<string> {
  const client: http.HttpRequest = http.createHttp();
  try {
    const header: Record<string, string> = {};
    header['User-Agent'] = USER_AGENT;
    header['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.6';
    const response: http.HttpResponse = await client.request(url, {
      method: http.RequestMethod.GET, header: header, expectDataType: http.HttpDataType.STRING, usingCache: false,
      connectTimeout: WEB_TIMEOUT_MS, readTimeout: WEB_TIMEOUT_MS, maxLimit: WEB_MAX_BYTES
    });
    if (response.responseCode < 200 || response.responseCode >= 400) {
      throw new Error('网页返回 ' + response.responseCode.toString());
    }
    return String(response.result);
  } finally { client.destroy(); }
}

/**
 * 联网搜索 for the AI: the query goes to Bing (cn.bing.com, reachable in mainland China) and the first results —
 * title, address, summary — come back as text for the model. Only the query leaves the device.
 */
export async function aiWebSearch(query: string): Promise<string> {
  const q: string = query.trim().slice(0, 200);
  if (q === '') { return '没有搜索：关键词为空。'; }
  try {
    const html: string = await getText('https://cn.bing.com/search?q=' + encodeURIComponent(q) + '&setlang=zh-Hans&cc=CN');
    const results: AiWebResult[] = aiParseBingResults(html, 6);
    hilog.info(0x0000, 'AiChat', 'web search results=%{public}s', results.length.toString());
    if (results.length === 0) { return '没有搜到「' + q + '」的结果，可以换个说法再搜。'; }
    return '「' + q + '」的搜索结果（来自必应）：\n' + results.map((r: AiWebResult, i: number): string =>
      (i + 1).toString() + '. ' + r.title + '\n   ' + r.url + (r.snippet !== '' ? '\n   ' + r.snippet : '')).join('\n') +
      '\n需要细节时可以用 read_webpage 读其中一个网址；回答时说明信息来自网络。';
  } catch (error) {
    const why: string = error instanceof Error ? error.message : '网络不可用';
    hilog.warn(0x0000, 'AiChat', 'web search failed %{public}s', why);
    return '搜索失败（' + why + '），请稍后再试或告诉用户暂时无法联网搜索。';
  }
}

/** The readable text of a web page (https only), cut to a size the model can take. */
export async function aiReadWebpage(url: string): Promise<string> {
  const target: string = url.trim();
  if (!target.startsWith('https://') && !target.startsWith('http://')) { return '只能读取 http(s) 网址。'; }
  try {
    const html: string = await getText(target);
    const title: RegExpMatchArray | null = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
    const text: string = aiHtmlText(html);
    if (text.length < 40) { return '这个网页没有可读的正文（可能需要登录或由脚本生成）。'; }
    return (title !== null ? '标题：' + aiHtmlText(title[1]).slice(0, 120) + '\n' : '') + '网址：' + target + '\n正文：\n' +
      text.slice(0, PAGE_CHARS) + (text.length > PAGE_CHARS ? '\n（正文较长，只读取了开头）' : '');
  } catch (error) {
    return '读取失败：' + (error instanceof Error ? error.message : '网络不可用');
  }
}
