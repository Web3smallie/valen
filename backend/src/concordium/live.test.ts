import { describe, expect, it } from 'vitest';
import { CONCORDIUM_TESTNET_POLICY } from './config.js';
import { deriveEvmAddress, encodeExternalKeyId, parseOwnerOfKeyResponse } from './cis8.js';
import { GrpcConcordiumNode } from './node.js';

// Live testnet reads through the module's own node client. Runs only with
// CONCORDIUM_LIVE=1 (proves the transport + query + parse path against the
// real chain); skipped in ordinary CI runs for determinism.
const live = process.env['CONCORDIUM_LIVE'] === '1' ? it : it.skip;

describe('live Concordium Testnet reads (gated)', () => {
  live('reads account standing and CIS-8 bindings end to end', async () => {
    const node = new GrpcConcordiumNode(
      CONCORDIUM_TESTNET_POLICY.grpcHost,
      CONCORDIUM_TESTNET_POLICY.grpcPort,
      CONCORDIUM_TESTNET_POLICY.grpcSecure,
    );
    const height = await node.getBestBlockHeight();
    expect(Number(height)).toBeGreaterThan(50_000_000);

    const account = await node.getAccount('49BGJbazHuYzPFMRrvMJzapKdCdz1TCawUxGnABAJfMbH2jRps');
    expect(account.address).toBe('49BGJbazHuYzPFMRrvMJzapKdCdz1TCawUxGnABAJfMbH2jRps');
    expect(account.credentials).toHaveLength(1);
    expect(account.credentials[0].type).toBe('normal');
    expect(account.credentials[0].ipIdentity).toBe(0);

    const paramHex = encodeExternalKeyId({
      namespace: 'eip155:1',
      keyType: 'secp256k1-uncompressed',
      publicKeyHex:
        '040238d232c7b05753d8a5526b31ef6df0ca20eeeb5f47cd7f9a76aca901056ca7f58e41fcb6a671ebc072c80f737a07670c31f5ab8b36b60e00195ae1fdced622',
    });
    const raw = await node.invokeOwnerOfKey(
      CONCORDIUM_TESTNET_POLICY.cis8ContractIndex,
      CONCORDIUM_TESTNET_POLICY.cis8ContractSubindex,
      paramHex,
    );
    const parsed = parseOwnerOfKeyResponse(raw);
    expect(parsed.found).toBe(true);
    if (!parsed.found) {
      throw new Error('unreachable');
    }
    expect(parsed.ownerHex).toBe('70ba750ec3ea77b6e7af7d11921bb724e49f4dd4f54029891ee419bc00b10a0e');
    expect(parsed.status).toBe('Active');
    expect(deriveEvmAddress(parsed.publicKeyHex)).toBe('0x88dc41fe71c180ac0628ebb8c126db866b58fb3d');

    const global = await node.getGlobalContext();
    expect(JSON.stringify(global).toLowerCase()).toContain('generator');
  }, 120_000);
});
