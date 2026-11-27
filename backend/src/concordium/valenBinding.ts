/**
 * Valen's own CIS-8 cross-chain binding (Step 2).
 *
 * Links the designated Concordium account to the Arc Testnet EOA that
 * owns Valen's 11 lending contracts. CIS-8 binds an EXTERNAL KEY, not
 * a smart contract: the binding asserts that a Concordium account
 * controls a secp256k1 public key, proven by a signature from that
 * key over the canonical message. The Arc owner address enters only
 * as independently re-derived corroboration (never trusted from
 * registry metadata).
 *
 * This module prepares the binding and verifies it from live chain
 * state. It NEVER signs: producing canonical bytes and descriptors is
 * where it stops. The owner key signs at approval time, and the
 * designated Concordium account submits `registerExternalKey`.
 *
 * EOA assumption: this binding proves control of one secp256k1 key,
 * which is exactly what an EOA owner holds. If Valen moves to
 * multisig/Safe ownership, a single-key CIS-8 binding no longer
 * captures "the contracts are controlled by this party" and a
 * different accountability mechanism is required.
 */

import { AccountAddress } from '@concordium/web-sdk';
import { keccak256 } from 'viem';
import { secp256k1 } from '@noble/curves/secp256k1';
import { verifyBinding, type ExternalKeyId, type VerifiedBinding } from './cis8.js';
import type { ConcordiumNode } from './node.js';
import { ConcordiumError, type ConcordiumAccount, type EvmAddress } from './types.js';

/** Arc Testnet EOA owning all 11 Valen contracts (read live, 2026-11-23). */
export const VALEN_ARC_OWNER = '0xB0E8Ba6aFe21371AD4001e611224FC200FD10144' as EvmAddress;

/** Arc Testnet CAIP namespace (chain id 5042002, see deployments manifest). */
export const VALEN_CIS8_NAMESPACE = 'eip155:5042002';

/** Exact-match gate: Valen's binding MUST carry the Arc namespace. */
export const VALEN_CIS8_NAMESPACE_PATTERN = /^eip155:5042002$/;

/** 65-byte uncompressed secp256k1 — Valen's canonical key encoding. */
export const VALEN_CIS8_KEY_TYPE = 'secp256k1-uncompressed';

/**
 * Registry-normalized echo encoding. The deployed CIS-8 contract stores
 * keys compressed and echoes `secp256k1-compressed` even when the
 * registered key id was uncompressed (observed live on Valen's own
 * binding). Accepted on READ only; submissions stay uncompressed.
 */
export const VALEN_CIS8_NORMALIZED_KEY_TYPE = 'secp256k1-compressed';

/** ECDSA/secp256k1 personal-sign proof (CIS-8 spec, live F1 precedent). */
export const VALEN_CIS8_PROOF_SCHEME = 'ethereum-personal-sign';

function stripHex(value: string, what: string): string {
  const clean = value.startsWith('0x') || value.startsWith('0X') ? value.slice(2) : value;
  if (!/^[0-9a-fA-F]*$/.test(clean) || clean.length % 2 !== 0) {
    throw new ConcordiumError('VALEN_BINDING_INPUT_INVALID', `${what}: not even-length hex`);
  }
  return clean.toLowerCase();
}

function u64le(value: bigint): Buffer {
  const buffer = Buffer.alloc(8);
  buffer.writeBigUInt64LE(value);
  return buffer;
}

function strEnc(text: string): Buffer {
  const bytes = Buffer.from(text, 'utf8');
  const length = Buffer.alloc(4);
  length.writeUInt32LE(bytes.length);
  return Buffer.concat([length, bytes]);
}

/**
 * Build Valen's CIS-8 key identifier from the Arc owner public key.
 * Requires the 65-byte uncompressed form (`04` prefix) on the secp256k1
 * curve — the single canonical encoding for Valen's binding.
 */
export function buildValenBindingKeyId(ownerPublicKeyHex: string): ExternalKeyId {
  const clean = ownerPublicKeyHex.startsWith('0x') || ownerPublicKeyHex.startsWith('0X')
    ? ownerPublicKeyHex.slice(2)
    : ownerPublicKeyHex;
  if (!/^04[0-9a-fA-F]{128}$/.test(clean)) {
    throw new ConcordiumError('CIS8_KEY_MALFORMED', 'expected 65-byte uncompressed secp256k1 key');
  }
  try {
    secp256k1.ProjectivePoint.fromHex(clean.toLowerCase());
  } catch {
    throw new ConcordiumError('CIS8_KEY_MALFORMED', 'not a secp256k1 curve point');
  }
  return {
    namespace: VALEN_CIS8_NAMESPACE,
    keyType: VALEN_CIS8_KEY_TYPE,
    publicKeyHex: clean.toLowerCase(),
  };
}

export interface CanonicalBytesInput {
  readonly concordiumAccount: ConcordiumAccount;
  readonly contractIndex: bigint;
  readonly contractSubindex: bigint;
  /** 32-byte genesis hash hex (chain anchor against cross-network replay). */
  readonly genesisHashHex: string;
  readonly key: ExternalKeyId;
  readonly proofScheme?: string;
}

