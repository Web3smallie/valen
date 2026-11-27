/**
 * Prover account and credential validation.
 *
 * Operates on live chain data (via the `ConcordiumNode` interface) and
 * enforces, independently of anything the wallet asserts:
 * - Exactly one credential (multi-signature accounts are out of scope and
 *   rejected — attribution would be ambiguous).
 * - Standard (`normal`) credential with on-chain commitments. `Initial`
 *   credentials carry no commitments and cannot anchor ZK proofs.
 * - Credential id matches the proof's prover (binds the proof to the
 *   resolved account; defeats credential substitution).
 * - Issuing IDP is in Valen's allowlist.
 * - Credential validity window (`createdAt`/`validTo`, YYYYMM) covers now.
 *
 * Returns the attribute commitments the caller feeds to presentation
 * verification as public inputs.
 */

import type { AccountView, ConcordiumNode } from './node.js';
import { ConcordiumError } from './types.js';

export interface CheckedProver {
  readonly accountAddress: string;
  readonly credIdHex: string;
  readonly ipIdentity: number;
  /** Public inputs for `verifyPresentation` (account-credential family). */
  readonly publicData: unknown;
}

function endOfMonthUtc(yyyymm: string): number | null {
  const match = /^(\d{4})(0[1-9]|1[0-2])$/.exec(yyyymm);
  if (!match) {
    return null;
  }
  const year = Number.parseInt(match[1], 10);
  const monthZeroBased = Number.parseInt(match[2], 10) - 1;
  return Date.UTC(year, monthZeroBased + 1, 1, 0, 0, 0, 0) - 1;
}

function startOfMonthUtc(yyyymm: string): number | null {
  const match = /^(\d{4})(0[1-9]|1[0-2])$/.exec(yyyymm);
  if (!match) {
    return null;
  }
  const year = Number.parseInt(match[1], 10);
  const monthZeroBased = Number.parseInt(match[2], 10) - 1;
  return Date.UTC(year, monthZeroBased, 1, 0, 0, 0, 0);
}

export interface CredentialStanding {
  readonly credIdHex: string;
  readonly ipIdentity: number;
  readonly commitments: Record<string, string>;
}

/**
 * Standing checks that need no proof output (single/normal credential,
 * IDP allowlist, validity window). Run BEFORE presentation verification
 * so its public inputs come from a vetted credential.
 */
export function checkCredentialStanding(
  account: AccountView,
  idpAllowlist: readonly number[],
  nowMs: number,
): CredentialStanding {
  if (account.credentials.length !== 1) {
    throw new ConcordiumError(
      'PROVER_MULTI_CREDENTIAL',
      `expected exactly 1 credential, saw ${account.credentials.length}`,
    );
  }
  const credential = account.credentials[0];
  if (credential.type !== 'normal') {
    throw new ConcordiumError(
      'PROVER_INITIAL_CREDENTIAL',
      `credential type '${credential.type}' cannot anchor proofs`,
    );
  }
  if (!idpAllowlist.includes(credential.ipIdentity)) {
    throw new ConcordiumError(
      'IDP_NOT_ALLOWLISTED',
      `credential issued by IDP ${credential.ipIdentity}`,
    );
  }
  const validFrom = startOfMonthUtc(credential.createdAtYYYYMM);
  const validUntil = endOfMonthUtc(credential.validToYYYYMM);
  if (validFrom === null || validUntil === null) {
    throw new ConcordiumError('CREDENTIAL_EXPIRED', 'unparseable validity window');
  }
  if (nowMs < validFrom) {
    throw new ConcordiumError('CREDENTIAL_NOT_YET_VALID');
  }
  if (nowMs > validUntil) {
    throw new ConcordiumError('CREDENTIAL_EXPIRED');
  }
  return {
    credIdHex: credential.credIdHex.toLowerCase(),
    ipIdentity: credential.ipIdentity,
    commitments: { ...credential.commitments },
  };
}

export function checkProverCredential(
  account: AccountView,
  proverCredIdHex: string,
  idpAllowlist: readonly number[],
  nowMs: number,
): CheckedProver {
  const standing = checkCredentialStanding(account, idpAllowlist, nowMs);
  if (standing.credIdHex.toLowerCase() !== proverCredIdHex.toLowerCase()) {
    throw new ConcordiumError('PROVER_CRED_MISMATCH');
  }
  return {
    accountAddress: account.address,
    credIdHex: standing.credIdHex,
    ipIdentity: standing.ipIdentity,
    publicData: [{ type: 'account', commitments: { ...standing.commitments } }],
  };
}

export async function resolveProver(
  node: ConcordiumNode,
  expectedAccount: string,
  proverCredIdHex: string,
  idpAllowlist: readonly number[],
  nowMs: number,
): Promise<CheckedProver> {
  let account: AccountView;
  try {
    account = await node.getAccount(expectedAccount);
  } catch (error) {
    if (error instanceof ConcordiumError) {
      throw error;
    }
    throw new ConcordiumError('PROVER_NOT_FOUND');
  }
  if (account.address.toLowerCase() !== expectedAccount.toLowerCase()) {
    throw new ConcordiumError('PROVER_CRED_MISMATCH');
  }
  return checkProverCredential(account, proverCredIdHex, idpAllowlist, nowMs);
}
