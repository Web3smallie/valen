/**
 * Concordium presentation verification.
 *
 * Wraps `@concordium/web-sdk` `verifyPresentation` (WASM cryptographic
 * verification) with Valen's binding checks. The SDK call proves the
 * cryptography; every line below it proves the proof is OURS:
 * our challenge, our statement snapshot, our network, one credential.
 *
 * Responsibilities split (mirrors the audited gallery-verifier logic):
 * - SDK: proof validity against global context + supplied commitments.
 * - This module: challenge equality, statement equality, network match,
 *   single-statement shape, prover DID parsing.
 * - credentials.ts: prover account standing (credential type, IDP, window).
 * - challenge.ts: issuance freshness, expiry, single-use (called before this).
 *
 * @param cryptoVerify injectable SDK call (default: real `verifyPresentation`).
 *   Injection exists ONLY so Valen-side matching logic is unit-testable
 *   without a live wallet credential. The default path always runs the
 *   real cryptographic verification.
 */

import { verifyPresentation as sdkVerifyPresentation } from '@concordium/web-sdk';
import { timingSafeEqual } from 'node:crypto';
import { canonicalJson } from './policy.js';
import { ConcordiumError, type ConcordiumNetwork } from './types.js';

export type CryptoVerifyFn = (
  presentation: unknown,
  globalContext: unknown,
  publicData: unknown,
) => unknown;

export interface ProvenPresentation {
  /** Credential id (hex) the proof was generated for, from the proven DID. */
  readonly proverCredIdHex: string;
  readonly network: ConcordiumNetwork;
}

interface ParsedRequestStatement {
  readonly id: string;
  readonly statement: unknown;
  readonly hasWeb3IdType: boolean;
}

function asRecord(value: unknown, what: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null) {
    throw new ConcordiumError('PRESENTATION_MALFORMED', `expected object (${what})`);
  }
  return value as Record<string, unknown>;
}

function hexEqual(a: string, b: string): boolean {
  if (!/^[0-9a-fA-F]*$/.test(a) || !/^[0-9a-fA-F]*$/.test(b)) {
    return false;
  }
  const ab = Buffer.from(a.toLowerCase(), 'hex');
  const bb = Buffer.from(b.toLowerCase(), 'hex');
  return ab.length === bb.length && ab.length > 0 && timingSafeEqual(ab, bb);
}

/** Parse `did:ccd:<network>:cred:<credIdHex>`. */
export function parseAccountDid(did: string): { network: ConcordiumNetwork; credIdHex: string } {
  const match = /^did:ccd:(testnet|mainnet):cred:([0-9a-fA-F]{96})$/.exec(did);
  if (!match) {
    throw new ConcordiumError('PRESENTATION_MALFORMED', 'prover is not an account-credential DID');
  }
  return { network: match[1] as ConcordiumNetwork, credIdHex: match[2].toLowerCase() };
}

export interface VerifyPresentationInput {
  readonly presentation: unknown;
  readonly globalContext: unknown;
  /** Commitments for the expected prover account, from live chain data. */
  readonly publicData: unknown;
  readonly expectedChallengeHex: string;
  readonly expectedStatements: unknown;
  readonly expectedNetwork: ConcordiumNetwork;
  readonly cryptoVerify?: CryptoVerifyFn;
}

export function verifyPresentationAndMatch(input: VerifyPresentationInput): ProvenPresentation {
  const cryptoVerify: CryptoVerifyFn =
    input.cryptoVerify ?? (sdkVerifyPresentation as unknown as CryptoVerifyFn);

  asRecord(input.presentation, 'presentation');

  let proven: unknown;
  try {
    proven = cryptoVerify(input.presentation, input.globalContext, input.publicData);
  } catch (error) {
    throw new ConcordiumError(
      'PRESENTATION_CRYPTO_REJECTED',
      error instanceof Error ? error.message.slice(0, 200) : String(error).slice(0, 200),
    );
  }

  const request = asRecord(proven, 'proven request');
  if (typeof request['challenge'] !== 'string') {
    throw new ConcordiumError('PRESENTATION_MALFORMED', 'proven request lacks challenge');
  }
  if (!hexEqual(request['challenge'] as string, input.expectedChallengeHex)) {
    throw new ConcordiumError('PRESENTATION_CHALLENGE_MISMATCH');
  }

  const statements = request['credentialStatements'];
  if (!Array.isArray(statements) || statements.length !== 1) {
    throw new ConcordiumError(
      'PRESENTATION_STATEMENT_MISMATCH',
      'exactly one credential statement required',
    );
  }
  const provenStatement = asRecord(statements[0], 'credential statement') as unknown as ParsedRequestStatement;
  if (provenStatement.hasWeb3IdType || (statements[0] as Record<string, unknown>)['type'] !== undefined) {
    throw new ConcordiumError(
      'PRESENTATION_MALFORMED',
      'account credentials required (not Web3ID issuer credentials)',
    );
  }
  if (typeof provenStatement.id !== 'string') {
    throw new ConcordiumError('PRESENTATION_MALFORMED', 'credential statement lacks id');
  }
  if (canonicalJson(provenStatement.statement) !== canonicalJson(input.expectedStatements)) {
    throw new ConcordiumError('PRESENTATION_STATEMENT_MISMATCH');
  }

  const { network, credIdHex } = parseAccountDid(provenStatement.id);
  if (network !== input.expectedNetwork) {
    throw new ConcordiumError('PRESENTATION_NETWORK_MISMATCH');
  }
  return { proverCredIdHex: credIdHex, network };
}
