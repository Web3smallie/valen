import { randomBytes } from 'node:crypto';
import { privateKeyToAccount } from 'viem/accounts';
import { describe, expect, it } from 'vitest';
import {
  NonceService,
  buildCoSignatureMessage,
  nonceLabel,
  verifyCoSignature,
} from './coSignature.js';
import { ConcordiumError, type EvmAddress } from './types.js';

const CHAIN_ID = 5042002; // Arc Testnet, from deployments/arc-testnet.json.
const ACCOUNT = '49BGJbazHuYzPFMRrvMJzapKdCdz1TCawUxGnABAJfMbH2jRps';

function testKey(): { address: EvmAddress; sign: (message: string) => Promise<string> } {
  const account = privateKeyToAccount(`0x${randomBytes(32).toString('hex')}`);
  return {
    address: account.address.toLowerCase() as EvmAddress,
    sign: async (message: string) => account.signMessage({ message }),
  };
}

async function expectCode(promise: Promise<unknown>, code: string): Promise<void> {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(ConcordiumError);
    expect((error as ConcordiumError).code).toBe(code);
    return;
  }
  throw new Error(`expected ConcordiumError(${code}), nothing thrown`);
}

describe('co-signature (real secp256k1 signatures)', () => {
  it('accepts a fresh signature over the canonical message', async () => {
    const wallet = testKey();
    const nonces = new NonceService(600_000);
    const { nonceHex, expiresAtMs } = nonces.issue(nonceLabel(wallet.address, 7n));
    const fields = {
      wallet: wallet.address,
      concordiumAccount: ACCOUNT,
      agentId: 7n,
      nonceHex,
      expiryMs: expiresAtMs,
      chainId: CHAIN_ID,
    };
    const message = buildCoSignatureMessage(fields);
    expect(message).toContain('Valen-Concordium-Binding/v1');
    const signature = await wallet.sign(message);
    const recovered = await verifyCoSignature(nonces, { ...fields, signature, presentedMessage: message }, Date.now());
    expect(recovered).toBe(wallet.address);
  });

  it('rejects signatures from a substituted wallet', async () => {
    const wallet = testKey();
    const attacker = testKey();
    const nonces = new NonceService(600_000);
    const { nonceHex, expiresAtMs } = nonces.issue(nonceLabel(wallet.address, 7n));
    const fields = {
      wallet: wallet.address,
      concordiumAccount: ACCOUNT,
      agentId: 7n,
      nonceHex,
      expiryMs: expiresAtMs,
      chainId: CHAIN_ID,
    };
    const message = buildCoSignatureMessage(fields);
    const attackerSig = await attacker.sign(message);
    await expectCode(
      verifyCoSignature(nonces, { ...fields, signature: attackerSig, presentedMessage: message }, Date.now()),
      'COSIG_WALLET_MISMATCH',
    );
  });

  it('rejects altered payloads before recovery', async () => {
    const wallet = testKey();
    const nonces = new NonceService(600_000);
    const { nonceHex, expiresAtMs } = nonces.issue(nonceLabel(wallet.address, 7n));
    const fields = {
      wallet: wallet.address,
      concordiumAccount: ACCOUNT,
      agentId: 7n,
      nonceHex,
      expiryMs: expiresAtMs,
      chainId: CHAIN_ID,
    };
    const signature = await wallet.sign(buildCoSignatureMessage(fields));
    await expectCode(
      verifyCoSignature(
        nonces,
        { ...fields, agentId: 8n, signature, presentedMessage: buildCoSignatureMessage(fields) },
        Date.now(),
      ),
      'COSIG_PAYLOAD_MISMATCH',
    );
  });

  it('rejects expired, reused, and unknown nonces', async () => {
    let now = 1_700_000_000_000;
    const nonces = new NonceService(60_000, () => now);
    const wallet = testKey();
    const first = nonces.issue(nonceLabel(wallet.address, 3n));
    const fields = {
      wallet: wallet.address,
      concordiumAccount: ACCOUNT,
      agentId: 3n,
      nonceHex: first.nonceHex,
      expiryMs: first.expiresAtMs,
      chainId: CHAIN_ID,
    };
    const signature = await wallet.sign(buildCoSignatureMessage(fields));
    await verifyCoSignature(
      nonces,
      { ...fields, signature, presentedMessage: buildCoSignatureMessage(fields) },
      now,
    );
    await expectCode(
      verifyCoSignature(
        nonces,
        { ...fields, signature, presentedMessage: buildCoSignatureMessage(fields) },
        now,
      ),
      'COSIG_NONCE_REUSED',
    );
    const second = nonces.issue(nonceLabel(wallet.address, 3n));
    now += 60_001;
    const expiredFields = { ...fields, nonceHex: second.nonceHex, expiryMs: second.expiresAtMs };
    const expiredSig = await wallet.sign(buildCoSignatureMessage(expiredFields));
    await expectCode(
      verifyCoSignature(
        nonces,
        { ...expiredFields, signature: expiredSig, presentedMessage: buildCoSignatureMessage(expiredFields) },
        now,
      ),
      'COSIG_EXPIRED',
    );
    const unknownFields = { ...fields, nonceHex: 'ab'.repeat(32), expiryMs: now + 60_000 };
    const unknownMessage = buildCoSignatureMessage(unknownFields);
    const unknownSig = await wallet.sign(unknownMessage);
    await expectCode(
      verifyCoSignature(
        nonces,
        { ...unknownFields, signature: unknownSig, presentedMessage: unknownMessage },
        now,
      ),
      'COSIG_NONCE_UNKNOWN',
    );
  });

  it('rejects malformed and unrecoverable signatures', async () => {
    const wallet = testKey();
    const nonces = new NonceService(600_000);
    const { nonceHex, expiresAtMs } = nonces.issue(nonceLabel(wallet.address, 1n));
    const fields = {
      wallet: wallet.address,
      concordiumAccount: ACCOUNT,
      agentId: 1n,
      nonceHex,
      expiryMs: expiresAtMs,
      chainId: CHAIN_ID,
    };
    const message = buildCoSignatureMessage(fields);
    await expectCode(
      verifyCoSignature(nonces, { ...fields, signature: '0x1234', presentedMessage: message }, Date.now()),
      'COSIG_BAD_SIGNATURE',
    );
    await expectCode(
      verifyCoSignature(
        nonces,
        { ...fields, signature: `0x${'11'.repeat(65)}`, presentedMessage: message },
        Date.now(),
      ),
      'COSIG_BAD_SIGNATURE',
    );
  });
});
