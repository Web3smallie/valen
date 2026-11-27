/**
 * Valen service-agent registration on Concordium Testnet (Step 1).
 *
 * Valen itself holds ONE service-agent identity in the CIS-8004 Agent
 * Registry — separate from borrower agents, which Valen never creates,
 * onboards, or operates. This module prepares that registration and
 * confirms it afterwards. It NEVER signs, submits, or broadcasts:
 * producing the descriptor is where this module stops, and a human
 * signs with the owner wallet.
 *
 * Registration shape (Step 1 only): BARE — no agent_uri, no
 * metadata_hash, no external_reference, no initial metadata. The Agent
 * Card is pinned later via `setAgentURI` (Step 2) with no
 * re-registration. CIS-8 binding, badge, and verifier work are
 * explicitly out of scope for this step.
 *
 * Wire provenance (all three agree):
 * - CIS-8004 proposal: RegisterParam with three absent optionals +
 *   u32 metadata count 0.
 * - Official MCP `build_register` (testnet, 2026-11-23): parameter_hex
 *   `00000000000000`, receive_name `CIS-8004.register`, energy 30000.
 * - `CIS-8004.agentOf` invoked live against testnet <12802,0> and
 *   cross-checked field-by-field against MCP `agent_of`.
 */

import { AccountAddress } from '@concordium/web-sdk';
import type { ConcordiumNode } from './node.js';
import { ConcordiumError, type ConcordiumAccount } from './types.js';

/** CIS-8004 `register` receive name (MCP-verified). */
export const CIS8004_REGISTER_RECEIVE_NAME = 'CIS-8004.register';

/** CIS-8004 `agentOf` view receive name (invoked live on testnet). */
export const CIS8004_AGENT_OF_RECEIVE_NAME = 'CIS-8004.agentOf';

/**
 * Exact parameter bytes for a bare registration: three absent
 * optionals (uri, hash, external reference) + u32 metadata count 0.
 */
export const BARE_REGISTER_PARAMETER_HEX = '00000000000000';

/** Energy budget suggested by the official MCP `build_register`. */
export const REGISTER_SUGGESTED_ENERGY = 30000;

export interface ServiceAgentRegistration {
  readonly network: 'testnet';
  readonly contractIndex: bigint;
  readonly contractSubindex: bigint;
  readonly receiveName: string;
  readonly parameterHex: string;
  readonly suggestedEnergy: number;
  /** Owner account that must sign and submit (mint recipient). */
  readonly sender: ConcordiumAccount;
  /** Lowercase 32-byte hex of the sender account. */
  readonly senderHex: string;
  readonly ccdscanUrl: string;
}

export interface RegistrationInput {
  readonly sender: ConcordiumAccount;
  readonly contractIndex: bigint;
  readonly contractSubindex: bigint;
}

/**
 * Build the exact transaction descriptor for Valen's bare service-agent
 * registration. Returns data for a human to sign — no keys, no signing.
 */
export function buildServiceAgentRegistration(input: RegistrationInput): ServiceAgentRegistration {
  let senderHex: string;
  try {
    senderHex = Buffer.from(AccountAddress.fromBase58(input.sender).decodedAddress).toString('hex');
  } catch {
    throw new ConcordiumError('SERVICE_AGENT_SENDER_MALFORMED', 'sender is not a valid Concordium account');
  }
  return {
    network: 'testnet',
    contractIndex: input.contractIndex,
    contractSubindex: input.contractSubindex,
    receiveName: CIS8004_REGISTER_RECEIVE_NAME,
    parameterHex: BARE_REGISTER_PARAMETER_HEX,
    suggestedEnergy: REGISTER_SUGGESTED_ENERGY,
    sender: input.sender,
    senderHex,
    ccdscanUrl: `https://testnet.ccdscan.io/?dcount=1&dentity=contract&daddress=${input.contractIndex}`,
  };
}

const U64_MAX = 18446744073709551615n;

