/**
 * CIS-8 external-key binding verification (read-only).
 *
 * Establishes, from live chain state, that a Concordium account currently
 * owns a binding for a specific external public key — and that the key
 * derives to the exact EVM borrowing wallet Valen will lend to.
 *
 * Trust rules (all enforced, all fail closed):
 * - The binding is read fresh from the pinned CIS-8 instance every time.
 *   Absent (`0x00`), revoked, or owner-mismatched bindings reject.
 *   Owner mismatch is the expected signature of key displacement.
 * - Namespace must match Valen's EVM allowlist; key type must be an
 *   allowed secp256k1 encoding. The deployed registry normalizes
 *   compressed/uncompressed queries to one registration, so comparison
 *   is by x-coordinate, never by raw encoding.
 * - The EVM address is ALWAYS recomputed locally from the key bytes.
 *   The registry's `external_address` metadata is registrant-asserted
 *   and MUST never be trusted.
 * - Trailing bytes in contract responses are tolerated (the deployed
 *   contracts append fields beyond the spec text); truncated or
 *   structurally invalid responses reject.
 */

import { keccak256 } from 'viem';
import { secp256k1 } from '@noble/curves/secp256k1';
import type { ConcordiumNode } from './node.js';
import { ConcordiumError, type EvmAddress } from './types.js';

export interface ExternalKeyId {
  readonly namespace: string;
  readonly keyType: string;
  /** Hex public key bytes WITHOUT 0x prefix (any case). */
  readonly publicKeyHex: string;
}

export interface Cis8Registration {
  readonly ownerHex: string;
  readonly namespace: string;
  readonly keyType: string;
  readonly publicKeyHex: string;
  readonly proofScheme: string;
  readonly status: 'Active' | 'Revoked';
  readonly lastUpdatedMs: number;
}

function stripHex(value: string): string {
  const clean = value.startsWith('0x') || value.startsWith('0X') ? value.slice(2) : value;
  if (!/^[0-9a-fA-F]*$/.test(clean) || clean.length % 2 !== 0) {
    throw new ConcordiumError('CIS8_KEY_MALFORMED', 'not even-length hex');
  }
  return clean.toLowerCase();
}

function u32le(value: number): Buffer {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32LE(value);
  return buffer;
}

/** CIS-8 `ExternalKeyId` wire encoding: String + String + Bytestring. */
export function encodeExternalKeyId(key: ExternalKeyId): string {
  const publicKey = Buffer.from(stripHex(key.publicKeyHex), 'hex');
  const namespace = Buffer.from(key.namespace, 'utf8');
  const keyType = Buffer.from(key.keyType, 'utf8');
  return Buffer.concat([
    u32le(namespace.length),
    namespace,
    u32le(keyType.length),
    keyType,
    u32le(publicKey.length),
    publicKey,
  ]).toString('hex');
}

class Cursor {
  private offset = 0;

  constructor(private readonly buffer: Buffer) {}

  take(length: number, what: string): Buffer {
    if (this.offset + length > this.buffer.length) {
      throw new ConcordiumError('NODE_ERROR', `truncated ownerOfKey response (${what})`);
    }
    const slice = this.buffer.subarray(this.offset, this.offset + length);
    this.offset += length;
    return slice;
  }

  takeByte(what: string): number {
    return this.take(1, what)[0];
  }

  takeU32(what: string): number {
    return this.take(4, what).readUInt32LE(0);
  }

  takeU64Ms(what: string): number {
    return Number(this.take(8, what).readBigUInt64LE(0));
  }

  takeString(what: string): string {
    const length = this.takeU32(`${what}.length`);
    return this.take(length, what).toString('utf8');
  }
}

function parseRegistration(cursor: Cursor): Cis8Registration {
  const ownerHex = cursor.take(32, 'owner').toString('hex');
  const namespace = cursor.takeString('namespace');
  const keyType = cursor.takeString('keyType');
  const keyLength = cursor.takeU32('publicKey.length');
  const publicKeyHex = cursor.take(keyLength, 'publicKey').toString('hex');
  const proofScheme = cursor.takeString('proofScheme');
  const metadataCount = cursor.takeU32('metadata.length');
  for (let i = 0; i < metadataCount; i += 1) {
    cursor.takeString(`metadata[${i}].key`);
    cursor.takeString(`metadata[${i}].value`);
  }
  const statusByte = cursor.takeByte('status');
  if (statusByte !== 0 && statusByte !== 1) {
    throw new ConcordiumError('NODE_ERROR', `unknown registration status ${statusByte}`);
  }
  const lastUpdatedMs = cursor.takeU64Ms('lastUpdated');
  return {
    ownerHex,
    namespace,
    keyType,
    publicKeyHex,
    proofScheme,
    status: statusByte === 0 ? 'Active' : 'Revoked',
    lastUpdatedMs,
  };
}

/** Parse `ownerOfKey` return data. `0x00` means no active registration. */
export function parseOwnerOfKeyResponse(returnHex: string): { found: false } | ({ found: true } & Cis8Registration) {
  const bytes = Buffer.from(stripHex(returnHex), 'hex');
  if (bytes.length === 0) {
    throw new ConcordiumError('NODE_ERROR', 'empty ownerOfKey response');
  }
  if (bytes[0] === 0x00) {
    return { found: false };
  }
  if (bytes[0] !== 0x01) {
    throw new ConcordiumError('NODE_ERROR', 'malformed ownerOfKey response tag');
  }
  return { found: true, ...parseRegistration(new Cursor(bytes.subarray(1))) };
}

