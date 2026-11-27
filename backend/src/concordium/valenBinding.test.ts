import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { hashMessage, keccak256 } from 'viem';
import { describe, expect, it } from 'vitest';
import type { ExternalKeyId } from './cis8.js';
import type { ConcordiumNode } from './node.js';
import { ConcordiumError, type EvmAddress } from './types.js';
import {
  buildCis8CanonicalBytes,
  buildValenBindingKeyId,
  ethereumPersonalSignDigest,
  VALEN_ARC_OWNER,
  VALEN_CIS8_KEY_TYPE,
  VALEN_CIS8_NAMESPACE,
  VALEN_CIS8_PROOF_SCHEME,
  verifyArcContractOwners,
  verifyValenBinding,
} from './valenBinding.js';

// Designated identities for Valen's binding (live-verified: Concordium
// account standing + all 11 Arc owners read on-chain). Account updated
// to the current Valen service identity 4JnN (was 49BGJ at Step 2).
const CONCORDIUM_ACCOUNT = '4JnNAPh8mrS2BF2wcaB9Cdp83JscgvXuboxoUnnxesv39kcrCR';
const CONCORDIUM_OWNER_HEX = 'b376ffb2f41efa8a524ab6f6cf7b2f481c271d968ec21c4dd0a063647c516fea';
const ARC_OWNER = '0xB0E8Ba6aFe21371AD4001e611224FC200FD10144';
const ARC_OWNER_PUBKEY =
  '04e6a2ba9a7bafb29119156252e2e42e4e7695d478cb26a118ee83c0471beb9b2' +
  'dc9b52073d094fdceb7aaf718b0c750905965cebed0df1e4aaa157ec3f9852cab';
const TESTNET_GENESIS =
  '4221332d34e1694168c2a0c0b3fd0f273809612cb13d000d5c2e00e85f50f796';

// Official MCP `build_cis8_canonical_bytes` output for the exact Valen
// inputs above (testnet, 2026-11-23). Pins our local construction to
// the official tooling byte-for-byte.
const OFFICIAL_CANONICAL_HEX =
  '4349532d382f76312f63616e6f6e6963616c' +
  CONCORDIUM_OWNER_HEX +
  '0132000000000000' +
  '0000000000000000' +
  TESTNET_GENESIS +
  '0e0000006569703135353a35303432303032' +
  '0e0000006569703135353a35303432303032' +
  '16000000736563703235366b312d756e636f6d70726573736564' +
  '41000000' +
  ARC_OWNER_PUBKEY.toLowerCase() +
  '16000000657468657265756d2d706572736f6e616c2d7369676e';

const fixtureDir = join(dirname(fileURLToPath(import.meta.url)), 'testdata');
const f1 = JSON.parse(
  readFileSync(join(fixtureDir, 'ownerOfKey-consistent.json'), 'utf8'),
) as {
  query: { namespace: string; keyType: string; pubkey: string };
  returnValue: string;
};

function strEnc(text: string): string {
  const bytes = Buffer.from(text, 'utf8');
  const length = Buffer.alloc(4);
  length.writeUInt32LE(bytes.length);
  return Buffer.concat([length, bytes]).toString('hex');
}

