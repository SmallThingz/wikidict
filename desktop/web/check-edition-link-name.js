// A DOM screening heuristic. Confirm reported candidates in the browser accessibility tree.
export function linkNameCandidate(link) {
  const normalize = value => (value ?? '').normalize('NFC').replace(/\s+/gu, ' ').trim();
  const explicit = normalize(link.getAttribute('aria-label'));
  if (explicit) return explicit;
  const text = normalize(link.textContent);
  if (text) return text;
  const images = [...link.querySelectorAll('img,[role="img"]')].map(image =>
    normalize(image.getAttribute('aria-label')) || normalize(image.getAttribute('alt')));
  return normalize(images.join(' ')) || normalize(link.getAttribute('title'));
}
