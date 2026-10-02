/** Public, user-initiated handoff. Never expose provider keys in a URL. */
export function liveLearnSelectionURL(text: string): string | null {
  const value = text.trim()
  if (!value || new TextEncoder().encode(value).length > 262_144) return null
  return `livelearn://translate?text=${encodeURIComponent(value)}`
}
