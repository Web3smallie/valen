import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { PINNED } from '../src/config.js';
import type { ConcordiumTransports } from '../src/concordium/node.js';
import type { Cis8KeyId } from '../src/concordium/cis8.js';
import { printReport, runConcordiumChecks } from '../src/index.js';

const fixtures = join(dirname(fileURLToPath(import.meta.url)), 'fixtures');
const AGENT_OF_HEX = readFileSync(join(fixtures, 'agentof-1507.hex'), 'utf8').trim();
const OWNER_OF_KEY_HEX = readFileSync(join(fixtures, 'ownerofkey-valen.hex'), 'utf8').trim();
const CARD_BYTES = readFileSync(join(fixtures, 'agent-card.json'));
const CARD_URL =
  'https://raw.githubusercontent.com/Web3smallie/valen/9098748fabe8e1c0c633f4f9a0fe5db48cf85704/agent-card/agent-card.json';
const CARD_HASH = 'e1a8b6c9da17b8adbfd9351203bb76c406b3bbd75d1837f94a908c53f80cbfdc';
const OWNER_HEX = 'b376ffb2f41efa8a524ab6f6cf7b2f481c271d968ec21c4dd0a063647c516fea';
const OWNER_PUBKEY =
  '04e6a2ba9a7bafb29119156252e2e42e4e7695d478cb26a118ee83c0471beb9b2dc9b52073d094fdceb7aaf718b0c750905965cebed0df1e4aaa157ec3f9852cab';
const FINALIZED = { hash: 'aa'.repeat(32), height: '51321186' };

// --- synthetic record builders (independent byte-level construction) ---

function u64leHex(value: bigint): string {
  const buffer = Buffer.alloc(8);
  buffer.writeBigUInt64LE(value);
  return buffer.toString('hex');
}

function strEnc(text: string): string {
  const bytes = Buffer.from(text, 'utf8');
  const length = Buffer.alloc(4);
  length.writeUInt32LE(bytes.length);
  return Buffer.concat([length, bytes]).toString('hex');
}

interface AgentViewParts {
  tokenId?: bigint;
  ownerHex?: string;
  agentUri?: string | null;
  metadataHashHex?: string | null;
  extref?: {
    contractIndex: bigint;
    contractSubindex: bigint;
    namespace: string;
    keyType: string;
    publicKeyHex: string;
  } | null;
  status?: 'Active' | 'Revoked';
}

function buildAgentViewHex(parts: AgentViewParts = {}): string {
  const tokenId = parts.tokenId ?? 1507n;
  const ownerHex = (parts.ownerHex ?? OWNER_HEX).toLowerCase();
  const uri =
    parts.agentUri === undefined
      ? `01${strEnc(CARD_URL)}`
      : parts.agentUri === null
        ? '00'
        : `01${strEnc(parts.agentUri)}`;
  const hash =
    parts.metadataHashHex === undefined
      ? `01${CARD_HASH}`
      : parts.metadataHashHex === null
        ? '00'
        : `01${parts.metadataHashHex.toLowerCase()}`;
  let extref = '00';
  const ref =
    parts.extref === undefined
      ? {
          contractIndex: 12801n,
          contractSubindex: 0n,
          namespace: 'eip155:5042002',
          keyType: 'secp256k1-uncompressed',
          publicKeyHex: OWNER_PUBKEY,
        }
      : parts.extref;
  if (ref !== null) {
    const keyBytes = Buffer.from(ref.publicKeyHex, 'hex');
    const keyLength = Buffer.alloc(4);
    keyLength.writeUInt32LE(keyBytes.length);
    extref =
      '01' +
      u64leHex(ref.contractIndex) +
      u64leHex(ref.contractSubindex) +
      '00' +
      strEnc(ref.namespace) +
      strEnc(ref.keyType) +
      keyLength.toString('hex') +
      keyBytes.toString('hex');
  }
  return (
    '01' +
    `08${u64leHex(tokenId)}` +
    ownerHex +
    uri +
    hash +
    extref +
    `01${OWNER_HEX.toLowerCase()}` +
    (parts.status === 'Revoked' ? '01' : '00') +
    u64leHex(1795627608075n) +
    '00' +
    '00'
  );
}

