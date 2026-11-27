import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import type { ConcordiumNode } from './node.js';
import {
  BARE_REGISTER_PARAMETER_HEX,
  buildServiceAgentRegistration,
  CIS8004_AGENT_OF_RECEIVE_NAME,
  CIS8004_REGISTER_RECEIVE_NAME,
  encodeAgentTokenId,
  parseAgentOfResponse,
  REGISTER_SUGGESTED_ENERGY,
  verifyServiceAgentRegistration,
} from './serviceAgent.js';
import { ConcordiumError } from './types.js';

const fixtureDir = join(dirname(fileURLToPath(import.meta.url)), 'testdata');
const live1454 = JSON.parse(
  readFileSync(join(fixtureDir, 'agentOf-1454.json'), 'utf8'),
) as {
  query: { tokenId: string; paramHex: string };
  returnValue: string;
  crossCheck: { ownerAccount: string; status: string; registeredAt: string };
};

// Agreed Concordium testnet owner account for Valen's service-agent
// registration (controlled, funded, verified live 2026-11-23).
const SENDER = '49BGJbazHuYzPFMRrvMJzapKdCdz1TCawUxGnABAJfMbH2jRps';
const SENDER_HEX = '9da7b35d9f7f2b3263c4146b7b428a9905889281e8b6dc0bc9e123534aa07cfa';

function strEnc(text: string): string {
  const bytes = Buffer.from(text, 'utf8');
  const length = Buffer.alloc(4);
  length.writeUInt32LE(bytes.length);
  return Buffer.concat([length, bytes]).toString('hex');
}

function u64le(value: bigint): string {
  const buffer = Buffer.alloc(8);
  buffer.writeBigUInt64LE(value);
  return buffer.toString('hex');
}

/** AgentTokenId wire form: 0x08 + u64 LE. */
function tokenIdEnc(value: bigint): string {
  return `08${u64le(value)}`;
}

/**
 * Synthetic AgentView wrapped in the outer Some tag, mirroring the
 * live-recorded response shape. Defaults describe a bare registration
 * (no URI, hash, or external reference) owned by the agreed sender.
 */
function syntheticAgentView(overrides: {
  tokenId?: bigint;
  ownerHex?: string;
  agentUri?: string | null;
  metadataHashHex?: string | null;
  externalReference?: {
    contractIndex: bigint;
    contractSubindex: bigint;
    namespace: string;
    keyType: string;
    publicKeyHex: string;
  } | null;
  agentWalletHex?: string | null;
  status?: 'Active' | 'Revoked';
  registeredAtMs?: bigint;
  revokedAtMs?: bigint | null;
  revocationReason?: string | null;
} = {}): string {
  const tokenId = overrides.tokenId ?? 1454n;
  const ownerHex = (overrides.ownerHex ?? SENDER_HEX).toLowerCase();
  const agentUri =
    overrides.agentUri === undefined || overrides.agentUri === null
      ? '00'
      : `01${strEnc(overrides.agentUri)}`;
  const metadataHash =
    overrides.metadataHashHex === undefined || overrides.metadataHashHex === null
      ? '00'
      : `01${overrides.metadataHashHex.toLowerCase()}`;
  let externalReference = '00';
  if (overrides.externalReference !== undefined && overrides.externalReference !== null) {
    const ref = overrides.externalReference;
    const keyBytes = Buffer.from(ref.publicKeyHex, 'hex');
    const keyLength = Buffer.alloc(4);
    keyLength.writeUInt32LE(keyBytes.length);
    externalReference =
      '01' +
      u64le(ref.contractIndex) +
      u64le(ref.contractSubindex) +
      '00' +
      strEnc(ref.namespace) +
      strEnc(ref.keyType) +
      keyLength.toString('hex') +
      keyBytes.toString('hex');
  }
  const agentWallet =
    overrides.agentWalletHex === undefined || overrides.agentWalletHex === null
      ? '00'
      : `01${overrides.agentWalletHex.toLowerCase()}`;
  const status = overrides.status === 'Revoked' ? '01' : '00';
  const registeredAt = u64le(overrides.registeredAtMs ?? 1795999188623n);
  const revokedAt =
    overrides.revokedAtMs === undefined || overrides.revokedAtMs === null
      ? '00'
      : `01${u64le(overrides.revokedAtMs)}`;
  const revocationReason =
    overrides.revocationReason === undefined || overrides.revocationReason === null
      ? '00'
      : `01${strEnc(overrides.revocationReason)}`;
  return (
    '01' +
    tokenIdEnc(tokenId) +
    ownerHex +
    agentUri +
    metadataHash +
    externalReference +
    agentWallet +
    status +
    registeredAt +
    revokedAt +
    revocationReason
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
    invokeOwnerOfKey: async () => {
      throw new Error('unused');
    },
    invokeAgentOf: async () => returnHex,
    getGlobalContext: async () => ({}),
    getBestBlockHeight: async () => '1',
  };
}