/**
 * Build the exact CIS-8 canonical bytes the Arc owner key must sign:
 * `CIS-8/v1/canonical` + account + contract + genesis + namespace +
 * key id + scheme. Byte-matches the official MCP
 * `build_cis8_canonical_bytes` for identical inputs.
 */
export function buildCis8CanonicalBytes(input: CanonicalBytesInput): string {
  let account: Buffer;
  try {
    account = Buffer.from(AccountAddress.fromBase58(input.concordiumAccount).decodedAddress);
  } catch {
    throw new ConcordiumError('VALEN_BINDING_INPUT_INVALID', 'concordium account malformed');
  }
  const genesis = Buffer.from(stripHex(input.genesisHashHex, 'genesis hash'), 'hex');
  if (genesis.length !== 32) {
    throw new ConcordiumError('VALEN_BINDING_INPUT_INVALID', 'genesis hash must be 32 bytes');
  }
  if (input.contractIndex < 0n || input.contractSubindex < 0n) {
    throw new ConcordiumError('VALEN_BINDING_INPUT_INVALID', 'contract address must be non-negative');
  }
  const keyBytes = Buffer.from(stripHex(input.key.publicKeyHex, 'public key'), 'hex');
  const keyLength = Buffer.alloc(4);
  keyLength.writeUInt32LE(keyBytes.length);
  const proofScheme = input.proofScheme ?? VALEN_CIS8_PROOF_SCHEME;
  return Buffer.concat([
    Buffer.from('CIS-8/v1/canonical', 'utf8'),
    account,
    u64le(input.contractIndex),
    u64le(input.contractSubindex),
    genesis,
    strEnc(input.key.namespace),
    strEnc(input.key.namespace),
    strEnc(input.key.keyType),
    keyLength,
    keyBytes,
    strEnc(proofScheme),
  ]).toString('hex');
}

/**
 * EIP-191 digest of canonical bytes: keccak(`\x19Ethereum Signed
 * Message:\n<len>` + bytes). This 32-byte hash is what the owner key
 * signs under `ethereum-personal-sign`; the contract re-verifies it
 * by public-key recovery.
 */
export function ethereumPersonalSignDigest(canonicalHex: string): `0x${string}` {
  const bytes = Buffer.from(stripHex(canonicalHex, 'canonical bytes'), 'hex');
  const envelope = Buffer.concat([
    Buffer.from(`\x19Ethereum Signed Message:\n${bytes.length}`, 'utf8'),
    bytes,
  ]);
  return keccak256(`0x${envelope.toString('hex')}` as `0x${string}`);
}

export interface ValenBindingExpectation {
  readonly contractIndex: bigint;
  readonly contractSubindex: bigint;
  readonly key: ExternalKeyId;
  readonly expectedOwnerHex: string;
  readonly expectedWallet: EvmAddress;
}

/**
 * Verify Valen's binding from live CIS-8 state: namespace pinned to
 * Arc Testnet, personal-sign scheme, Active, owned by the expected
 * Concordium account, and re-derived to the expected Arc owner
 * address. The queried key must be Valen's uncompressed id; the
 * registry's normalized compressed echo is accepted. Key identity is
 * pinned by x-coordinate equality, never by the encoding label. Any
 * deviation rejects (fail closed).
 */
export function verifyValenBinding(
  node: ConcordiumNode,
  expected: ValenBindingExpectation,
): Promise<VerifiedBinding> {
  return verifyBinding(node, expected.contractIndex, expected.contractSubindex, expected.key, {
    namespacePattern: VALEN_CIS8_NAMESPACE_PATTERN,
    allowedKeyTypes: [VALEN_CIS8_KEY_TYPE, VALEN_CIS8_NORMALIZED_KEY_TYPE],
    allowedProofSchemes: [VALEN_CIS8_PROOF_SCHEME],
    expectedOwnerHex: expected.expectedOwnerHex,
    expectedWallet: expected.expectedWallet,
  });
}

export interface ArcOwnerReader {
  readOwner(contractAddress: string): Promise<EvmAddress>;
}

export interface ArcOwnerExpectation {
  readonly contractAddresses: readonly string[];
  readonly expectedWallet: EvmAddress;
}

/**
 * Confirm every listed Arc contract reports the expected owner.
 * Fails closed on the first mismatch — and on an empty list, which
 * would otherwise pass vacuously.
 */
export async function verifyArcContractOwners(
  reader: ArcOwnerReader,
  expected: ArcOwnerExpectation,
): Promise<{ checked: number; owner: EvmAddress }> {
  if (expected.contractAddresses.length === 0) {
    throw new ConcordiumError('VALEN_ARC_OWNER_MISMATCH', 'no contract addresses provided');
  }
  const want = expected.expectedWallet.toLowerCase();
  for (const contractAddress of expected.contractAddresses) {
    const owner = (await reader.readOwner(contractAddress)).toLowerCase();
    if (owner !== want) {
      throw new ConcordiumError(
        'VALEN_ARC_OWNER_MISMATCH',
        `${contractAddress} reports owner ${owner}`,
      );
    }
  }
  return { checked: expected.contractAddresses.length, owner: expected.expectedWallet };
}
