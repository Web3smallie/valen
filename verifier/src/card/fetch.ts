import { createHash } from 'node:crypto';

/**
 * Agent Card retrieval with a strict URL policy. The URL comes verbatim
 * from the chain (never normalized, never rewritten): whatever the
 * registry says is what gets fetched, and the policy below decides
 * whether fetching is even attempted.
 */

export class CardFetchError extends Error {}

export interface FetchedCard {
  readonly url: string;
  readonly status: number;
  readonly bytes: Buffer;
  readonly sha256Hex: string;
  readonly json: unknown;
}

export type FetchFunction = (url: string, init?: RequestInit) => Promise<Response>;

/** Maximum acceptable card body: 1 MiB (the live card is ~9 KB). */
export const MAX_CARD_BYTES = 1024 * 1024;

/** Single-request timeout: 20 seconds. */
const FETCH_TIMEOUT_MS = 20000;

/**
 * URL policy for agent_uri values. HTTPS only; no query string; no
 * fragment; path must contain a full 40-hex commit segment, which rules
 * out branch names, tags, and shortened hashes without enumerating them.
 */
export function assertPinnedHttpsUrl(url: string): void {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    throw new CardFetchError('agent_uri is not a valid URL');
  }
  if (parsed.protocol !== 'https:') {
    throw new CardFetchError('agent_uri must use HTTPS');
  }
  if (parsed.search !== '' || parsed.hash !== '') {
    throw new CardFetchError('agent_uri must not carry a query string or fragment');
  }
  const segments = parsed.pathname.split('/').filter((part) => part.length > 0);
  const pinned = segments.some((part) => /^[0-9a-f]{40}$/.test(part));
  if (!pinned) {
    throw new CardFetchError('agent_uri path must contain a full 40-hex commit segment');
  }
}

async function readBoundedBody(response: Response, limit: number): Promise<Buffer> {
  const reader = response.body?.getReader();
  if (!reader) {
    throw new CardFetchError('empty response body');
  }
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    total += value.length;
    if (total > limit) {
      try {
        await reader.cancel();
      } catch {
        /* ignored: already over budget */
      }
      throw new CardFetchError(`card body exceeds ${limit} bytes`);
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks);
}

/**
 * Fetch the card at exactly `url` (the on-chain string, untouched).
 * Rejects redirects, non-200 statuses, oversized bodies, and non-JSON.
 */
export async function fetchCard(url: string, fetchFn: FetchFunction = fetch): Promise<FetchedCard> {
  assertPinnedHttpsUrl(url);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  let response: Response;
  try {
    response = await fetchFn(url, { redirect: 'error', signal: controller.signal });
  } catch (error) {
    throw new CardFetchError(
      `fetch failed: ${error instanceof Error ? error.message.slice(0, 120) : String(error)}`,
    );
  } finally {
    clearTimeout(timer);
  }
  if (response.status !== 200) {
    throw new CardFetchError(`unexpected HTTP status ${response.status}`);
  }
  const bytes = await readBoundedBody(response, MAX_CARD_BYTES);
  let json: unknown;
  try {
    json = JSON.parse(bytes.toString('utf8'));
  } catch {
    throw new CardFetchError('card body is not valid JSON');
  }
  return {
    url,
    status: response.status,
    bytes,
    sha256Hex: createHash('sha256').update(bytes).digest('hex'),
    json,
  };
}
