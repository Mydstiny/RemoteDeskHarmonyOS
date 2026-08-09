/** Pure mapping from persisted RustDesk host state to card badges. */
export function resolveRustDeskBadges(directEnabled: boolean, proManaged: boolean): string[] {
  const badges: string[] = [];
  if (proManaged) { badges.push('Pro'); }
  // Relay is the default transport and does not need a visible badge. Keep
  // only the exceptional route labels that help distinguish host behavior.
  if (directEnabled) { badges.push('直连'); }
  return badges;
}
