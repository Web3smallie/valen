/**
 * Fresh EVM wallet co-signature.
 *
 * Closes the one residual the CIS-8 binding leaves open: a binding proves
 * the key holder cooperated with the Concordium account AT REGISTRATION,
 * while `msg.sender` proves key control AT TRANSACTION time — but neither
 * proves the CURRENT key holder still accepts THIS borrowing relationship.
 * A key sold or shared after binding would otherwise pass both checks.
 *
 * The co-signature requires the borrowing wallet to personal_sign a
 * canonical Valen message binding (wallet, Concordium account, borrower
 * id, server nonce, expiry, chain id) during paper issuance. Combined
 * with a fresh Step-1 presentation, both sides demonstrably accept the
 * relationship within the paper window.
 *
 * Nonces are server-issued, single-use, expiring, and label-bound, and
 * are consumed only after a signature verifies (valid signatures cannot
 * be replayed; typos just need a fresh nonce).
 */

import { randomBytes } from 'node:crypto';
import { isAddress, recoverMessageAddress } from 'viem';
import { ConcordiumError, type Clock, type EvmAddress, type UnixMs } from './types.js';

export const COSIGNATURE_DOMAIN = 'Valen-Concordium-Binding/v1';

export interface CoSignatureFields {
  readonly wallet: EvmAddress;
  readonly concordiumAccount: string;
  readonly agentId: bigint;
  readonly nonceHex: string;
  readonly expiryMs: number;
  readonly chainId: number;
}

function assertHex64(value: string, what: string): string {
  if (!/^[0-9a-f]{64}$/.test(value)) {
    throw new ConcordiumError('COSIG_BAD_SIGNATURE', `malformed ${what}`);
  }
  return value;
}

/** Canonical message bytes. Any deviation fails closed at recovery time. */
export function buildCoSignatureMessage(fields: CoSignatureFields): string {
  if (!isAddress(fields.wallet)) {
    throw new ConcordiumError('COSIG_WALLET_MISMATCH', 'wallet is not an address');
  }
  if (!/^[1-9A-HJ-NP-Za-km-z]{40,64}$/.test(fields.concordiumAccount)) {
    throw new ConcordiumError('COSIG_PAYLOAD_MISMATCH', 'concordium account malformed');
  }
  if (fields.agentId < 0n) {
    throw new ConcordiumError('COSIG_PAYLOAD_MISMATCH', 'agent id negative');
  }
  assertHex64(fields.nonceHex, 'nonce');
  if (!Number.isInteger(fields.expiryMs) || fields.expiryMs <= 0) {
    throw new ConcordiumError('COSIG_EXPIRED', 'expiry malformed');
  }
  if (!Number.isInteger(fields.chainId) || fields.chainId <= 0) {
    throw new ConcordiumError('COSIG_PAYLOAD_MISMATCH', 'chain id malformed');
  }
  return (
    `${COSIGNATURE_DOMAIN}\n` +
    `wallet:${fields.wallet.toLowerCase()}\n` +
    `concordium:${fields.concordiumAccount}\n` +
    `agent:${fields.agentId.toString(10)}\n` +
    `nonce:${fields.nonceHex}\n` +
    `expiry:${fields.expiryMs}\n` +
    `chain:${fields.chainId}`
  );
}

interface NonceRecord {
  readonly nonceHex: string;
  readonly label: string;
  readonly expiresAtMs: UnixMs;
  consumed: boolean;
}

export class NonceService {
  private readonly records = new Map<string, NonceRecord>();
  private readonly ttlMs: number;
  private readonly now: Clock;
  private readonly randomHex: (bytes: number) => string;

  constructor(
    ttlMs: number,
    now: Clock = Date.now,
    randomHex?: (bytes: number) => string,
  ) {
    if (!Number.isInteger(ttlMs) || ttlMs <= 0) {
      throw new ConcordiumError('COSIG_EXPIRED', 'ttl must be positive');
    }
    this.ttlMs = ttlMs;
    this.now = now;
    this.randomHex =
      randomHex ?? ((bytes: number): string => randomBytes(bytes).toString('hex'));
  }

  issue(label: string): { nonceHex: string; expiresAtMs: UnixMs } {
    if (label.length === 0) {
      throw new ConcordiumError('COSIG_PAYLOAD_MISMATCH', 'label required');
    }
    const createdAtMs = this.now();
    const record: NonceRecord = {
      nonceHex: this.randomHex(32),
      label,
      expiresAtMs: createdAtMs + this.ttlMs,
      consumed: false,
    };
    this.records.set(record.nonceHex, record);
    this.prune(createdAtMs);
    return { nonceHex: record.nonceHex, expiresAtMs: record.expiresAtMs };
  }

  /** Consume strictly after successful verification (see `verifyCoSignature`). */
  consume(nonceHex: string, label: string): void {
    const record = this.records.get(nonceHex);
    if (record === undefined) {
      throw new ConcordiumError('COSIG_NONCE_UNKNOWN');
    }
    if (record.label !== label) {
      throw new ConcordiumError('COSIG_PAYLOAD_MISMATCH', 'nonce bound to another wallet/agent');
    }
    if (record.consumed) {
      throw new ConcordiumError('COSIG_NONCE_REUSED');
    }
    if (this.now() > record.expiresAtMs) {
      throw new ConcordiumError('COSIG_EXPIRED');
    }
    record.consumed = true;
  }

  private prune(nowMs: UnixMs): void {
    for (const [nonceHex, record] of this.records) {
      if (record.expiresAtMs <= nowMs) {
        this.records.delete(nonceHex);
      }
    }
  }
}

export interface CoSignatureInput extends CoSignatureFields {
  /** `0x` + 130 hex chars (65-byte secp256k1 signature). */
  readonly signature: string;
  /**
   * The exact message bytes the wallet claims to have signed. Compared
   * against the server-rebuilt canonical form BEFORE recovery so
   * implementation drift surfaces as a payload error, not a silent
   * address mismatch.
   */
  readonly presentedMessage?: string;
}

export async function verifyCoSignature(
  nonces: NonceService,
  input: CoSignatureInput,
  nowMs: number,
): Promise<EvmAddress> {
  if (!/^0x[0-9a-fA-F]{130}$/.test(input.signature)) {
    throw new ConcordiumError('COSIG_BAD_SIGNATURE', 'malformed signature encoding');
  }
  if (nowMs > input.expiryMs) {
    throw new ConcordiumError('COSIG_EXPIRED');
  }
  const canonical = buildCoSignatureMessage(input);
  if (input.presentedMessage !== undefined && input.presentedMessage !== canonical) {
    throw new ConcordiumError('COSIG_PAYLOAD_MISMATCH');
  }
  let recovered: string;
  try {
    recovered = await recoverMessageAddress({
      message: canonical,
      signature: input.signature as `0x${string}`,
    });
  } catch {
    throw new ConcordiumError('COSIG_BAD_SIGNATURE', 'unrecoverable signature');
  }
  if (recovered.toLowerCase() !== input.wallet.toLowerCase()) {
    throw new ConcordiumError('COSIG_WALLET_MISMATCH');
  }
  nonces.consume(input.nonceHex, nonceLabel(input.wallet, input.agentId));
  return recovered.toLowerCase() as EvmAddress;
}

export function nonceLabel(wallet: EvmAddress, agentId: bigint): string {
  return `${wallet.toLowerCase()}:${agentId.toString(10)}`;
}
