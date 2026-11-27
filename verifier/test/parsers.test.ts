import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  AgentViewError,
  encodeExternalReferenceParam,
  encodeTokenIdParam,
  parseAgentOfResponse,
} from '../src/concordium/agentView.js';
import {
  Cis8Error,
  deriveEvmAddress,
  encodeExternalKeyId,
  keyXCoordinate,
  parseOwnerOfKeyResponse,
} from '../src/concordium/cis8.js';

const fixtures = join(dirname(fileURLToPath(import.meta.url)), 'fixtures');
const agentOfHex = readFileSync(join(fixtures, 'agentof-1507.hex'), 'utf8').trim();
const ownerOfKeyHex = readFileSync(join(fixtures, 'ownerofkey-valen.hex'), 'utf8').trim();

const OWNER_HEX = 'b376ffb2f41efa8a524ab6f6cf7b2f481c271d968ec21c4dd0a063647c516fea';
const OWNER_PUBKEY =
  '04e6a2ba9a7bafb29119156252e2e42e4e7695d478cb26a118ee83c0471beb9b2' +
  'dc9b52073d094fdceb7aaf718b0c750905965cebed0df1e4aaa157ec3f9852cab';
const OWNER_ADDRESS = '0xb0e8ba6afe21371ad4001e611224fc200fd10144';

describe('agentOf fixtures (live token 1507)', () => {
  it('parses every field of the live record', () => {
    const parsed = parseAgentOfResponse(agentOfHex);
    expect(parsed.found).toBe(true);
    if (!parsed.found) {
      throw new Error('unreachable');
    }
    expect(parsed.tokenId).toBe(1507n);
    expect(parsed.ownerHex).toBe(OWNER_HEX);
    expect(parsed.agentUri).toBe(
      'https://raw.githubusercontent.com/Web3smallie/valen/9098748fabe8e1c0c633f4f9a0fe5db48cf85704/agent-card/agent-card.json',
    );
    expect(parsed.metadataHashHex).toBe('e1a8b6c9da17b8adbfd9351203bb76c406b3bbd75d1837f94a908c53f80cbfdc');
    expect(parsed.externalReference).toEqual({
      contractIndex: 12801n,
      contractSubindex: 0n,
      kind: 'Cis8',
      key: {
        namespace: 'eip155:5042002',
        keyType: 'secp256k1-uncompressed',
        publicKeyHex: OWNER_PUBKEY.toLowerCase(),
      },
    });
    expect(parsed.agentWalletHex).toBe(OWNER_HEX);
    expect(parsed.status).toBe('Active');
    expect(parsed.registeredAtMs).toBeGreaterThan(0);
    expect(parsed.trailingHex).toBe('00000000');
  });

  it('reports absence and rejects malformed input', () => {
    expect(parseAgentOfResponse('00')).toEqual({ found: false });
    for (const bad of ['', '01', '02', 'zz', agentOfHex.slice(0, -30)]) {
      expect(() => parseAgentOfResponse(bad), bad.slice(0, 12)).toThrowError(AgentViewError);
    }
  });

  it('accepts exactly 4 trailing zero bytes and records the quirk', () => {
    const parsed = parseAgentOfResponse(agentOfHex);
    expect(parsed.found).toBe(true);
    if (!parsed.found) {
      throw new Error('unreachable');
    }
    expect(parsed.trailingHex).toBe('00000000');
    expect(parsed.trailingNote).toContain('quirk');
  });

  it('accepts zero trailing bytes as the spec form', () => {
    const specForm = agentOfHex.slice(0, -8);
    const parsed = parseAgentOfResponse(specForm);
    expect(parsed.found).toBe(true);
    if (!parsed.found) {
      throw new Error('unreachable');
    }
    expect(parsed.trailingHex).toBe('');
    expect(parsed.tokenId).toBe(1507n);
  });

  it('rejects 3 trailing bytes', () => {
    const base = agentOfHex.slice(0, -8);
    expect(() => parseAgentOfResponse(`${base}000000`)).toThrowError(AgentViewError);
  });

  it('rejects 5 trailing bytes', () => {
    const base = agentOfHex.slice(0, -8);
    expect(() => parseAgentOfResponse(`${base}0000000000`)).toThrowError(AgentViewError);
  });

  it('rejects 4 non-zero trailing bytes', () => {
    const base = agentOfHex.slice(0, -8);
    expect(() => parseAgentOfResponse(`${base}00000001`)).toThrowError(AgentViewError);
  });

  it('rejects an unknown external-reference kind', () => {
    // Flip the Cis8 kind tag (byte after the 16-byte contract address in the extref).
    const bytes = Buffer.from(agentOfHex, 'hex');
    // Locate: walk is brittle; instead corrupt the known kind position by search.
    // The extref starts with u64le(12801)=0132...; kind byte follows 16 contract bytes.
    const marker = Buffer.from('0132000000000000' + '0000000000000000', 'hex');
    const at = bytes.indexOf(marker);
    expect(at).toBeGreaterThan(0);
    bytes[at + 16] = 0x07;
    expect(() => parseAgentOfResponse(bytes.toString('hex'))).toThrowError(AgentViewError);
  });
});

