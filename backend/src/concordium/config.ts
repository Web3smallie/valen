/**
 * Concordium security policy: pinned contracts, IDP allowlist, and lifetimes.
 *
 * Security-critical values live HERE in code, not in environment variables:
 * an operator typo must never silently widen trust. Only transport-level
 * settings (gRPC host/port) are overridable via environment.
 *
 * Values below target Concordium Testnet. Mainnet values require a
 * separate, explicitly reviewed configuration (instances, IDPs, genesis).
 */

import type { ConcordiumNetwork } from './types.js';

export interface ConcordiumPolicy {
  readonly network: ConcordiumNetwork;
  readonly genesisHashHex: string;
  readonly grpcHost: string;
  readonly grpcPort: number;
  readonly grpcSecure: boolean;
  /** Pinned CIS-8 External Key Registry instance. */
  readonly cis8ContractIndex: bigint;
  readonly cis8ContractSubindex: bigint;
  /** Pinned CIS-8004 Agent Registry instance. */
  readonly cis8004ContractIndex: bigint;
  readonly cis8004ContractSubindex: bigint;
  /** Concordium identity-provider indexes Valen accepts. */
  readonly idpAllowlist: readonly number[];
  /** EVM namespaces accepted for borrowing-wallet bindings. */
  readonly evmNamespacePattern: RegExp;
  /** secp256k1 key encodings accepted for borrowing-wallet bindings. */
  readonly secp256k1KeyTypes: readonly string[];
  /** CIS-8 proof schemes accepted for bindings. */
  readonly cis8ProofSchemes: readonly string[];
  /** Identity-challenge lifetime. Enforced at consume time. */
  readonly challengeTtlMs: number;
  /** Wallet co-signature nonce lifetime. Enforced at verify time. */
  readonly coSignatureTtlMs: number;
}

function grpcEnv(name: string, fallback: string): string {
  const v = process.env[name];
  return v !== undefined && v !== '' ? v : fallback;
}

export const CONCORDIUM_TESTNET_POLICY: ConcordiumPolicy = {
  network: 'testnet',
  // Verified live: matches `getConsensusStatus().genesisBlock` on Testnet.
  genesisHashHex:
    '4221332d34e1694168c2a0c0b3fd0f273809612cb13d000d5c2e00e85f50f796',
  grpcHost: grpcEnv('CONCORDIUM_GRPC_HOST', 'grpc.testnet.concordium.com'),
  grpcPort: Number.parseInt(grpcEnv('CONCORDIUM_GRPC_PORT', '20000'), 10),
  grpcSecure: true,
  // Verified live: `init_CIS-8` instance on Testnet (Step 2 spike).
  cis8ContractIndex: 12801n,
  cis8ContractSubindex: 0n,
  // Verified live: MCP `contract_info` + successful `agentOf` invoke.
  cis8004ContractIndex: 12802n,
  cis8004ContractSubindex: 0n,
  // Testnet IP only. Production MUST replace this with the reviewed IDP set.
  idpAllowlist: [0],
  // Any eip155 chain: the same secp256k1 key yields the same address on
  // every EVM chain, so the namespace is corroborating metadata, not a
  // security boundary. Derivation match is the enforced check.
  evmNamespacePattern: /^eip155:\d+$/,
  secp256k1KeyTypes: ['secp256k1-uncompressed', 'secp256k1-compressed'],
  // ethereum-personal-sign: CIS-8 spec proof scheme for EVM keys,
  // confirmed live on this contract by the F1 binding precedent.
  cis8ProofSchemes: ['ethereum-personal-sign'],
  challengeTtlMs: 10 * 60 * 1000,
  coSignatureTtlMs: 10 * 60 * 1000,
};
