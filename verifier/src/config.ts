/**
 * Pinned inputs for the Valen registration verifier.
 *
 * These constants are the trust anchors: everything the verifier checks is
 * compared against these values, never against Valen's backend and never
 * against Concordium's hosted badge resolver. Changing any pin changes what
 * "verified" means, so each value cites its provenance.
 */
export interface PinnedInputs {
  /** Concordium testnet genesis hash (chain anchor; first 32 hex chars form the CAIP-2 namespace suffix). */
  readonly concordiumGenesisHashHex: string;
  /** CIS-8004 Agent Registry contract this badge must belong to. */
  readonly cis8004Contract: { readonly index: bigint; readonly subindex: bigint };
  /** CIS-8 External Key Registry contract the binding must live on. */
  readonly cis8Contract: { readonly index: bigint; readonly subindex: bigint };
  /** Badge under verification, CAIP-19 form. */
  readonly badgeCaip19: string;
  /** Expected agent token id (must match the badge decode AND the chain record). */
  readonly expectedTokenId: bigint;
  /** Expected Concordium owner account (base58). */
  readonly expectedOwnerAccount: string;
  /** Expected Arc chain id. */
  readonly expectedArcChainId: number;
  /** Expected Arc owner address (EIP-55). */
  readonly expectedArcOwner: string;
}

export const PINNED: PinnedInputs = {
  // Observed via MCP contract_info + chain parameters; stable chain constant.
  concordiumGenesisHashHex:
    '4221332d34e1694168c2a0c0b3fd0f273809612cb13d000d5c2e00e85f50f796',
  // Observed via MCP contract_info (testnet) + getInstanceInfo.
  cis8004Contract: { index: 12802n, subindex: 0n },
  cis8Contract: { index: 12801n, subindex: 0n },
  // Issued at registration (token 1507); short form independently decoded.
  badgeCaip19: 'ccd:4221332d34e1694168c2a0c0b3fd0f27/cis-2:JyP9YAskQ5pWBESxthBcf',
  expectedTokenId: 1507n,
  // Designated Valen service account.
  expectedOwnerAccount: '4JnNAPh8mrS2BF2wcaB9Cdp83JscgvXuboxoUnnxesv39kcrCR',
  // Arc Testnet, confirmed live via eth_chainId.
  expectedArcChainId: 5042002,
  // Owner of all 11 Valen contracts, read live via owner().
  expectedArcOwner: '0xB0E8Ba6aFe21371AD4001e611224FC200FD10144',
};

/** Full badge short form for convenience (suffix of badgeCaip19 after `cis-2:`). */
export const BADGE_SHORT_FORM = 'JyP9YAskQ5pWBESxthBcf';

/**
 * Sanity expectations only. The verifier REPORTS mismatches against these;
 * it never treats them as ground truth. Ground truth always comes from a
 * live chain read performed during the run.
 */
export const SANITY = {
  /** On-chain metadata_hash is expected to start with this prefix. */
  metadataHashPrefix: 'e1a8b6',
  /** Served card body is expected to be exactly this long. */
  cardByteLength: 9041,
} as const;
