/**
 * CIS-8004 `agentOf` parameter encoding and `AgentView` parsing,
 * hand-written from the CIS-8004 proposal and verified against a live
 * testnet record (token 1507, 378 bytes incl. 4 trailing zero bytes the
 * deployed contract appends beyond the spec text).
 *
 * Layout: Option tag, then AgentTokenId (0x08 + u64 LE), owner (32B),
 * OptionalString uri, OptionalHash256, OptionalExtRef
 * (ContractAddress u64le+u64le, kind byte, ExternalKeyId), OptionalAddress
 * wallet, status byte (0 Active / 1 Revoked), Timestamp u64le ms,
 * OptionalTimestamp, OptionalString. Trailing bytes are TOLERATED but
 * recorded: the live true record carries 4 zero bytes, so strict rejection
 * would fail a correct registration.
 */

export class AgentViewError extends Error {}

export interface AgentExternalKey {
  readonly namespace: string;
  readonly keyType: string;
  readonly publicKeyHex: string;
}

export interface AgentExternalReference {
  readonly contractIndex: bigint;
  readonly contractSubindex: bigint;
  readonly kind: string;
  readonly key: AgentExternalKey;
}

export interface AgentRecord {
  readonly tokenId: bigint;
  readonly ownerHex: string;
  readonly agentUri: string | null;
  readonly metadataHashHex: string | null;
  readonly externalReference: AgentExternalReference | null;
  readonly agentWalletHex: string | null;
  readonly status: 'Active' | 'Revoked';
  readonly registeredAtMs: number;
  readonly trailingHex: string;
  readonly trailingNote: string;
}

/** Exact trailing-data policy: spec form (none) or the observed 4-zero-byte quirk, nothing else. */
export const TRAILING_QUIRK_HEX = '00000000';
export const TRAILING_QUIRK_NOTE =
  'quirk observed live: deployed contract appends exactly 4 zero bytes beyond the spec fields';
const TRAILING_SPEC_NOTE = 'spec form: no trailing bytes';

export type AgentOfResult = { readonly found: false } | ({ readonly found: true } & AgentRecord);

export interface ExternalReferenceInput {
  readonly contractIndex: bigint;
  readonly contractSubindex: bigint;
  readonly key: { readonly namespace: string; readonly keyType: string; readonly publicKeyHex: string };
}

/** ExternalReference parameter for agentByExternalReference: contract + Cis8 tag + key id. */
export function encodeExternalReferenceParam(ref: ExternalReferenceInput): string {
  if (ref.contractIndex < 0n || ref.contractSubindex < 0n) {
    throw new AgentViewError('contract address must be non-negative');
  }
  const clean = ref.key.publicKeyHex.startsWith('0x') ? ref.key.publicKeyHex.slice(2) : ref.key.publicKeyHex;
  if (!/^[0-9a-fA-F]+$/.test(clean) || clean.length % 2 !== 0) {
    throw new AgentViewError('public key is not hex');
  }
  const keyBytes = Buffer.from(clean, 'hex');
  const strEnc = (text: string): Buffer => {
    const bytes = Buffer.from(text, 'utf8');
    const length = Buffer.alloc(4);
    length.writeUInt32LE(bytes.length);
    return Buffer.concat([length, bytes]);
  };
  const index = Buffer.alloc(8);
  index.writeBigUInt64LE(ref.contractIndex);
  const subindex = Buffer.alloc(8);
  subindex.writeBigUInt64LE(ref.contractSubindex);
  const keyLength = Buffer.alloc(4);
  keyLength.writeUInt32LE(keyBytes.length);
  return Buffer.concat([
    index,
    subindex,
    Buffer.from([0]),
    strEnc(ref.key.namespace),
    strEnc(ref.key.keyType),
    keyLength,
    keyBytes,
  ]).toString('hex');
}

const U64_MAX = (1n << 64n) - 1n;

/** AgentTokenId parameter: 0x08 length prefix + u64 little-endian. */
export function encodeTokenIdParam(tokenId: bigint): string {
  if (typeof tokenId !== 'bigint' || tokenId < 0n || tokenId > U64_MAX) {
    throw new AgentViewError('token id must be a u64');
  }
  const id = Buffer.alloc(8);
  id.writeBigUInt64LE(tokenId);
  return Buffer.concat([Buffer.from([8]), id]).toString('hex');
}

class Reader {
  private pos = 0;

  constructor(private readonly bytes: Buffer) {}

  get offset(): number {
    return this.pos;
  }

  get remaining(): number {
    return this.bytes.length - this.pos;
  }

