import { describe, expect, it } from 'vitest';
import { runControlRead, type ArcStorageTransport } from '../src/arc/control.js';

const ADDRESS = '0x253B68c7a2D646561387Dc0958A6C176a30a6f8d';
const SLOT = '0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300';
const OWNER = '0x000000000000000000000000b0e8ba6afe21371ad4001e611224fc200fd10144';

function stubTransport(values: Record<string, string>, failOn?: string): ArcStorageTransport {
  return {
    readOwnerCall: () => Promise.resolve(OWNER),
    readStorage: (_address, _slot, block) => {
      const key = typeof block === 'bigint' ? `number:${block.toString()}` : `tag:${block}`;
      if (failOn === key) {
        return Promise.reject(new Error('transport down'));
      }
      return Promise.resolve(values[key] ?? OWNER);
    },
  };
}

describe('control read', () => {
  it('passes when every read matches', async () => {
    const result = await runControlRead(stubTransport({}), {
      address: ADDRESS,
      slot: SLOT,
      blocks: ['latest', 'finalized', 'safe', 74216459n],
    });
    expect(result.expected).toBe(OWNER.toLowerCase());
    expect(result.allMatch).toBe(true);
    expect(result.entries).toHaveLength(4);
  });

  it('fails when any single read differs', async () => {
    const result = await runControlRead(stubTransport({ 'tag:finalized': `0x${'00'.repeat(32)}` }), {
      address: ADDRESS,
      slot: SLOT,
      blocks: ['latest', 'finalized'],
    });
    expect(result.allMatch).toBe(false);
    expect(result.entries[1]?.match).toBe(false);
  });

  it('rejects malformed words instead of comparing them', async () => {
    await expect(
      runControlRead(stubTransport({ 'tag:latest': 'not-hex' }), {
        address: ADDRESS,
        slot: SLOT,
        blocks: ['latest'],
      }),
    ).rejects.toThrowError();
  });

  it('propagates transport errors instead of passing', async () => {
    await expect(
      runControlRead(stubTransport({}, 'tag:latest'), {
        address: ADDRESS,
        slot: SLOT,
        blocks: ['latest'],
      }),
    ).rejects.toThrowError('transport down');
  });

  it('refuses an empty block list', async () => {
    await expect(
      runControlRead(stubTransport({}), { address: ADDRESS, slot: SLOT, blocks: [] }),
    ).rejects.toThrowError();
  });
});