/** `AgentTokenId` wire form: 0x08 length prefix + u64 LE token id. */
export function encodeAgentTokenId(tokenId: bigint): string {
  if (typeof tokenId !== 'bigint' || tokenId < 0n || tokenId > U64_MAX) {
    throw new ConcordiumError('SERVICE_AGENT_TOKEN_ID_INVALID', 'token id must be a u64');
  }
  const id = Buffer.alloc(8);
  id.writeBigUInt64LE(tokenId);
  return Buffer.concat([Buffer.from([8]), id]).toString('hex');
}

function stripHex(value: string): string {
  const clean = value.startsWith('0x') || value.startsWith('0X') ? value.slice(2) : value;
  if (!/^[0-9a-fA-F]*$/.test(clean) || clean.length % 2 !== 0) {
    throw new ConcordiumError('NODE_ERROR', 'not even-length hex');
  }
  return clean.toLowerCase();
}

class Cursor {
  private offset = 0;

  constructor(private readonly buffer: Buffer) {}

  take(length: number, what: string): Buffer {
    if (this.offset + length > this.buffer.length) {
      throw new ConcordiumError('NODE_ERROR', `truncated agentOf response (${what})`);
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

  takeU64(what: string): bigint {
    return this.take(8, what).readBigUInt64LE(0);
  }

  takeU64Ms(what: string): number {
    return Number(this.takeU64(what));
  }

  takeString(what: string): string {
    const length = this.takeU32(`${what}.length`);
    return this.take(length, what).toString('utf8');
  }
}

export interface ServiceAgentExternalReference {
  readonly contractIndex: bigint;
  readonly contractSubindex: bigint;
  readonly kind: 'Cis8';
  readonly namespace: string;
  readonly keyType: string;
  readonly publicKeyHex: string;
}

export interface ServiceAgentRecord {
  readonly tokenId: bigint;
  readonly ownerHex: string;
  readonly agentUri: string | null;
  readonly metadataHashHex: string | null;
  readonly externalReference: ServiceAgentExternalReference | null;
  readonly agentWalletHex: string | null;
  readonly status: 'Active' | 'Revoked';
  readonly registeredAtMs: number;
  readonly revokedAtMs: number | null;
  readonly revocationReason: string | null;
}

function takeOptional(cursor: Cursor, what: string): boolean {
  const tag = cursor.takeByte(`${what}.tag`);
  if (tag !== 0 && tag !== 1) {
    throw new ConcordiumError('NODE_ERROR', `unknown option tag ${tag} (${what})`);
  }
  return tag === 1;
}

function parseExternalReference(cursor: Cursor): ServiceAgentExternalReference {
  const contractIndex = cursor.takeU64('externalReference.contractIndex');
  const contractSubindex = cursor.takeU64('externalReference.contractSubindex');
  const kindTag = cursor.takeByte('externalReference.kind');
  // Cis8 (tag 0) is the only kind the standard defines; anything else
  // has an unknown length, so fail closed rather than skip blindly.
  if (kindTag !== 0) {
    throw new ConcordiumError('NODE_ERROR', `unknown external reference kind ${kindTag}`);
  }
  const namespace = cursor.takeString('externalReference.namespace');
  const keyType = cursor.takeString('externalReference.keyType');
  const keyLength = cursor.takeU32('externalReference.publicKey.length');
  const publicKeyHex = cursor.take(keyLength, 'externalReference.publicKey').toString('hex');
  return { contractIndex, contractSubindex, kind: 'Cis8', namespace, keyType, publicKeyHex };
}

function parseAgentView(cursor: Cursor): ServiceAgentRecord {
  const lengthPrefix = cursor.takeByte('tokenId.length');
  if (lengthPrefix !== 8) {
    throw new ConcordiumError('NODE_ERROR', `unexpected token id prefix ${lengthPrefix}`);
  }
  const tokenId = cursor.takeU64('tokenId');
  const ownerHex = cursor.take(32, 'owner').toString('hex');
  const agentUri = takeOptional(cursor, 'agentUri') ? cursor.takeString('agentUri') : null;
  const metadataHashHex = takeOptional(cursor, 'metadataHash')
    ? cursor.take(32, 'metadataHash').toString('hex')
    : null;
  const externalReference = takeOptional(cursor, 'externalReference')
    ? parseExternalReference(cursor)
    : null;
  const agentWalletHex = takeOptional(cursor, 'agentWallet')
    ? cursor.take(32, 'agentWallet').toString('hex')
    : null;
  const statusByte = cursor.takeByte('status');
  if (statusByte !== 0 && statusByte !== 1) {
    throw new ConcordiumError('NODE_ERROR', `unknown agent status ${statusByte}`);
  }
  const registeredAtMs = cursor.takeU64Ms('registeredAt');
  const revokedAtMs = takeOptional(cursor, 'revokedAt') ? cursor.takeU64Ms('revokedAt') : null;
  const revocationReason = takeOptional(cursor, 'revocationReason')
    ? cursor.takeString('revocationReason')
    : null;
  return {
    tokenId,
    ownerHex,
    agentUri,
    metadataHashHex,
    externalReference,
    agentWalletHex,
    status: statusByte === 0 ? 'Active' : 'Revoked',
    registeredAtMs,
    revokedAtMs,
    revocationReason,
  };
}

/**
 * Parse an `agentOf` return value. The deployed contract answers `0x00`
 * for unknown tokens (observed live); a present record is `0x01` +
 * AgentView. Trailing bytes beyond the spec are tolerated; truncated
 * or structurally invalid responses reject.
 */
export function parseAgentOfResponse(
  returnHex: string,
): { found: false } | ({ found: true } & ServiceAgentRecord) {
  const bytes = Buffer.from(stripHex(returnHex), 'hex');
  if (bytes.length === 0) {
    throw new ConcordiumError('NODE_ERROR', 'empty agentOf response');
  }
  if (bytes[0] === 0x00) {
    return { found: false };
  }
  if (bytes[0] !== 0x01) {
    throw new ConcordiumError('NODE_ERROR', 'malformed agentOf response tag');
  }
  return { found: true, ...parseAgentView(new Cursor(bytes.subarray(1))) };
}

export interface ServiceAgentExpectation {
  readonly contractIndex: bigint;
  readonly contractSubindex: bigint;
  readonly tokenId: bigint;
  readonly expectedOwnerHex: string;
}

export interface VerifiedServiceAgent {
  readonly tokenId: bigint;
  readonly ownerHex: string;
  readonly status: 'Active';
  readonly registeredAtMs: number;
  readonly agentUri: string | null;
  readonly metadataHashHex: string | null;
}

/**
 * Confirm Valen's service-agent registration from live chain state:
 * the token exists, echoes the requested id, is Active, and is owned
 * by the expected account. Any deviation rejects (fail closed).
 */
export async function verifyServiceAgentRegistration(
  node: ConcordiumNode,
  expected: ServiceAgentExpectation,
): Promise<VerifiedServiceAgent> {
  const paramHex = encodeAgentTokenId(expected.tokenId);
  let returnHex: string;
  try {
    returnHex = await node.invokeAgentOf(expected.contractIndex, expected.contractSubindex, paramHex);
  } catch (error) {
    if (error instanceof ConcordiumError) {
      throw error;
    }
    throw new ConcordiumError('NODE_ERROR', 'agentOf query failed');
  }
  const parsed = parseAgentOfResponse(returnHex);
  if (!parsed.found) {
    throw new ConcordiumError('SERVICE_AGENT_NOT_FOUND');
  }
  if (parsed.tokenId !== expected.tokenId) {
    throw new ConcordiumError('SERVICE_AGENT_NOT_FOUND', 'registry echoed a different token id');
  }
  if (parsed.status !== 'Active') {
    throw new ConcordiumError('SERVICE_AGENT_REVOKED');
  }
  const expectedOwner = stripHex(expected.expectedOwnerHex);
  if (parsed.ownerHex.toLowerCase() !== expectedOwner) {
    throw new ConcordiumError('SERVICE_AGENT_OWNER_MISMATCH');
  }
  return {
    tokenId: parsed.tokenId,
    ownerHex: parsed.ownerHex,
    status: 'Active',
    registeredAtMs: parsed.registeredAtMs,
    agentUri: parsed.agentUri,
    metadataHashHex: parsed.metadataHashHex,
  };
}
