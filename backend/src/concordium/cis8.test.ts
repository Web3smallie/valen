import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  deriveEvmAddress,
  encodeExternalKeyId,
  parseOwnerOfKeyResponse,
  secp256k1X,
  verifyBinding,
} from './cis8.js';
import type { ConcordiumNode } from './node.js';
import { ConcordiumError, type EvmAddress } from './types.js';
import type { ExternalKeyId } from './cis8.js';

const fixtureDir = join(dirname(fileURLToPath(import.meta.url)), 'testdata');
interface KeyFixture {
  query: { namespace: string; keyType: string; pubkey: string };
  returnValue: string;
}
const consistent = JSON.parse(
  readFileSync(join(fixtureDir, 'ownerOfKey-consistent.json'), 'utf8'),
) as KeyFixture;
const displaced = JSON.parse(
  readFileSync(join(fixtureDir, 'ownerOfKey-displaced.json'), 'utf8'),
) as KeyFixture;

// Independently derived with `cast keccak` (outside this module).
const TOKEN30_ADDRESS = '0x88dc41fe71c180ac0628ebb8c126db866b58fb3d';
const TOKEN25_ADDRESS = '0xfa7840126d187f9f86ed64bfe82d1614f72bcf6e';
const TOKEN25_OWNER_HEX = 'e3241c77e32d6c1d7ae00e83ad4f5f8f18ed7d802bcf73a0bc01d32d610020ce';
const TOKEN25_AGENT_OWNER_HEX = 'af2874eeb46f3c8080ba90999d9c42edf20d5c9a19e366463ce9c4bf72ce70db';
/** Live-recorded compressed form: the registry echoes the token-25 key compressed. */
function liveCompressedToken25(): string {
  const parsed = parseOwnerOfKeyResponse(displaced.returnValue);
  if (!parsed.found) {
    throw new Error('fixture must contain the live binding');
  }
  return parsed.publicKeyHex;
}

function expectCode(fn: () => unknown, code: string): void {
  try {
    fn();
  } catch (error) {
    expect(error).toBeInstanceOf(ConcordiumError);
    expect((error as ConcordiumError).code).toBe(code);
    return;
  }
  throw new Error(`expected ConcordiumError(${code}), nothing thrown`);
}

async function expectCodeAsync(fn: () => Promise<unknown>, code: string): Promise<void> {
  try {
    await fn();
  } catch (error) {
    expect(error).toBeInstanceOf(ConcordiumError);
    expect((error as ConcordiumError).code).toBe(code);
    return;
  }
  throw new Error(`expected ConcordiumError(${code}), nothing thrown`);
}

function mockNode(returnHex: string): ConcordiumNode {
  return {
    getAccount: async () => {
      throw new Error('unused');
    },
    getAccountByCredId: async () => {
      throw new Error('unused');
    },
    invokeOwnerOfKey: async () => returnHex,
    invokeAgentOf: async () => {
      throw new Error('unused');
    },
    getGlobalContext: async () => ({}),
    getBestBlockHeight: async () => '1',
  };
}

function asKeyId(query: { namespace: string; keyType: string; pubkey: string }): ExternalKeyId {
  return { namespace: query.namespace, keyType: query.keyType, publicKeyHex: query.pubkey };
}

describe('encodeExternalKeyId', () => {
  it('encodes the exact live-verified wire bytes', () => {
    const expected =
      '08000000' +
      Buffer.from('eip155:1', 'utf8').toString('hex') +
      '16000000' +
      Buffer.from('secp256k1-uncompressed', 'utf8').toString('hex') +
      '41000000' +
      asKeyId(consistent.query).publicKeyHex.toLowerCase();
    expect(encodeExternalKeyId(asKeyId(consistent.query))).toBe(expected);
  });
});

describe('parseOwnerOfKeyResponse (live-recorded)', () => {
  it('parses the consistent binding', () => {
    const parsed = parseOwnerOfKeyResponse(consistent.returnValue);
    expect(parsed.found).toBe(true);
    if (!parsed.found) {
      throw new Error('unreachable');
    }
    expect(parsed.ownerHex).toBe('70ba750ec3ea77b6e7af7d11921bb724e49f4dd4f54029891ee419bc00b10a0e');
    expect(parsed.status).toBe('Active');
    expect(parsed.proofScheme).toBe('ethereum-personal-sign');
    expect(parsed.lastUpdatedMs).toBeGreaterThan(Date.UTC(2026, 0, 1));
  });

  it('parses the displaced binding (owner differs from the agent owner)', () => {
    const parsed = parseOwnerOfKeyResponse(displaced.returnValue);
    expect(parsed.found).toBe(true);
    if (!parsed.found) {
      throw new Error('unreachable');
    }
    expect(parsed.ownerHex).toBe(TOKEN25_OWNER_HEX);
    expect(parsed.status).toBe('Active');
  });

  it('treats 0x00 as not-found and rejects malformed responses', () => {
    expect(parseOwnerOfKeyResponse('00')).toEqual({ found: false });
    expect(parseOwnerOfKeyResponse('0x00')).toEqual({ found: false });
    expectCode(() => parseOwnerOfKeyResponse(''), 'NODE_ERROR');
    expectCode(() => parseOwnerOfKeyResponse('02'), 'NODE_ERROR');
    expectCode(() => parseOwnerOfKeyResponse(consistent.returnValue.slice(0, 100)), 'NODE_ERROR');
  });

  it('tolerates trailing bytes (deployed contracts append fields)', () => {
    const withTrailing = `${consistent.returnValue}deadbeef`;
    const parsed = parseOwnerOfKeyResponse(withTrailing);
    expect(parsed.found).toBe(true);
  });
});