describe('service-agent registration descriptor', () => {
  it('builds the exact bare register transaction descriptor', () => {
    const descriptor = buildServiceAgentRegistration({
      sender: SENDER,
      contractIndex: 12802n,
      contractSubindex: 0n,
    });
    expect(descriptor.network).toBe('testnet');
    expect(descriptor.contractIndex).toBe(12802n);
    expect(descriptor.contractSubindex).toBe(0n);
    expect(descriptor.receiveName).toBe('CIS-8004.register');
    expect(descriptor.receiveName).toBe(CIS8004_REGISTER_RECEIVE_NAME);
    // Three absent optionals + u32 metadata count 0 (spec + MCP cross-checked).
    expect(descriptor.parameterHex).toBe('00000000000000');
    expect(descriptor.parameterHex).toBe(BARE_REGISTER_PARAMETER_HEX);
    expect(descriptor.suggestedEnergy).toBe(30000);
    expect(descriptor.suggestedEnergy).toBe(REGISTER_SUGGESTED_ENERGY);
    expect(descriptor.sender).toBe(SENDER);
    expect(descriptor.senderHex).toBe(SENDER_HEX);
    expect(descriptor.ccdscanUrl).toBe('https://testnet.ccdscan.io/?dcount=1&dentity=contract&daddress=12802');
  });

  it('rejects a malformed sender account', () => {
    expect(() =>
      buildServiceAgentRegistration({
        sender: 'not-an-account',
        contractIndex: 12802n,
        contractSubindex: 0n,
      }),
    ).toThrowError(ConcordiumError);
    try {
      buildServiceAgentRegistration({
        sender: 'not-an-account',
        contractIndex: 12802n,
        contractSubindex: 0n,
      });
      throw new Error('unreachable');
    } catch (error) {
      expect((error as ConcordiumError).code).toBe('SERVICE_AGENT_SENDER_MALFORMED');
    }
  });
});

describe('encodeAgentTokenId', () => {
  it('encodes the live-recorded token id bytes exactly', () => {
    expect(encodeAgentTokenId(1454n)).toBe(live1454.query.paramHex);
    expect(encodeAgentTokenId(1454n)).toBe('08ae05000000000000');
  });

  it('encodes boundary token ids', () => {
    expect(encodeAgentTokenId(0n)).toBe(`08${'00'.repeat(8)}`);
    expect(encodeAgentTokenId(18446744073709551615n)).toBe(`08${'ff'.repeat(8)}`);
  });

  it('rejects out-of-range token ids', () => {
    for (const bad of [-1n, 18446744073709551616n]) {
      try {
        encodeAgentTokenId(bad);
        throw new Error(`unreachable for ${bad}`);
      } catch (error) {
        expect(error).toBeInstanceOf(ConcordiumError);
        expect((error as ConcordiumError).code).toBe('SERVICE_AGENT_TOKEN_ID_INVALID');
      }
    }
  });
});

