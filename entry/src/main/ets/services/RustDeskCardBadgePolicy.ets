/** Pure mapping from persisted RustDesk host state to card badges. */
export function resolveRustDeskBadges(directEnabled: boolean, proManaged: boolean): string[] {
  const badges: string[] = [];
  if (proManaged) { badges.push('Pro'); }
  badges.push(directEnabled ? '直连' : '中继');
  return badges;
}