describe('secp256k1 normalization and EVM derivation', () => {
  it('normalizes compressed and uncompressed forms to one x-coordinate', () => {
    const uncompressed = asKeyId(displaced.query).publicKeyHex;
    const compressed = liveCompressedToken25();
    expect(compressed).toMatch(/^0[23][0-9a-f]{64}$/);
    expect(secp256k1X(uncompressed)).toBe(secp256k1X(compressed));
    expect(secp256k1X(uncompressed)).toBe(uncompressed.slice(2, 66));
  });

  it('rejects malformed keys', () => {
    expectCode(() => secp256k1X('zz'), 'CIS8_KEY_MALFORMED');
    expectCode(() => secp256k1X(`05${'11'.repeat(32)}`), 'CIS8_KEY_MALFORMED');
    expectCode(() => deriveEvmAddress(`02${'00'.repeat(32)}`), 'CIS8_KEY_MALFORMED');
  });

  it('re-derives live testnet addresses exactly (cast cross-checked)', () => {
    // Token-25 key also resolves through the live-recorded compressed form
    // (exercises the noble/curves decompression path against the same address).
    expect(deriveEvmAddress(asKeyId(displaced.query).publicKeyHex)).toBe(TOKEN25_ADDRESS);
    expect(deriveEvmAddress(liveCompressedToken25())).toBe(TOKEN25_ADDRESS);
    expect(deriveEvmAddress(asKeyId(consistent.query).publicKeyHex)).toBe(TOKEN30_ADDRESS);
  });
});

