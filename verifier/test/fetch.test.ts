import { describe, expect, it } from 'vitest';
import { assertPinnedHttpsUrl, CardFetchError, fetchCard, MAX_CARD_BYTES } from '../src/card/fetch.js';

const PINNED =
  'https://raw.githubusercontent.com/Web3smallie/valen/9098748fabe8e1c0c633f4f9a0fe5db48cf85704/agent-card/agent-card.json';

function stubFetch(handler: (url: string) => Response): (url: string) => Promise<Response> {
  return (url: string) => Promise.resolve(handler(url));
}

function textResponse(body: string, status = 200): Response {
  return new Response(body, { status, headers: { 'Content-Type': 'application/json' } });
}

describe('URL policy', () => {
  it('accepts the pinned production URL', () => {
    expect(() => assertPinnedHttpsUrl(PINNED)).not.toThrow();
  });

  it('rejects branch names, tags, short hashes, and bad schemes', () => {
    const bad = [
      'https://raw.githubusercontent.com/Web3smallie/valen/master/agent-card/agent-card.json',
      'https://raw.githubusercontent.com/Web3smallie/valen/main/agent-card/agent-card.json',
      'https://raw.githubusercontent.com/Web3smallie/valen/v1.0.0/agent-card/agent-card.json',
      'https://raw.githubusercontent.com/Web3smallie/valen/9098748/agent-card/agent-card.json',
      'http://example.com/9098748fabe8e1c0c633f4f9a0fe5db48cf85704/card.json',
      `${PINNED}?x=1`,
      `${PINNED}#frag`,
      'not-a-url',
      '',
    ];
    for (const url of bad) {
      expect(() => assertPinnedHttpsUrl(url), url.slice(0, 60)).toThrowError(CardFetchError);
    }
  });
});

describe('fetchCard', () => {
  it('fetches exact bytes and hashes them', async () => {
    const body = '{"name":"Valen"}';
    const fetched = await fetchCard(PINNED, stubFetch(() => textResponse(body)));
    expect(fetched.url).toBe(PINNED);
    expect(fetched.status).toBe(200);
    expect(fetched.bytes.toString('utf8')).toBe(body);
    expect(fetched.json).toEqual({ name: 'Valen' });
    const { createHash } = await import('node:crypto');
    expect(fetched.sha256Hex).toBe(createHash('sha256').update(body).digest('hex'));
  });

  it('rejects non-200 responses', async () => {
    await expect(fetchCard(PINNED, stubFetch(() => textResponse('nope', 404)))).rejects.toThrowError(
      CardFetchError,
    );
  });

  it('rejects non-JSON bodies', async () => {
    await expect(fetchCard(PINNED, stubFetch(() => textResponse('not json {{{')))).rejects.toThrowError(
      CardFetchError,
    );
  });

  it('rejects oversized bodies without buffering them fully', async () => {
    const big = 'x'.repeat(MAX_CARD_BYTES + 1);
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(new TextEncoder().encode(big));
        controller.close();
      },
    });
    const res = new Response(stream, { status: 200 });
    await expect(fetchCard(PINNED, stubFetch(() => res))).rejects.toThrowError(CardFetchError);
  });

  it('propagates transport failures (redirects included)', async () => {
    await expect(
      fetchCard(PINNED, stubFetch(() => {
        throw new Error('redirect blocked');
      })),
    ).rejects.toThrowError(CardFetchError);
  });

  it('never fetches a rejected URL', async () => {
    let called = false;
    const spy = stubFetch(() => {
      called = true;
      return textResponse('{}');
    });
    await expect(
      fetchCard('https://raw.githubusercontent.com/Web3smallie/valen/master/agent-card/agent-card.json', spy),
    ).rejects.toThrowError(CardFetchError);
    expect(called).toBe(false);
  });
});