/**
 * Normalize a secp256k1 key to its 32-byte x-coordinate hex.
 * Accepts 33-byte compressed (`02`/`03` prefix) and 65-byte uncompressed
 * (`04` prefix) encodings — the registry treats them as one key.
 */
export function secp256k1X(publicKeyHex: string): string {
  const clean = stripHex(publicKeyHex);
  if (clean.length === 66 && (clean.startsWith('02') || clean.startsWith('03'))) {
    return clean.slice(2);
  }
  if (clean.length === 130 && clean.startsWith('04')) {
    return clean.slice(2, 66);
  }
  throw new ConcordiumError('CIS8_KEY_MALFORMED', 'expected 33-byte compressed or 65-byte uncompressed key');
}

/** Full 64-byte uncompressed key (x‖y), decompressing when necessary. */
function uncompressed64(publicKeyHex: string): Buffer {
  const clean = stripHex(publicKeyHex);
  if (clean.length === 130 && clean.startsWith('04')) {
    return Buffer.from(clean.slice(2), 'hex');
  }
  if (clean.length === 66 && (clean.startsWith('02') || clean.startsWith('03'))) {
    try {
      const point = secp256k1.ProjectivePoint.fromHex(clean);
      return Buffer.from(point.toRawBytes(false).slice(1));
    } catch {
      throw new ConcordiumError('CIS8_KEY_MALFORMED', 'invalid secp256k1 point');
    }
  }
  throw new ConcordiumError('CIS8_KEY_MALFORMED', 'expected 33-byte compressed or 65-byte uncompressed key');
}

/** `address = last20(keccak256(x‖y))`, recomputed locally — always. */
export function deriveEvmAddress(publicKeyHex: string): EvmAddress {
  const digest = keccak256(`0x${uncompressed64(publicKeyHex).toString('hex')}`);
  return `0x${digest.slice(2 + 24)}` as EvmAddress;
}

export interface BindingExpectation {
  readonly namespacePattern: RegExp;
  readonly allowedKeyTypes: readonly string[];
  readonly allowedProofSchemes: readonly string[];
  readonly expectedOwnerHex: string;
  readonly expectedWallet: EvmAddress;
}

export interface VerifiedBinding {
  readonly ownerHex: string;
  readonly address: EvmAddress;
  readonly namespace: string;
  readonly keyType: string;
  readonly proofScheme: string;
  readonly lastUpdatedMs: number;
}

export async function verifyBinding(
  node: ConcordiumNode,
  contractIndex: bigint,
  contractSubindex: bigint,
  key: ExternalKeyId,
  expected: BindingExpectation,
): Promise<VerifiedBinding> {
  if (!expected.namespacePattern.test(key.namespace)) {
    throw new ConcordiumError('CIS8_NAMESPACE_REJECTED', key.namespace);
  }
  if (!expected.allowedKeyTypes.includes(key.keyType)) {
    throw new ConcordiumError('CIS8_KEYTYPE_REJECTED', key.keyType);
  }
  const queriedX = secp256k1X(key.publicKeyHex);

  let returnHex: string;
  try {
    returnHex = await node.invokeOwnerOfKey(contractIndex, contractSubindex, encodeExternalKeyId(key));
  } catch (error) {
    if (error instanceof ConcordiumError) {
      throw error;
    }
    throw new ConcordiumError('NODE_ERROR', 'ownerOfKey query failed');
  }
  const parsed = parseOwnerOfKeyResponse(returnHex);
  if (!parsed.found) {
    throw new ConcordiumError('CIS8_NOT_FOUND');
  }
  if (parsed.status !== 'Active') {
    throw new ConcordiumError('CIS8_REVOKED');
  }
  if (parsed.namespace !== key.namespace) {
    throw new ConcordiumError('CIS8_NAMESPACE_REJECTED', `echoed ${parsed.namespace}`);
  }
  if (!expected.allowedKeyTypes.includes(parsed.keyType)) {
    throw new ConcordiumError('CIS8_KEYTYPE_REJECTED', `echoed ${parsed.keyType}`);
  }
  if (!expected.allowedProofSchemes.includes(parsed.proofScheme)) {
    throw new ConcordiumError('CIS8_PROOF_SCHEME_REJECTED', `echoed ${parsed.proofScheme}`);
  }
  if (secp256k1X(parsed.publicKeyHex) !== queriedX) {
    throw new ConcordiumError('NODE_ERROR', 'registry echoed a different key');
  }
  if (parsed.ownerHex.toLowerCase() !== stripHex(expected.expectedOwnerHex)) {
    throw new ConcordiumError('CIS8_OWNER_MISMATCH');
  }
  const address = deriveEvmAddress(parsed.publicKeyHex);
  if (address.toLowerCase() !== expected.expectedWallet.toLowerCase()) {
    throw new ConcordiumError('EVM_DERIVATION_MISMATCH');
  }
  return {
    ownerHex: parsed.ownerHex,
    address,
    namespace: parsed.namespace,
    keyType: parsed.keyType,
    proofScheme: parsed.proofScheme,
    lastUpdatedMs: parsed.lastUpdatedMs,
  };
}
