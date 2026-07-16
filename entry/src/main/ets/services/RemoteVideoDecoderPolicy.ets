export function shouldInitializeRemoteVideoDecoder(protocol: string): boolean {
  return protocol === 'rustdesk';
}
