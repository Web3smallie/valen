/**
 * Shared types and errors for Valen's Concordium verification module.
 *
 * Every verification failure is raised as a ConcordiumError carrying a
 * machine-readable `code`. Callers MUST treat any throw as rejection
 * (fail closed) and MUST NOT distinguish error kinds for control flow
 * other than logging and metrics.
 */

export type HexString = `0x${string}`;

/** Lowercase 64-hex-char challenge secret (no 0x prefix). */
export type ChallengeHex = string;

/** Concordium account address in base58check presentation format. */
export type ConcordiumAccount = string;

/** EVM address (`0x` + 40 hex chars, any case; compared lowercased). */
export type EvmAddress = `0x${string}`;

/** Networks Valen accepts Concordium proofs from. */
export type ConcordiumNetwork = 'testnet' | 'mainnet';

export type VerificationFailureCode =
  | 'CHALLENGE_UNKNOWN'
  | 'CHALLENGE_EXPIRED'
  | 'CHALLENGE_REUSED'
  | 'CHALLENGE_LABEL_MISMATCH'
  | 'PRESENTATION_MALFORMED'
  | 'PRESENTATION_CRYPTO_REJECTED'
  | 'PRESENTATION_CHALLENGE_MISMATCH'
  | 'PRESENTATION_STATEMENT_MISMATCH'
  | 'PRESENTATION_NETWORK_MISMATCH'
  | 'PROVER_NOT_FOUND'
  | 'PROVER_MULTI_CREDENTIAL'
  | 'PROVER_INITIAL_CREDENTIAL'
  | 'PROVER_CRED_MISMATCH'
  | 'IDP_NOT_ALLOWLISTED'
  | 'CREDENTIAL_EXPIRED'
  | 'CREDENTIAL_NOT_YET_VALID'
  | 'CIS8_NOT_FOUND'
  | 'CIS8_REVOKED'
  | 'CIS8_OWNER_MISMATCH'
  | 'CIS8_NAMESPACE_REJECTED'
  | 'CIS8_KEYTYPE_REJECTED'
  | 'CIS8_KEY_MALFORMED'
  | 'CIS8_PROOF_SCHEME_REJECTED'
  | 'VALEN_BINDING_INPUT_INVALID'
  | 'VALEN_ARC_OWNER_MISMATCH'
  | 'EVM_DERIVATION_MISMATCH'
  | 'COSIG_NONCE_UNKNOWN'
  | 'COSIG_NONCE_REUSED'
  | 'COSIG_EXPIRED'
  | 'COSIG_WALLET_MISMATCH'
  | 'COSIG_PAYLOAD_MISMATCH'
  | 'COSIG_BAD_SIGNATURE'
  | 'SERVICE_AGENT_SENDER_MALFORMED'
  | 'SERVICE_AGENT_TOKEN_ID_INVALID'
  | 'SERVICE_AGENT_NOT_FOUND'
  | 'SERVICE_AGENT_REVOKED'
  | 'SERVICE_AGENT_OWNER_MISMATCH'
  | 'NODE_ERROR';

export class ConcordiumError extends Error {
  readonly code: VerificationFailureCode;

  constructor(code: VerificationFailureCode, detail?: string) {
    super(detail ? `${code}: ${detail}` : code);
    this.name = 'ConcordiumError';
    this.code = code;
  }
}

/** Clock abstraction so expiry logic is deterministically testable. */
export type Clock = () => number;

/** Milliseconds since Unix epoch, as returned by `Date.now()`. */
export type UnixMs = number;