describe('ownerOfKey fixtures (live Valen binding)', () => {
  it('parses every field of the live record', () => {
    const parsed = parseOwnerOfKeyResponse(ownerOfKeyHex);
    expect(parsed.found).toBe(true);
    if (!parsed.found) {
      throw new Error('unreachable');
    }
    expect(parsed.ownerHex).toBe(OWNER_HEX);
    expect(parsed.namespace).toBe('eip155:5042002');
    expect(parsed.keyType).toBe('secp256k1-compressed');
    expect(parsed.publicKeyHex).toBe('03e6a2ba9a7bafb29119156252e2e42e4e7695d478cb26a118ee83c0471beb9b2d');
    expect(parsed.proofScheme).toBe('ethereum-personal-sign');
    expect(parsed.metadataCount).toBe(0);
    expect(parsed.status).toBe('Active');
    expect(parsed.trailingHex).toBe('');
  });

  it('reports absence and rejects malformed input', () => {
    expect(parseOwnerOfKeyResponse('00')).toEqual({ found: false });
    for (const bad of ['', '01', '02', 'zz', ownerOfKeyHex.slice(0, -4)]) {
      expect(() => parseOwnerOfKeyResponse(bad), bad.slice(0, 12)).toThrowError(Cis8Error);
    }
  });
});

describe('parameter encoders', () => {
  it('encodes token ids', () => {
    expect(encodeTokenIdParam(1507n)).toBe('08e305000000000000');
    expect(encodeTokenIdParam(0n)).toBe(`08${'00'.repeat(8)}`);
    expect(() => encodeTokenIdParam(-1n)).toThrowError(AgentViewError);
  });

  it('encodes external key ids deterministically', () => {
    const hex = encodeExternalKeyId({
      namespace: 'eip155:5042002',
      keyType: 'secp256k1-uncompressed',
      publicKeyHex: OWNER_PUBKEY,
    });
    expect(hex.startsWith('0e000000')).toBe(true);
    expect(hex).toContain(OWNER_PUBKEY.toLowerCase());
    expect(() => encodeExternalKeyId({ namespace: 'x', keyType: 'y', publicKeyHex: 'zz' })).toThrowError(
      Cis8Error,
    );
  });

  it('encodes external references for reverse lookup', () => {
    const hex = encodeExternalReferenceParam({
      contractIndex: 12801n,
      contractSubindex: 0n,
      key: { namespace: 'eip155:5042002', keyType: 'secp256k1-uncompressed', publicKeyHex: OWNER_PUBKEY },
    });
    expect(hex.startsWith('0132000000000000' + '0000000000000000' + '00')).toBe(true);
    expect(hex).toContain(OWNER_PUBKEY.toLowerCase());
  });
});

describe('EVM derivation', () => {
  it('derives the owner address from both key encodings', () => {
    expect(deriveEvmAddress(OWNER_PUBKEY).toLowerCase()).toBe(OWNER_ADDRESS.toLowerCase());
    expect(
      deriveEvmAddress('03e6a2ba9a7bafb29119156252e2e42e4e7695d478cb26a118ee83c0471beb9b2d').toLowerCase(),
    ).toBe(OWNER_ADDRESS.toLowerCase());
  });

  it('agrees on x-coordinates across encodings', () => {
    expect(keyXCoordinate(OWNER_PUBKEY)).toBe(
      keyXCoordinate('03e6a2ba9a7bafb29119156252e2e42e4e7695d478cb26a118ee83c0471beb9b2d'),
    );
  });

  it('rejects malformed keys', () => {
    for (const bad of ['', '04', '05' + '11'.repeat(64), 'zz']) {
      expect(() => deriveEvmAddress(bad), bad.slice(0, 8)).toThrowError(Cis8Error);
    }
  });
});