describe('verifyBinding', () => {
  const baseExpectation = {
    namespacePattern: /^eip155:\d+$/,
    allowedKeyTypes: ['secp256k1-uncompressed', 'secp256k1-compressed'],
    allowedProofSchemes: ['ethereum-personal-sign'],
  };

  it('accepts the consistent live binding', async () => {
    const verified = await verifyBinding(
      mockNode(consistent.returnValue),
      12801n,
      0n,
      asKeyId(consistent.query),
      {
        ...baseExpectation,
        expectedOwnerHex: '70ba750ec3ea77b6e7af7d11921bb724e49f4dd4f54029891ee419bc00b10a0e',
        expectedWallet: TOKEN30_ADDRESS as EvmAddress,
      },
    );
    expect(verified.address).toBe(TOKEN30_ADDRESS);
    expect(verified.proofScheme).toBe('ethereum-personal-sign');
  });

  it('rejects the displaced live binding on owner mismatch', async () => {
    await expectCodeAsync(
      () =>
        verifyBinding(
          mockNode(displaced.returnValue),
          12801n,
          0n,
          asKeyId(displaced.query),
          {
            ...baseExpectation,
            // The AGENT owner (af28..), not the current key owner (e324..).
            expectedOwnerHex: TOKEN25_AGENT_OWNER_HEX,
            expectedWallet: TOKEN25_ADDRESS as EvmAddress,
          },
        ),
      'CIS8_OWNER_MISMATCH',
    );
  });

  it('rejects absent and revoked bindings', async () => {
    await expectCodeAsync(
      () =>
        verifyBinding(mockNode('00'), 12801n, 0n, asKeyId(consistent.query), {
          ...baseExpectation,
          expectedOwnerHex: '70ba750ec3ea77b6e7af7d11921bb724e49f4dd4f54029891ee419bc00b10a0e',
          expectedWallet: TOKEN30_ADDRESS as EvmAddress,
        }),
      'CIS8_NOT_FOUND',
    );
    // Synthetic revoked record: same shape as live data, status byte 0x01.
    // Lengths: ns 8, keyType 20, key 33, scheme 22.
    const syntheticRevoked =
      `01${'11'.repeat(32)}` +
      `08000000${Buffer.from('eip155:1', 'utf8').toString('hex')}` +
      `14000000${Buffer.from('secp256k1-compressed', 'utf8').toString('hex')}` +
      `21000000${'02'}${'22'.repeat(32)}` +
      `16000000${Buffer.from('ethereum-personal-sign', 'utf8').toString('hex')}` +
      `00000000` +
      `01` +
      `0000000000000000`;
    await expectCodeAsync(
      () =>
        verifyBinding(mockNode(syntheticRevoked), 12801n, 0n, {
          namespace: 'eip155:1',
          keyType: 'secp256k1-compressed',
          publicKeyHex: `02${'22'.repeat(32)}`,
        }, {
          ...baseExpectation,
          expectedOwnerHex: '11'.repeat(32),
          // Revocation throws before derivation runs, so any wallet works here.
          expectedWallet: TOKEN30_ADDRESS as EvmAddress,
        }),
      'CIS8_REVOKED',
    );
  });

  it('rejects wrong namespace family, key type, and wallet', async () => {
    const expectation = {
      ...baseExpectation,
      expectedOwnerHex: '70ba750ec3ea77b6e7af7d11921bb724e49f4dd4f54029891ee419bc00b10a0e',
      expectedWallet: TOKEN30_ADDRESS as EvmAddress,
    };
    let rpcCalls = 0;
    const countingNode = mockNode(consistent.returnValue);
    const counting = {
      ...countingNode,
      invokeOwnerOfKey: async (...args: [bigint, bigint, string]) => {
        rpcCalls += 1;
        return countingNode.invokeOwnerOfKey(...args);
      },
    };
    await expectCodeAsync(
      () => verifyBinding(counting, 12801n, 0n, { namespace: 'solana:mainnet', keyType: 'ed25519', publicKeyHex: '11'.repeat(32) }, expectation),
      'CIS8_NAMESPACE_REJECTED',
    );
    await expectCodeAsync(
      () => verifyBinding(counting, 12801n, 0n, { namespace: 'eip155:1', keyType: 'ed25519', publicKeyHex: '11'.repeat(32) }, expectation),
      'CIS8_KEYTYPE_REJECTED',
    );
    expect(rpcCalls).toBe(0);
    await expectCodeAsync(
      () =>
        verifyBinding(mockNode(consistent.returnValue), 12801n, 0n, asKeyId(consistent.query), {
          ...expectation,
          expectedWallet: '0x0000000000000000000000000000000000000001' as EvmAddress,
        }),
      'EVM_DERIVATION_MISMATCH',
    );
  });

  it('rejects a non-allowlisted proof scheme', async () => {
    const realScheme = `16000000${Buffer.from('ethereum-personal-sign', 'utf8').toString('hex')}`;
    expect(consistent.returnValue).toContain(realScheme);
    // Same byte length keeps the length-prefixed layout valid.
    const otherSchemeName = 'unsupported-scheme-000';
    expect(otherSchemeName).toHaveLength('ethereum-personal-sign'.length);
    const reschemed = consistent.returnValue.replace(
      realScheme,
      `16000000${Buffer.from(otherSchemeName, 'utf8').toString('hex')}`,
    );
    await expectCodeAsync(
      () =>
        verifyBinding(mockNode(reschemed), 12801n, 0n, asKeyId(consistent.query), {
          ...baseExpectation,
          expectedOwnerHex: '70ba750ec3ea77b6e7af7d11921bb724e49f4dd4f54029891ee419bc00b10a0e',
          expectedWallet: TOKEN30_ADDRESS as EvmAddress,
        }),
      'CIS8_PROOF_SCHEME_REJECTED',
    );
    // The same record verifies when its scheme is explicitly allowlisted.
    const verified = await verifyBinding(mockNode(reschemed), 12801n, 0n, asKeyId(consistent.query), {
      ...baseExpectation,
      allowedProofSchemes: [otherSchemeName],
      expectedOwnerHex: '70ba750ec3ea77b6e7af7d11921bb724e49f4dd4f54029891ee419bc00b10a0e',
      expectedWallet: TOKEN30_ADDRESS as EvmAddress,
    });
    expect(verified.proofScheme).toBe(otherSchemeName);
  });

  it('rejects echoed-key mismatch and propagates node failures closed', async () => {
    // Flip one nibble inside the echoed public key's x-coordinate.
    const tampered = consistent.returnValue.replace('0238d232', '0238d233');
    expect(tampered).not.toBe(consistent.returnValue);
    await expectCodeAsync(
      () =>
        verifyBinding(mockNode(tampered), 12801n, 0n, asKeyId(consistent.query), {
          ...baseExpectation,
          expectedOwnerHex: '70ba750ec3ea77b6e7af7d11921bb724e49f4dd4f54029891ee419bc00b10a0e',
          expectedWallet: TOKEN30_ADDRESS as EvmAddress,
        }),
      'NODE_ERROR',
    );
    const failing: ConcordiumNode = {
      getAccount: async () => {
        throw new Error('unused');
      },
      getAccountByCredId: async () => {
        throw new Error('unused');
      },
      invokeOwnerOfKey: async () => {
        throw new Error('boom');
      },
      invokeAgentOf: async () => {
        throw new Error('unused');
      },
      getGlobalContext: async () => ({}),
      getBestBlockHeight: async () => '1',
    };
    await expectCodeAsync(
      () =>
        verifyBinding(failing, 12801n, 0n, asKeyId(consistent.query), {
          ...baseExpectation,
          expectedOwnerHex: '70ba750ec3ea77b6e7af7d11921bb724e49f4dd4f54029891ee419bc00b10a0e',
          expectedWallet: TOKEN30_ADDRESS as EvmAddress,
        }),
      'NODE_ERROR',
    );
  });
});