interface RegistrationParts {
  ownerHex?: string;
  namespace?: string;
  keyType?: string;
  publicKeyHex?: string;
  proofScheme?: string;
  status?: 'Active' | 'Revoked';
}

function buildRegistrationHex(parts: RegistrationParts = {}): string {
  const keyBytes = Buffer.from(parts.publicKeyHex ?? OWNER_PUBKEY, 'hex');
  const keyLength = Buffer.alloc(4);
  keyLength.writeUInt32LE(keyBytes.length);
  return (
    '01' +
    (parts.ownerHex ?? OWNER_HEX).toLowerCase() +
    strEnc(parts.namespace ?? 'eip155:5042002') +
    strEnc(parts.keyType ?? 'secp256k1-uncompressed') +
    keyLength.toString('hex') +
    keyBytes.toString('hex') +
    strEnc(parts.proofScheme ?? 'ethereum-personal-sign') +
    '00000000' +
    (parts.status === 'Revoked' ? '01' : '00') +
    u64leHex(1795605602075n)
  );
}

// --- stub world ---

interface CardResponse {
  readonly status: number;
  readonly body: Buffer;
  readonly throws?: string;
}

interface StubWorld {
  agentOfResponses?: string[];
  ownerOfKey?: string | Error;
  agentByExtRef?: string | Error;
  cards?: Record<string, CardResponse>;
  failFinalized?: boolean;
}

function stubNode(world: StubWorld): ConcordiumTransports {
  let agentOfCalls = 0;
  return {
    endpoint: 'stub:concordium-testnet',
    getFinalizedBlock: () => {
      if (world.failFinalized) {
        return Promise.reject(new Error('consensus unavailable'));
      }
      return Promise.resolve({ ...FINALIZED });
    },
    invokeAgentOf: () => {
      const list = world.agentOfResponses ?? [AGENT_OF_HEX];
      const next = list[Math.min(agentOfCalls, list.length - 1)] as string;
      agentOfCalls += 1;
      return Promise.resolve(next);
    },
    invokeOwnerOfKey: () => {
      const value = world.ownerOfKey ?? OWNER_OF_KEY_HEX;
      return value instanceof Error ? Promise.reject(value) : Promise.resolve(value);
    },
    invokeAgentByExternalReference: () => {
      const value = world.agentByExtRef ?? AGENT_OF_HEX;
      return value instanceof Error ? Promise.reject(value) : Promise.resolve(value);
    },
  };
}

function stubFetch(world: StubWorld): (url: string) => Promise<Response> {
  return (url: string) => {
    const entry = world.cards?.[url];
    if (!entry) {
      return Promise.reject(new Error(`unexpected fetch: ${url.slice(0, 80)}`));
    }
    if (entry.throws) {
      return Promise.reject(new Error(entry.throws));
    }
    return Promise.resolve(new Response(new Uint8Array(entry.body), { status: entry.status }));
  };
}

function happyWorld(): StubWorld {
  return { cards: { [CARD_URL]: { status: 200, body: CARD_BYTES } } };
}

async function verdictOf(world: StubWorld): Promise<string> {
  const report = await runConcordiumChecks({ node: stubNode(world), fetchFn: stubFetch(world) }, PINNED);
  return report.verdict;
}

describe('happy path (live-recorded fixtures)', () => {
  it('passes every check end to end', async () => {
    const report = await runConcordiumChecks({ node: stubNode(happyWorld()), fetchFn: stubFetch(happyWorld()) }, PINNED);
    expect(report.verdict).toBe('PASS');
    expect(report.checks.map((c) => `${c.name}=${c.verdict}`).join(' ')).toBe(
      '1-badge=PASS 2-agentOf=PASS 3-card=PASS 4-badge-block=PASS 5-cis8=PASS 6-toctou=PASS',
    );
    const printed = printReport(report);
    expect(printed).toContain('VERDICT: PASS');
    expect(printed).toContain('JyP9YAskQ5pWBESxthBcf');
  });
});