describe('parseAgentOfResponse (live-recorded token 1454)', () => {
  it('parses every field of the live record', () => {
    const parsed = parseAgentOfResponse(live1454.returnValue);
    expect(parsed.found).toBe(true);
    if (!parsed.found) {
      throw new Error('unreachable');
    }
    expect(parsed.tokenId).toBe(1454n);
    expect(parsed.ownerHex).toBe('90c861057951b4439e0843295393c870cb59a521d2325b149578b62a9d7bd7fc');
    expect(parsed.agentUri).toBe(
      'https://raw.githubusercontent.com/balojey/tradewizard-concordium/main/docs/agents/tradewizard-agent-card.json',
    );
    expect(parsed.metadataHashHex).toBe('6f9fe84acdb3ebc969040721b4b148e6628c60c12b34f630014cfabc90f1f9b9');
    expect(parsed.externalReference).toBeNull();
    // Register auto-sets the wallet to the sender; owner shows through here.
    expect(parsed.agentWalletHex).toBe('90c861057951b4439e0843295393c870cb59a521d2325b149578b62a9d7bd7fc');
    expect(parsed.status).toBe('Active');
    // Matches the MCP cross-check registered_at exactly.
    expect(parsed.registeredAtMs).toBe(Date.parse(live1454.crossCheck.registeredAt));
    expect(parsed.revokedAtMs).toBeNull();
    expect(parsed.revocationReason).toBeNull();
  });

  it('parses a bare registration (all optionals absent)', () => {
    const parsed = parseAgentOfResponse(syntheticAgentView());
    expect(parsed.found).toBe(true);
    if (!parsed.found) {
      throw new Error('unreachable');
    }
    expect(parsed.tokenId).toBe(1454n);
    expect(parsed.ownerHex).toBe(SENDER_HEX);
    expect(parsed.agentUri).toBeNull();
    expect(parsed.metadataHashHex).toBeNull();
    expect(parsed.externalReference).toBeNull();
    expect(parsed.agentWalletHex).toBeNull();
    expect(parsed.status).toBe('Active');
    expect(parsed.registeredAtMs).toBe(1795999188623);
    expect(parsed.revokedAtMs).toBeNull();
    expect(parsed.revocationReason).toBeNull();
  });

  it('parses a present Cis8 external reference', () => {
    const parsed = parseAgentOfResponse(
      syntheticAgentView({
        externalReference: {
          contractIndex: 12801n,
          contractSubindex: 0n,
          namespace: 'eip155:1',
          keyType: 'secp256k1-uncompressed',
          publicKeyHex: `04${'11'.repeat(64)}`,
        },
      }),
    );
    expect(parsed.found).toBe(true);
    if (!parsed.found) {
      throw new Error('unreachable');
    }
    expect(parsed.externalReference).toEqual({
      contractIndex: 12801n,
      contractSubindex: 0n,
      kind: 'Cis8',
      namespace: 'eip155:1',
      keyType: 'secp256k1-uncompressed',
      publicKeyHex: `04${'11'.repeat(64)}`,
    });
  });

  it('parses a revoked record with reason', () => {
    const parsed = parseAgentOfResponse(
      syntheticAgentView({
        status: 'Revoked',
        revokedAtMs: 1795999200000n,
        revocationReason: 'key compromised',
      }),
    );
    expect(parsed.found).toBe(true);
    if (!parsed.found) {
      throw new Error('unreachable');
    }
    expect(parsed.status).toBe('Revoked');
    expect(parsed.revokedAtMs).toBe(1795999200000);
    expect(parsed.revocationReason).toBe('key compromised');
  });

  it('reports a missing token as not found', () => {
    expect(parseAgentOfResponse('00')).toEqual({ found: false });
  });

  it('tolerates trailing bytes beyond the spec', () => {
    const parsed = parseAgentOfResponse(`${syntheticAgentView()}deadbeef`);
    expect(parsed.found).toBe(true);
    if (!parsed.found) {
      throw new Error('unreachable');
    }
    expect(parsed.tokenId).toBe(1454n);
    expect(parsed.status).toBe('Active');
  });

  it('rejects truncated and malformed responses', () => {
    const full = syntheticAgentView();
    const cases: Array<[string, string]> = [
      ['', 'empty'],
      ['01', 'tag only'],
      [full.slice(0, full.length - 2), 'truncated tail'],
      [`01${tokenIdEnc(7n)}`, 'truncated after token id'],
      ['02', 'bad outer tag'],
    ];
    for (const [input, label] of cases) {
      try {
        parseAgentOfResponse(input);
        throw new Error(`unreachable for ${label}`);
      } catch (error) {
        expect(error, label).toBeInstanceOf(ConcordiumError);
      }
    }
  });

  it('rejects an unknown status byte', () => {
    const full = syntheticAgentView();
    // Status sits right after the fixed prefix for this bare record:
    // 1 (outer) + 9 (token) + 32 (owner) + 1 + 1 + 1 (absent optionals) + 1 (absent wallet).
    const statusOffset = (1 + 9 + 32 + 1 + 1 + 1 + 1) * 2;
    const tampered = `${full.slice(0, statusOffset)}02${full.slice(statusOffset + 2)}`;
    expect(() => parseAgentOfResponse(tampered)).toThrowError(ConcordiumError);
  });
});

