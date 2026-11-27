import { secp256k1 } from '@noble/curves/secp256k1';
import { keccak256 } from 'viem';

/**
 * CIS-8 `ownerOfKey` parameter encoding, `Registration` parsing, and EVM
 * address derivation — hand-written from the CIS-8 proposal and verified
 * against a live testnet record (Valen binding, 151 bytes, fully consumed).
 *
 * Layout: Option tag, then owner (32B), ExternalKeyId (String namespace,
 * String key type, Bytestring key), String proof scheme, u32 metadata count
 * + entries (String key, String value), status byte (0 Active / 1 Revoked),
 * Timestamp u64le ms. Trailing bytes are recorded (tolerated) like agentOf.
 */

export class Cis8Error extends Error {}

export interface Cis8KeyId {
  readonly namespace: string;
  readonly keyType: string;
  readonly publicKeyHex: string;
}

export interface Cis8Registration {
  readonly ownerHex: string;
  readonly namespace: string;
  readonly keyType: string;
  readonly publicKeyHex: string;
  readonly proofScheme: string;
  readonly metadataCount: number;
  readonly status: 'Active' | 'Revoked';
  readonly lastUpdatedMs: number;
  readonly trailingHex: string;
}

export type OwnerOfKeyResult =
  | { readonly found: false }
  | ({ readonly found: true } & Cis8Registration);

function u32leBuffer(value: number): Buffer {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32LE(value);
  return buffer;
}

function encodeLengthPrefixedUtf8(text: string): Buffer {
  const bytes = Buffer.from(text, 'utf8');
  return Buffer.concat([u32leBuffer(bytes.length), bytes]);
}

/** ExternalKeyId wire form: namespace + key type + raw public key, length-prefixed. */
export function encodeExternalKeyId(key: Cis8KeyId): string {
  if (!/^(0x)?[0-9a-fA-F]+$/.test(key.publicKeyHex)) {
    throw new Cis8Error('public key is not hex');
  }
  const keyBytes = Buffer.from(key.publicKeyHex.replace(/^0x/i, ''), 'hex');
  const keyLength = Buffer.alloc(4);
  keyLength.writeUInt32LE(keyBytes.length);
  return Buffer.concat([
    encodeLengthPrefixedUtf8(key.namespace),
    encodeLengthPrefixedUtf8(key.keyType),
    keyLength,
    keyBytes,
  ]).toString('hex');
}

class Reader {
  private pos = 0;

  constructor(private readonly bytes: Buffer) {}

  get offset(): number {
    return this.pos;
  }

  take(count: number, what: string): Buffer {
    if (this.pos + count > this.bytes.length) {
      throw new Cis8Error(`truncated response at ${what}`);
    }
    const slice = this.bytes.subarray(this.pos, this.pos + count);
    this.pos += count;
    return slice;
  }

  u8(what: string): number {
    const value = this.take(1, what)[0];
    if (value === undefined) {
      throw new Cis8Error(`truncated response at ${what}`);
    }
    return value;
  }

  text(what: string): string {
    return this.take(this.take(4, `${what}.length`).readUInt32LE(0), what).toString('utf8');
  }
}

/** Parse an `ownerOfKey` return value. `0x00` means no binding. */
export function parseOwnerOfKeyResponse(returnHex: string): OwnerOfKeyResult {
  const clean = returnHex.startsWith('0x') ? returnHex.slice(2) : returnHex;
  if (!/^[0-9a-fA-F]*$/.test(clean) || clean.length % 2 !== 0) {
    throw new Cis8Error('not even-length hex');
  }
  const bytes = Buffer.from(clean, 'hex');
  if (bytes.length === 0) {
    throw new Cis8Error('empty response');
  }
  if (bytes[0] === 0x00) {
    return { found: false };
  }
  if (bytes[0] !== 0x01) {
    throw new Cis8Error('bad outer tag');
  }
  const reader = new Reader(bytes.subarray(1));
  const ownerHex = reader.take(32, 'owner').toString('hex');
  const namespace = reader.text('namespace');
  const keyType = reader.text('keyType');
  const publicKeyHex = reader
    .take(reader.take(4, 'key.length').readUInt32LE(0), 'key')
    .toString('hex');
  const proofScheme = reader.text('proofScheme');
  const metadataCount = reader.take(4, 'metadata.count').readUInt32LE(0);
  for (let i = 0; i < metadataCount; i += 1) {
    reader.text(`metadata[${i}].key`);
    reader.text(`metadata[${i}].value`);
  }
  const statusByte = reader.u8('status');
  if (statusByte !== 0 && statusByte !== 1) {
    throw new Cis8Error(`bad status byte ${statusByte}`);
  }
  const lastUpdatedMs = Number(reader.take(8, 'lastUpdated').readBigUInt64LE(0));
  const trailingHex = bytes.subarray(1 + reader.offset).toString('hex');
  return {
    found: true,
    ownerHex,
    namespace,
    keyType,
    publicKeyHex,
    proofScheme,
    metadataCount,
    status: statusByte === 0 ? 'Active' : 'Revoked',
    lastUpdatedMs,
    trailingHex,
  };
}

/**
 * Derive the EVM address from a secp256k1 public key: last 20 bytes of
 * keccak256(x || y). Accepts uncompressed (`04`, 65 bytes) and compressed
 * (`02`/`03`, 33 bytes) forms; compressed keys are decompressed first.
 * Returns lowercase `0x` form; callers compare case-insensitively.
 */
export function deriveEvmAddress(publicKeyHex: string): string {
  const clean = publicKeyHex.startsWith('0x') ? publicKeyHex.slice(2) : publicKeyHex;
  if (!/^[0-9a-fA-F]+$/.test(clean)) {
    throw new Cis8Error('public key is not hex');
  }
  let x: Uint8Array;
  let y: Uint8Array;
  if (clean.length === 130 && clean.toLowerCase().startsWith('04')) {
    x = Buffer.from(clean.slice(2, 66), 'hex');
    y = Buffer.from(clean.slice(66, 130), 'hex');
  } else if (clean.length === 66 && /^[0-9a-fA-F]{2}/.test(clean)) {
    const prefix = clean.slice(0, 2).toLowerCase();
    if (prefix !== '02' && prefix !== '03') {
      throw new Cis8Error('bad compressed key prefix');
    }
    let point;
    try {
      point = secp256k1.ProjectivePoint.fromHex(clean.toLowerCase());
    } catch {
      throw new Cis8Error('not a secp256k1 curve point');
    }
    const uncompressed = point.toRawBytes(false);
    x = uncompressed.subarray(1, 33);
    y = uncompressed.subarray(33, 65);
  } else {
    throw new Cis8Error('public key must be 65-byte uncompressed or 33-byte compressed');
  }
  const digest = keccak256(`0x${Buffer.concat([Buffer.from(x), Buffer.from(y)]).toString('hex')}` as `0x${string}`);
  return `0x${digest.slice(-40)}`;
}

/** X-coordinate hex of a secp256k1 key in either encoding (encoding-agnostic identity). */
export function keyXCoordinate(publicKeyHex: string): string {
  const clean = (publicKeyHex.startsWith('0x') ? publicKeyHex.slice(2) : publicKeyHex).toLowerCase();
  if (clean.length === 130 && clean.startsWith('04')) {
    return clean.slice(2, 66);
  }
  if (clean.length === 66 && (clean.startsWith('02') || clean.startsWith('03'))) {
    return clean.slice(2, 66);
  }
  throw new Cis8Error('public key must be 65-byte uncompressed or 33-byte compressed');
}