describe('required negatives', () => {
  it('(1) one-byte card mutation fails the hash check', async () => {
    const mutated = Buffer.from(CARD_BYTES);
    mutated[mutated.length - 10] = (mutated[mutated.length - 10] as number) ^ 0xff;
    const world = happyWorld();
    world.cards = { [CARD_URL]: { status: 200, body: mutated } };
    expect(await verdictOf(world)).toBe('FAIL');
  });

  it('(2) unknown token fails', async () => {
    expect(await verdictOf({ ...happyWorld(), agentOfResponses: ['00'] })).toBe('FAIL');
  });

  it('(3) revoked agent fails', async () => {
    const world = happyWorld();
    world.agentOfResponses = [buildAgentViewHex({ status: 'Revoked' })];
    expect(await verdictOf(world)).toBe('FAIL');
  });

  it('(4) foreign binding owner fails', async () => {
    const world = happyWorld();
    world.ownerOfKey = buildRegistrationHex({ ownerHex: '11'.repeat(32) });
    expect(await verdictOf(world)).toBe('FAIL');
  });

  it('(5) non-200 card fetch fails overall', async () => {
    const world = happyWorld();
    world.cards = { [CARD_URL]: { status: 503, body: Buffer.from('{}') } };
    expect(await verdictOf(world)).toBe('FAIL');
  });

  it('(6) master URL fails before any fetch', async () => {
    let fetched = false;
    const world = happyWorld();
    world.agentOfResponses = [
      buildAgentViewHex({
        agentUri: 'https://raw.githubusercontent.com/Web3smallie/valen/master/agent-card/agent-card.json',
      }),
    ];
    const report = await runConcordiumChecks(
      {
        node: stubNode(world),
        fetchFn: () => {
          fetched = true;
          return Promise.resolve(new Response('{}'));
        },
      },
      PINNED,
    );
    expect(report.verdict).toBe('FAIL');
    expect(fetched).toBe(false);
  });
});

