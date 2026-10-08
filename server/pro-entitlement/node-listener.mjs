import { createServer } from 'node:http';
import { Readable } from 'node:stream';

// Bind this listener to a private interface behind a configured HTTPS ingress.
// Forwarded headers never supply an owner or credentials to the application.
export function createProNodeListener(api) {
  const server = createServer({ maxHeaderSize: 24576 }, async (incoming, outgoing) => {
    const controller = new AbortController();
    const deadline = setTimeout(() => { controller.abort(); outgoing.destroy(); }, 60000);
    const closed = () => { if (!outgoing.writableFinished) controller.abort(); };
    outgoing.on('close', closed);
    try {
      if (!incoming.url?.startsWith('/') || incoming.url.startsWith('//')) throw new Error('invalid_path');
      const headers = new Headers();
      for (let i = 0; i < incoming.rawHeaders.length; i += 2) headers.append(incoming.rawHeaders[i], incoming.rawHeaders[i + 1]);
      const request = new Request('http://127.0.0.1' + incoming.url, { method: incoming.method, headers,
        signal: controller.signal, ...(incoming.method !== 'GET' && incoming.method !== 'HEAD' ?
          { body: Readable.toWeb(incoming), duplex: 'half' } : {}) });
      const result = await api.handle(request);
      if (controller.signal.aborted || outgoing.destroyed) return;
      outgoing.writeHead(result.status, Object.fromEntries(result.headers));
      outgoing.end(Buffer.from(await result.arrayBuffer()));
    } catch {
      if (!outgoing.headersSent && !outgoing.destroyed) {
        outgoing.writeHead(400, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
        outgoing.end('{"error":"invalid_request"}');
      } else outgoing.destroy();
    } finally { clearTimeout(deadline); outgoing.removeListener('close', closed); }
  });
  server.requestTimeout = 15000; server.headersTimeout = 10000; server.keepAliveTimeout = 5000;
  server.maxHeadersCount = 32; server.maxConnections = 64;
  return server;
}