describe('verifyServiceAgentRegistration', () => {
  const where = { contractIndex: 12802n, contractSubindex: 0n };

  it('accepts a live Active record owned by the expected account', async () => {
    const verified = await verifyServiceAgentRegistration(mockNode(live1454.returnValue), {
      ...where,
      tokenId: 1454n,
      expectedOwnerHex: '90c861057951b4439e0843295393c870cb59a521d2325b149578b62a9d7bd7fc',
    });
    expect(verified.tokenId).toBe(1454n);
    expect(verified.status).toBe('Active');
    expect(verified.registeredAtMs).toBe(Date.parse(live1454.crossCheck.registeredAt));
  });

  it('rejects a missing token', async () => {
    await expect(
      verifyServiceAgentRegistration(mockNode('00'), {
        ...where,
        tokenId: 999999999n,
        expectedOwnerHex: SENDER_HEX,
      }),
    ).rejects.toMatchObject({ code: 'SERVICE_AGENT_NOT_FOUND' });
  });

  it('rejects a revoked registration', async () => {
    await expect(
      verifyServiceAgentRegistration(mockNode(syntheticAgentView({ status: 'Revoked' })), {
        ...where,
        tokenId: 1454n,
        expectedOwnerHex: SENDER_HEX,
      }),
    ).rejects.toMatchObject({ code: 'SERVICE_AGENT_REVOKED' });
  });

  it('rejects an owner mismatch', async () => {
    await expect(
      verifyServiceAgentRegistration(mockNode(syntheticAgentView()), {
        ...where,
        tokenId: 1454n,
        expectedOwnerHex: '00'.repeat(32),
      }),
    ).rejects.toMatchObject({ code: 'SERVICE_AGENT_OWNER_MISMATCH' });
  });

  it('queries the exact token id requested', async () => {
    let seenParam = '';
    const node: ConcordiumNode = {
      ...mockNode(syntheticAgentView({ tokenId: 77n })),
      invokeAgentOf: async (_index, _subindex, paramHex) => {
        seenParam = paramHex;
        return syntheticAgentView({ tokenId: 77n });
      },
    };
    const verified = await verifyServiceAgentRegistration(node, {
      ...where,
      tokenId: 77n,
      expectedOwnerHex: SENDER_HEX,
    });
    expect(seenParam).toBe(encodeAgentTokenId(77n));
    expect(verified.tokenId).toBe(77n);
  });

  it('rejects when the chain echoes a different token id', async () => {
    await expect(
      verifyServiceAgentRegistration(mockNode(syntheticAgentView({ tokenId: 78n })), {
        ...where,
        tokenId: 77n,
        expectedOwnerHex: SENDER_HEX,
      }),
    ).rejects.toMatchObject({ code: 'SERVICE_AGENT_NOT_FOUND' });
  });
});

describe('receive-name constants', () => {
  it('targets the live-verified CIS-8004 entrypoints', () => {
    expect(CIS8004_REGISTER_RECEIVE_NAME).toBe('CIS-8004.register');
    expect(CIS8004_AGENT_OF_RECEIVE_NAME).toBe('CIS-8004.agentOf');
  });
});