/** Synthetic CIS-8 Registration wrapped in the Some tag. */
function syntheticRegistration(overrides: {
  ownerHex?: string;
  namespace?: string;
  keyType?: string;
  publicKeyHex?: string;
  proofScheme?: string;
  status?: 'Active' | 'Revoked';
  lastUpdatedMs?: bigint;
}): string {
  const keyBytes = Buffer.from(
    (overrides.publicKeyHex ?? ARC_OWNER_PUBKEY).replace(/^0x/i, ''),
    'hex',
  );
  const keyLength = Buffer.alloc(4);
  keyLength.writeUInt32LE(keyBytes.length);
  const updated = Buffer.alloc(8);
  updated.writeBigUInt64LE(overrides.lastUpdatedMs ?? 1795999188623n);
  return (
    '01' +
    (overrides.ownerHex ?? CONCORDIUM_OWNER_HEX).toLowerCase() +
    strEnc(overrides.namespace ?? VALEN_CIS8_NAMESPACE) +
    strEnc(overrides.keyType ?? VALEN_CIS8_KEY_TYPE) +
    keyLength.toString('hex') +
    keyBytes.toString('hex') +
    strEnc(overrides.proofScheme ?? VALEN_CIS8_PROOF_SCHEME) +
    '00000000' +
    (overrides.status === 'Revoked' ? '01' : '00') +
    updated.toString('hex')
  );
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

const WHERE = { contractIndex: 12801n, contractSubindex: 0n };

describe('Valen binding constants', () => {
  it('pins the Arc owner, namespace, key type, and scheme', () => {
    expect(VALEN_ARC_OWNER).toBe(ARC_OWNER);
    expect(VALEN_CIS8_NAMESPACE).toBe('eip155:5042002');
    expect(VALEN_CIS8_KEY_TYPE).toBe('secp256k1-uncompressed');
    expect(VALEN_CIS8_PROOF_SCHEME).toBe('ethereum-personal-sign');
  });
});

describe('buildValenBindingKeyId', () => {
  it('builds the exact key id for the Arc owner pubkey', () => {
    expect(buildValenBindingKeyId(ARC_OWNER_PUBKEY)).toEqual({
      namespace: 'eip155:5042002',
      keyType: 'secp256k1-uncompressed',
      publicKeyHex: ARC_OWNER_PUBKEY.toLowerCase(),
    });
  });

  it('rejects malformed owner pubkeys', () => {
    const cases = [
      '',
      'deadbeef',
      `02${'11'.repeat(32)}`, // compressed: Valen binds the uncompressed form
      `05${'11'.repeat(64)}`, // bad prefix
      `04${'zz'.repeat(64)}`, // non-hex
    ];
    for (const bad of cases) {
      expect(() => buildValenBindingKeyId(bad), bad.slice(0, 10)).toThrowError(ConcordiumError);
    }
  });
});

describe('buildCis8CanonicalBytes', () => {
  it('byte-matches the official MCP construction', () => {
    expect(
      buildCis8CanonicalBytes({
        concordiumAccount: CONCORDIUM_ACCOUNT,
        contractIndex: 12801n,
        contractSubindex: 0n,
        genesisHashHex: TESTNET_GENESIS,
        key: buildValenBindingKeyId(ARC_OWNER_PUBKEY),
      }),
    ).toBe(OFFICIAL_CANONICAL_HEX);
  });

  it('rejects malformed inputs', () => {
    const good = {
      concordiumAccount: CONCORDIUM_ACCOUNT,
      contractIndex: 12801n,
      contractSubindex: 0n,
      genesisHashHex: TESTNET_GENESIS,
      key: buildValenBindingKeyId(ARC_OWNER_PUBKEY),
    };
    expect(() => buildCis8CanonicalBytes({ ...good, concordiumAccount: 'nope' })).toThrowError(
      ConcordiumError,
    );
    expect(() => buildCis8CanonicalBytes({ ...good, genesisHashHex: 'abcd' })).toThrowError(
      ConcordiumError,
    );
  });
});

describe('ethereumPersonalSignDigest', () => {
  it('matches viem hashMessage over the canonical bytes', () => {
    const canonical = buildCis8CanonicalBytes({
      concordiumAccount: CONCORDIUM_ACCOUNT,
      contractIndex: 12801n,
      contractSubindex: 0n,
      genesisHashHex: TESTNET_GENESIS,
      key: buildValenBindingKeyId(ARC_OWNER_PUBKEY),
    });
    const raw = `0x${canonical}` as `0x${string}`;
    expect(ethereumPersonalSignDigest(canonical)).toBe(hashMessage({ raw }));
    // Independently: manual EIP-191 envelope + keccak.
    const bytes = Buffer.from(canonical, 'hex');
    const envelope = Buffer.concat([
      Buffer.from(`\x19Ethereum Signed Message:\n${bytes.length}`, 'utf8'),
      bytes,
    ]);
    expect(ethereumPersonalSignDigest(canonical)).toBe(
      keccak256(`0x${envelope.toString('hex')}` as `0x${string}`),
    );
  });
});

describe('verifyValenBinding', () => {
  const key: ExternalKeyId = {
    namespace: VALEN_CIS8_NAMESPACE,
    keyType: VALEN_CIS8_KEY_TYPE,
    publicKeyHex: ARC_OWNER_PUBKEY,
  };

  it('accepts the correct account and Arc owner key', async () => {
    const verified = await verifyValenBinding(mockNode(syntheticRegistration({})), {
      ...WHERE,
      key,
      expectedOwnerHex: CONCORDIUM_OWNER_HEX,
      expectedWallet: ARC_OWNER as EvmAddress,
    });
    expect(verified.address.toLowerCase()).toBe(ARC_OWNER.toLowerCase());
    expect(verified.namespace).toBe('eip155:5042002');
    expect(verified.proofScheme).toBe('ethereum-personal-sign');
  });

  it('rejects an incorrect Concordium account', async () => {
    await expect(
      verifyValenBinding(mockNode(syntheticRegistration({})), {
        ...WHERE,
        key,
        expectedOwnerHex: '00'.repeat(32),
        expectedWallet: ARC_OWNER as EvmAddress,
      }),
    ).rejects.toMatchObject({ code: 'CIS8_OWNER_MISMATCH' });
  });

  it('rejects an incorrect external key', async () => {
    const otherKey = `04${'22'.repeat(64)}`;
    await expect(
      verifyValenBinding(mockNode(syntheticRegistration({})), {
        ...WHERE,
        key: { ...key, publicKeyHex: otherKey },
        expectedOwnerHex: CONCORDIUM_OWNER_HEX,
        expectedWallet: ARC_OWNER as EvmAddress,
      }),
    ).rejects.toMatchObject({ code: 'NODE_ERROR' });
  });

  it('rejects an unsupported namespace', async () => {
    await expect(
      verifyValenBinding(mockNode(syntheticRegistration({ namespace: 'eip155:1' })), {
        ...WHERE,
        key: { ...key, namespace: 'eip155:1' },
        expectedOwnerHex: CONCORDIUM_OWNER_HEX,
        expectedWallet: ARC_OWNER as EvmAddress,
      }),
    ).rejects.toMatchObject({ code: 'CIS8_NAMESPACE_REJECTED' });
  });

  it('rejects an unsupported signature scheme', async () => {
    await expect(
      verifyValenBinding(mockNode(syntheticRegistration({ proofScheme: 'solana-ed25519' })), {
        ...WHERE,
        key,
        expectedOwnerHex: CONCORDIUM_OWNER_HEX,
        expectedWallet: ARC_OWNER as EvmAddress,
      }),
    ).rejects.toMatchObject({ code: 'CIS8_PROOF_SCHEME_REJECTED' });
  });

  it('rejects a missing binding', async () => {
    await expect(
      verifyValenBinding(mockNode('00'), {
        ...WHERE,
        key,
        expectedOwnerHex: CONCORDIUM_OWNER_HEX,
        expectedWallet: ARC_OWNER as EvmAddress,
      }),
    ).rejects.toMatchObject({ code: 'CIS8_NOT_FOUND' });
  });

  it('rejects an inactive binding', async () => {
    await expect(
      verifyValenBinding(mockNode(syntheticRegistration({ status: 'Revoked' })), {
        ...WHERE,
        key,
        expectedOwnerHex: CONCORDIUM_OWNER_HEX,
        expectedWallet: ARC_OWNER as EvmAddress,
      }),
    ).rejects.toMatchObject({ code: 'CIS8_REVOKED' });
  });

  it('rejects accidental F1 fixture reuse as the binding key', async () => {
    const f1Key: ExternalKeyId = {
      namespace: f1.query.namespace,
      keyType: f1.query.keyType,
      publicKeyHex: f1.query.pubkey,
    };
    await expect(
      verifyValenBinding(mockNode(f1.returnValue), {
        ...WHERE,
        key: f1Key,
        expectedOwnerHex: CONCORDIUM_OWNER_HEX,
        expectedWallet: ARC_OWNER as EvmAddress,
      }),
    ).rejects.toMatchObject({ code: 'CIS8_NAMESPACE_REJECTED' });
  });

  it('rejects the F1 live binding against Valen expectations', async () => {
    await expect(
      verifyValenBinding(mockNode(f1.returnValue), {
        ...WHERE,
        key,
        expectedOwnerHex: CONCORDIUM_OWNER_HEX,
        expectedWallet: ARC_OWNER as EvmAddress,
      }),
    ).rejects.toThrowError(ConcordiumError);
  });

  it('accepts the live Valen binding with normalized compressed echo', async () => {
    const live = JSON.parse(
      readFileSync(join(fixtureDir, 'ownerOfKey-valen-5042002.json'), 'utf8'),
    ) as { returnValue: string };
    const verified = await verifyValenBinding(mockNode(live.returnValue), {
      ...WHERE,
      key,
      expectedOwnerHex: CONCORDIUM_OWNER_HEX,
      expectedWallet: ARC_OWNER as EvmAddress,
    });
    expect(verified.address.toLowerCase()).toBe(ARC_OWNER.toLowerCase());
    expect(verified.namespace).toBe('eip155:5042002');
    expect(verified.proofScheme).toBe('ethereum-personal-sign');
    expect(verified.ownerHex).toBe(CONCORDIUM_OWNER_HEX);
  });
});

describe('verifyArcContractOwners', () => {
  const ELEVEN = [
    '0xeC74944752Fff0f53Af5b727F288f59435C0144e',
    '0x253B68c7a2D646561387Dc0958A6C176a30a6f8d',
    '0x6F77979c0e2f6f8073FD6555c9A9d5883786AE19',
    '0x258B0678b30E2d32034389cfeCa7f58fE1CeB897',
    '0xE0B9b39E72f73f2d85D77a1e24a2f319246de822',
    '0xC49999B7d32F1B1Df28d53efAdee450A0Fd7dA2f',
    '0x04B22AD06256cFdD32546aCC6c40bFF9C3eFd061',
    '0x23307d061dad8335995080518B73A839Ffe69E7A',
    '0xf8E069B659CEAf9c68318041D727b5c482Ac6374',
    '0xe741d95aa64F125f75cB14E90d4b1cF96618f0fD',
    '0x2660044E4A7316B65263ea1B23b80aAf09841196',
  ];

  it('accepts when all 11 contracts agree on the owner', async () => {
    const result = await verifyArcContractOwners(
      { readOwner: async () => ARC_OWNER as EvmAddress },
      { contractAddresses: ELEVEN, expectedWallet: ARC_OWNER as EvmAddress },
    );
    expect(result.checked).toBe(11);
    expect(result.owner).toBe(ARC_OWNER);
  });

  it('rejects a single mismatched contract owner', async () => {
    const result = verifyArcContractOwners(
      {
        readOwner: async (contract) =>
          (contract === ELEVEN[4] ? '0x0000000000000000000000000000000000000001' : ARC_OWNER) as EvmAddress,
      },
      { contractAddresses: ELEVEN, expectedWallet: ARC_OWNER as EvmAddress },
    );
    await expect(result).rejects.toMatchObject({ code: 'VALEN_ARC_OWNER_MISMATCH' });
  });

  it('rejects when the expected wallet matches none', async () => {
    await expect(
      verifyArcContractOwners(
        { readOwner: async () => ARC_OWNER as EvmAddress },
        {
          contractAddresses: ELEVEN,
          expectedWallet: '0x0000000000000000000000000000000000000001' as EvmAddress,
        },
      ),
    ).rejects.toMatchObject({ code: 'VALEN_ARC_OWNER_MISMATCH' });
  });
});