describe('additional negatives', () => {
  it('checksum-tampered badge fails', async () => {
    const bad = { ...PINNED, badgeCaip19: 'ccd:4221332d34e1694168c2a0c0b3fd0f27/cis-2:JyP9YAskQ5pWBESxthBcg' };
    const report = await runConcordiumChecks({ node: stubNode(happyWorld()), fetchFn: stubFetch(happyWorld()) }, bad);
    expect(report.verdict).toBe('FAIL');
  });

  it('wrong-genesis badge fails', async () => {
    const bad = { ...PINNED, badgeCaip19: 'ccd:00000000000000000000000000000000/cis-2:JyP9YAskQ5pWBESxthBcf' };
    const report = await runConcordiumChecks({ node: stubNode(happyWorld()), fetchFn: stubFetch(happyWorld()) }, bad);
    expect(report.verdict).toBe('FAIL');
  });

  it('wrong-contract badge fails', async () => {
    const { encodeBadgeShortForm } = await import('../src/concordium/badge.js');
    const foreign = encodeBadgeShortForm(99999n, 0n, 1507n);
    const bad = { ...PINNED, badgeCaip19: `ccd:4221332d34e1694168c2a0c0b3fd0f27/cis-2:${foreign}` };
    const report = await runConcordiumChecks({ node: stubNode(happyWorld()), fetchFn: stubFetch(happyWorld()) }, bad);
    expect(report.verdict).toBe('FAIL');
  });

  it('extref pointing at a foreign CIS-8 contract fails', async () => {
    const world = happyWorld();
    world.agentOfResponses = [
      buildAgentViewHex({
        extref: {
          contractIndex: 99999n,
          contractSubindex: 0n,
          namespace: 'eip155:5042002',
          keyType: 'secp256k1-uncompressed',
          publicKeyHex: OWNER_PUBKEY,
        },
      }),
    ];
    expect(await verdictOf(world)).toBe('FAIL');
  });

  it('binding owner differing from agent owner fails', async () => {
    const world = happyWorld();
    world.ownerOfKey = buildRegistrationHex({ ownerHex: '22'.repeat(32) });
    expect(await verdictOf(world)).toBe('FAIL');
  });

  it('hash mismatch fails even with a valid pinned URL', async () => {
    const world = happyWorld();
    world.agentOfResponses = [buildAgentViewHex({ metadataHashHex: 'ab'.repeat(32) })];
    expect(await verdictOf(world)).toBe('FAIL');
  });

  it('non-JSON card fails', async () => {
    const world = happyWorld();
    world.cards = { [CARD_URL]: { status: 200, body: Buffer.from('not json {{{') } };
    expect(await verdictOf(world)).toBe('FAIL');
  });

  it('oversized card fails', async () => {
    const world = happyWorld();
    world.cards = { [CARD_URL]: { status: 200, body: Buffer.alloc(1024 * 1024 + 1, 120) } };
    expect(await verdictOf(world)).toBe('FAIL');
  });

  it('redirecting fetch fails', async () => {
    const world = happyWorld();
    world.cards = { [CARD_URL]: { status: 200, body: CARD_BYTES, throws: 'redirect blocked' } };
    expect(await verdictOf(world)).toBe('FAIL');
  });

  it('missing on-chain URI fails', async () => {
    const world = happyWorld();
    world.agentOfResponses = [buildAgentViewHex({ agentUri: null })];
    expect(await verdictOf(world)).toBe('FAIL');
  });

  it('missing on-chain hash fails', async () => {
    const world = happyWorld();
    world.agentOfResponses = [buildAgentViewHex({ metadataHashHex: null })];
    expect(await verdictOf(world)).toBe('FAIL');
  });

  it('TOCTOU change fails', async () => {
    const world = happyWorld();
    world.agentOfResponses = [AGENT_OF_HEX, buildAgentViewHex({ status: 'Revoked' })];
    expect(await verdictOf(world)).toBe('FAIL');
  });

  it('transport failure fails overall (never passes)', async () => {
    const failing: ConcordiumTransports = {
      endpoint: 'stub:down',
      getFinalizedBlock: () => Promise.resolve({ ...FINALIZED }),
      invokeAgentOf: () => Promise.reject(new Error('node unreachable')),
      invokeOwnerOfKey: () => Promise.reject(new Error('node unreachable')),
      invokeAgentByExternalReference: () => Promise.reject(new Error('node unreachable')),
    };
    const report = await runConcordiumChecks({ node: failing, fetchFn: stubFetch(happyWorld()) }, PINNED);
    expect(report.verdict).toBe('FAIL');
  });

  it('finalized-block failure fails overall', async () => {
    expect(await verdictOf({ ...happyWorld(), failFinalized: true })).toBe('FAIL');
  });

  it('badge block token mismatch fails', async () => {
    const card = JSON.parse(CARD_BYTES.toString('utf8')) as Record<string, unknown>;
    const caps = card['capabilities'] as Record<string, unknown>;
    const exts = caps['extensions'] as Array<Record<string, unknown>>;
    (exts[0]?.['params'] as Record<string, unknown>)['tokenAddress'] =
      'ccd:4221332d34e1694168c2a0c0b3fd0f27/cis-2:AAAAAAAAAAAAAAAAAAAAAA';
    const world = happyWorld();
    // Serve tampered card from a DIFFERENT pinned URL is impossible (hash binds);
    // instead point the on-chain URI at a second pinned URL serving it with a matching hash.
    const otherUrl =
      'https://raw.githubusercontent.com/Web3smallie/valen/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/agent-card/agent-card.json';
    const body = Buffer.from(JSON.stringify(card));
    const { createHash } = await import('node:crypto');
    const hash = createHash('sha256').update(body).digest('hex');
    world.agentOfResponses = [buildAgentViewHex({ agentUri: otherUrl, metadataHashHex: hash })];
    world.cards = { [otherUrl]: { status: 200, body } };
    const report = await runConcordiumChecks(
      { node: stubNode(world), fetchFn: stubFetch(world) },
      PINNED,
    );
    expect(report.verdict).toBe('FAIL');
    const badgeBlock = report.checks.find((c) => c.name === '4-badge-block');
    expect(badgeBlock?.verdict).toBe('FAIL');
  });
});