  take(count: number, what: string): Buffer {
    if (this.pos + count > this.bytes.length) {
      throw new AgentViewError(`truncated response at ${what}`);
    }
    const slice = this.bytes.subarray(this.pos, this.pos + count);
    this.pos += count;
    return slice;
  }

  u8(what: string): number {
    const value = this.take(1, what)[0];
    if (value === undefined) {
      throw new AgentViewError(`truncated response at ${what}`);
    }
    return value;
  }

  u32le(what: string): number {
    return this.take(4, what).readUInt32LE(0);
  }

  u64le(what: string): bigint {
    return this.take(8, what).readBigUInt64LE(0);
  }

  text(what: string): string {
    const length = this.u32le(`${what}.length`);
    return this.take(length, what).toString('utf8');
  }

  optional(what: string): boolean {
    const tag = this.u8(`${what}.tag`);
    if (tag !== 0 && tag !== 1) {
      throw new AgentViewError(`bad option tag ${tag} at ${what}`);
    }
    return tag === 1;
  }
}

function parseExternalReference(reader: Reader): AgentExternalReference {
  const contractIndex = reader.u64le('extref.contractIndex');
  const contractSubindex = reader.u64le('extref.contractSubindex');
  const kindTag = reader.u8('extref.kind');
  if (kindTag !== 0) {
    throw new AgentViewError(`unsupported external reference kind ${kindTag} (only Cis8/0)`);
  }
  return {
    contractIndex,
    contractSubindex,
    kind: 'Cis8',
    key: {
      namespace: reader.text('extref.namespace'),
      keyType: reader.text('extref.keyType'),
      publicKeyHex: reader.take(reader.u32le('extref.key.length'), 'extref.key').toString('hex'),
    },
  };
}

/**
 * Parse an `agentOf` return value. `0x00` means absent; `0x01` prefixes the
 * record. Anything structurally invalid throws (caller maps to FAIL).
 */
export function parseAgentOfResponse(returnHex: string): AgentOfResult {
  const clean = returnHex.startsWith('0x') ? returnHex.slice(2) : returnHex;
  if (!/^[0-9a-fA-F]*$/.test(clean) || clean.length % 2 !== 0) {
    throw new AgentViewError('not even-length hex');
  }
  const bytes = Buffer.from(clean, 'hex');
  if (bytes.length === 0) {
    throw new AgentViewError('empty response');
  }
  if (bytes[0] === 0x00) {
    return { found: false };
  }
  if (bytes[0] !== 0x01) {
    throw new AgentViewError('bad outer tag');
  }
  const reader = new Reader(bytes.subarray(1));
  if (reader.u8('tokenId.prefix') !== 8) {
    throw new AgentViewError('bad token id prefix');
  }
  const tokenId = reader.u64le('tokenId');
  const ownerHex = reader.take(32, 'owner').toString('hex');
  const agentUri = reader.optional('agentUri') ? reader.text('agentUri') : null;
  const metadataHashHex = reader.optional('metadataHash')
    ? reader.take(32, 'metadataHash').toString('hex')
    : null;
  const externalReference = reader.optional('externalReference')
    ? parseExternalReference(reader)
    : null;
  const agentWalletHex = reader.optional('agentWallet')
    ? reader.take(32, 'agentWallet').toString('hex')
    : null;
  const statusByte = reader.u8('status');
  if (statusByte !== 0 && statusByte !== 1) {
    throw new AgentViewError(`bad status byte ${statusByte}`);
  }
  const registeredAtMs = Number(reader.u64le('registeredAt'));
  if (reader.optional('revokedAt')) {
    reader.u64le('revokedAt');
  }
  if (reader.optional('revocationReason')) {
    reader.text('revocationReason');
  }
  const trailingHex = bytes.subarray(1 + reader.offset).toString('hex');
  let trailingNote: string;
  if (trailingHex === '') {
    trailingNote = TRAILING_SPEC_NOTE;
  } else if (trailingHex === TRAILING_QUIRK_HEX) {
    trailingNote = TRAILING_QUIRK_NOTE;
  } else {
    throw new AgentViewError(
      `unexpected trailing data: ${trailingHex.length / 2} byte(s), expected none or exactly 4 zero bytes`,
    );
  }
  return {
    found: true,
    tokenId,
    ownerHex,
    agentUri,
    metadataHashHex,
    externalReference,
    agentWalletHex,
    status: statusByte === 0 ? 'Active' : 'Revoked',
    registeredAtMs,
    trailingHex,
    trailingNote,
  };
}
