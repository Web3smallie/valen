/**
 * Valen Concordium borrower-linkage verification (Step 1: backend checks).
 *
 * Answers, for one loan decision: does a currently-valid Concordium
 * identity stand behind this exact Arc borrowing wallet, right now?
 *
 * Pipeline (every step fail-closed; any throw rejects the loan):
 *  1. Consume the identity challenge (single-use, expiry, label-bound to
 *     the expected Concordium account) and recover the issued statement
 *     snapshot.
 *  2. Resolve the expected account live; enforce single `normal`
 *     credential, IDP allowlist, and validity window.
 *  3. Cryptographically verify the presentation against live chain
 *     commitments; match challenge, statements, and network; extract the
 *     prover credential and require it to equal the resolved account's.
 *  4. Verify the CIS-8 binding for the borrowing key: present, Active,
 *     owned by the same account, namespace/key-type allowed, and
 *     independently re-derived to the exact borrowing wallet.
 *  5. Verify the wallet's fresh co-signature over the canonical binding
 *     message (proves the CURRENT key holder accepts THIS relationship).
 *
 * This module issues NO attestations and holds NO signing keys — it
 * produces a verdict object. Paper issuance is a later, separately
 * approved step that consumes verdicts.
 */

import { AccountAddress } from '@concordium/web-sdk';
import { ChallengeService } from './challenge.js';
import { verifyBinding, type ExternalKeyId } from './cis8.js';
import { CONCORDIUM_TESTNET_POLICY, type ConcordiumPolicy } from './config.js';
import { NonceService, verifyCoSignature, type CoSignatureInput } from './coSignature.js';
import { checkCredentialStanding } from './credentials.js';
import type { AccountView, ConcordiumNode } from './node.js';
import { verifyPresentationAndMatch, type CryptoVerifyFn } from './presentation.js';
import {
  ConcordiumError,
  type Clock,
  type ConcordiumAccount,
  type EvmAddress,
  type UnixMs,
} from './types.js';

export * from './types.js';
export * from './challenge.js';
export * from './cis8.js';
export * from './coSignature.js';
export * from './credentials.js';
export * from './node.js';
export * from './policy.js';
export * from './presentation.js';
export * from './serviceAgent.js';
export * from './valenBinding.js';
export { CONCORDIUM_TESTNET_POLICY, type ConcordiumPolicy } from './config.js';

export interface LinkageDependencies {
  readonly node: ConcordiumNode;
  readonly challenges: ChallengeService;
  readonly nonces: NonceService;
  readonly policy?: ConcordiumPolicy;
  readonly now?: Clock;
  /** Defaults to the real SDK cryptographic verification. */
  readonly cryptoVerify?: CryptoVerifyFn;
}

export interface LinkageInput {
  /** Identity presentation produced by the operator's wallet. */
  readonly presentation: unknown;
  readonly challengeId: string;
  readonly challengeSecretHex: string;
  /** Expected Concordium account (challenge label + resolution target). */
  readonly concordiumAccount: ConcordiumAccount;
  /** Borrowing key as named by the operator (normalized + re-derived). */
  readonly externalKey: ExternalKeyId;
  /** The Arc wallet requesting the loan. */
  readonly borrowingWallet: EvmAddress;
  readonly agentId: bigint;
  readonly arcChainId: number;
  readonly coSignature: {
    readonly signature: string;
    readonly nonceHex: string;
    readonly expiryMs: number;
    readonly presentedMessage?: string;
  };
}

export interface LinkageEvidence {
  readonly concordiumAccount: ConcordiumAccount;
  readonly ownerHex: string;
  readonly credIdHex: string;
  readonly ipIdentity: number;
  readonly borrowingWallet: EvmAddress;
  readonly bindingProofScheme: string;
  readonly bindingLastUpdatedMs: UnixMs;
  readonly verifiedAtMs: UnixMs;
}

export function concordiumAccountToHex(account: ConcordiumAccount): string {
  try {
    return Buffer.from(AccountAddress.fromBase58(account).decodedAddress).toString('hex');
  } catch {
    throw new ConcordiumError('PROVER_NOT_FOUND', 'concordium account malformed');
  }
}

export async function verifyBorrowerLinkage(
  deps: LinkageDependencies,
  input: LinkageInput,
): Promise<LinkageEvidence> {
  const policy = deps.policy ?? CONCORDIUM_TESTNET_POLICY;
  const nowMs = (deps.now ?? Date.now)();

  // 1. Challenge: single-use, expiry, label-bound to the expected account.
  const consumed = deps.challenges.consume(
    input.challengeId,
    input.challengeSecretHex,
    input.concordiumAccount,
  );
  let issuedStatements: unknown;
  try {
    issuedStatements = JSON.parse(consumed.contextJson) as unknown;
  } catch {
    throw new ConcordiumError('PRESENTATION_STATEMENT_MISMATCH', 'issued statement snapshot corrupt');
  }

  // 2. Resolve the expected account live; enforce standing (except prover
  // match, which needs the cryptographically proven credential id).
  let account: AccountView;
  try {
    account = await deps.node.getAccount(input.concordiumAccount);
  } catch (error) {
    if (error instanceof ConcordiumError) {
      throw error;
    }
    throw new ConcordiumError('PROVER_NOT_FOUND');
  }
  const standing = checkCredentialStanding(account, policy.idpAllowlist, nowMs);

  // 3. Cryptographic presentation verification against live commitments.
  const globalContext = await deps.node.getGlobalContext();
  const proven = verifyPresentationAndMatch({
    presentation: input.presentation,
    globalContext,
    publicData: [{ type: 'account', commitments: standing.commitments }],
    expectedChallengeHex: input.challengeSecretHex,
    expectedStatements: issuedStatements,
    expectedNetwork: policy.network,
    cryptoVerify: deps.cryptoVerify,
  });

  // 4. The proven credential must be the resolved account's credential.
  if (proven.proverCredIdHex.toLowerCase() !== standing.credIdHex.toLowerCase()) {
    throw new ConcordiumError('PROVER_CRED_MISMATCH');
  }

  // 5. CIS-8 binding: present, Active, owned by this account, derives here.
  const ownerHex = concordiumAccountToHex(input.concordiumAccount);
  const binding = await verifyBinding(
    deps.node,
    policy.cis8ContractIndex,
    policy.cis8ContractSubindex,
    input.externalKey,
    {
      namespacePattern: policy.evmNamespacePattern,
      allowedKeyTypes: policy.secp256k1KeyTypes,
      allowedProofSchemes: policy.cis8ProofSchemes,
      expectedOwnerHex: ownerHex,
      expectedWallet: input.borrowingWallet,
    },
  );

  // 6. Fresh wallet co-signature over the canonical binding message.
  const coInput: CoSignatureInput = {
    wallet: input.borrowingWallet,
    concordiumAccount: input.concordiumAccount,
    agentId: input.agentId,
    nonceHex: input.coSignature.nonceHex,
    expiryMs: input.coSignature.expiryMs,
    chainId: input.arcChainId,
    signature: input.coSignature.signature,
    presentedMessage: input.coSignature.presentedMessage,
  };
  await verifyCoSignature(deps.nonces, coInput, nowMs);

  return {
    concordiumAccount: input.concordiumAccount,
    ownerHex,
    credIdHex: standing.credIdHex,
    ipIdentity: standing.ipIdentity,
    borrowingWallet: binding.address,
    bindingProofScheme: binding.proofScheme,
    bindingLastUpdatedMs: binding.lastUpdatedMs,
    verifiedAtMs: nowMs,
  };
}


