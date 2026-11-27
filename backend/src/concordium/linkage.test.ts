import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { secp256k1 } from '@noble/curves/secp256k1';
import { privateKeyToAccount } from 'viem/accounts';
import { describe, expect, it } from 'vitest';
import { deriveEvmAddress } from './cis8.js';
import type { ExternalKeyId } from './cis8.js';
import { ChallengeService } from './challenge.js';
import { NonceService, buildCoSignatureMessage, nonceLabel } from './coSignature.js';
import { verifyBorrowerLinkage } from './index.js';
import type { AccountView, ConcordiumNode } from './node.js';
import { canonicalJson } from './policy.js';
import { ConcordiumError, type EvmAddress } from './types.js';

const fixtureDir = join(dirname(fileURLToPath(import.meta.url)), 'testdata');
const f1owner = JSON.parse(
  readFileSync(join(fixtureDir, 'accountCredential-f1owner.json'), 'utf8'),
) as {
  address: string;
  credential: {
    ipIdentity: number;
    credId: string;
    policy: { validTo: string; createdAt: string };
    commitments: Record<string, string>;
  };
  credentialType: string;
};
const displaced = JSON.parse(
  readFileSync(join(fixtureDir, 'ownerOfKey-displaced.json'), 'utf8'),
) as {
  query: { namespace: string; keyType: string; pubkey: string };
  returnValue: string;
};

const CHAIN_ID = 5042002;
const NOW = Date.UTC(2026, 10, 22);
const STATEMENTS = [{ type: 'AttributeInRange', attributeTag: 'dob', lower: '18000101', upper: '20081122' }];

function accountView(): AccountView {
  return {
    address: f1owner.address,
    nonce: '5',
    microCcd: '19961059672',
    credentials: [
      {
        index: 0,
        type: f1owner.credentialType,
        ipIdentity: f1owner.credential.ipIdentity,
        credIdHex: f1owner.credential.credId,
        validToYYYYMM: f1owner.credential.policy.validTo,
        createdAtYYYYMM: f1owner.credential.policy.createdAt,
        commitments: { ...f1owner.credential.commitments },
      },
    ],
  };
}

function strEnc(text: string): string {
  const bytes = Buffer.from(text, 'utf8');
  const length = Buffer.alloc(4);
  length.writeUInt32LE(bytes.length);
  return Buffer.concat([length, bytes]).toString('hex');
}

/** Well-formed Active registration response for an arbitrary (key, owner). */
function syntheticRegistration(ownerHex: string, namespace: string, keyType: string, publicKeyHex: string): string {
  const keyBytes = Buffer.from(publicKeyHex, 'hex');
  const keyLength = Buffer.alloc(4);
  keyLength.writeUInt32LE(keyBytes.length);
  const updated = Buffer.alloc(8);
  updated.writeBigUInt64LE(BigInt(Date.UTC(2026, 10, 1)));
  return (
    '01' +
    ownerHex.toLowerCase() +
    strEnc(namespace) +
    strEnc(keyType) +
    keyLength.toString('hex') +
    keyBytes.toString('hex') +
    strEnc('ethereum-personal-sign') +
    '00000000' +
    '00' +
    updated.toString('hex')
  );
}

function mockNode(overrides: Partial<Record<'account' | 'ownerOfKey', unknown>> = {}): ConcordiumNode {
  return {
    getAccount: async () => (overrides['account'] ?? accountView()) as AccountView,
    getAccountByCredId: async () => {
      throw new Error('unused');
    },
    invokeOwnerOfKey: async () => overrides['ownerOfKey'] as string,
    invokeAgentOf: async () => {
      throw new Error('unused');
    },
    getGlobalContext: async () => ({ stubGlobalContext: true }),
    getBestBlockHeight: async () => '51120000',
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

function asKeyId(query: { namespace: string; keyType: string; pubkey: string }): ExternalKeyId {
  return { namespace: query.namespace, keyType: query.keyType, publicKeyHex: query.pubkey };
}

describe('verifyBorrowerLinkage (orchestrator wiring)', () => {
  it('accepts a fully consistent linkage end to end', async () => {
    const privateKey = secp256k1.utils.randomPrivateKey();
    const publicKeyHex = Buffer.from(secp256k1.getPublicKey(privateKey, false)).toString('hex');
    const wallet = deriveEvmAddress(publicKeyHex);
    const signer = privateKeyToAccount(`0x${Buffer.from(privateKey).toString('hex')}` as `0x${string}`);
    expect(signer.address.toLowerCase()).toBe(wallet.toLowerCase());

    const ownerHex = '70ba750ec3ea77b6e7af7d11921bb724e49f4dd4f54029891ee419bc00b10a0e';
    const node = mockNode({
      ownerOfKey: syntheticRegistration(ownerHex, 'eip155:1', 'secp256k1-uncompressed', publicKeyHex),
    });
    const challenges = new ChallengeService(600_000, undefined, () => NOW);
    const nonces = new NonceService(600_000, () => NOW);
    const issued = challenges.issue(f1owner.address, canonicalJson(STATEMENTS));
    const co = nonces.issue(nonceLabel(wallet, 7n));
    const message = buildCoSignatureMessage({
      wallet,
      concordiumAccount: f1owner.address,
      agentId: 7n,
      nonceHex: co.nonceHex,
      expiryMs: co.expiresAtMs,
      chainId: CHAIN_ID,
    });
    const verdict = await verifyBorrowerLinkage(
      {
        node,
        challenges,
        nonces,
        now: () => NOW,
        cryptoVerify: () => ({
          challenge: issued.secretHex,
          credentialStatements: [
            { id: `did:ccd:testnet:cred:${f1owner.credential.credId}`, statement: STATEMENTS },
          ],
        }),
      },
      {
        presentation: { stubPresentation: true },
        challengeId: issued.id,
        challengeSecretHex: issued.secretHex,
        concordiumAccount: f1owner.address,
        externalKey: { namespace: 'eip155:1', keyType: 'secp256k1-uncompressed', publicKeyHex },
        borrowingWallet: wallet,
        agentId: 7n,
        arcChainId: CHAIN_ID,
        coSignature: {
          signature: await signer.signMessage({ message }),
          nonceHex: co.nonceHex,
          expiryMs: co.expiresAtMs,
          presentedMessage: message,
        },
      },
    );
    expect(verdict.concordiumAccount).toBe(f1owner.address);
    expect(verdict.borrowingWallet).toBe(wallet);
    expect(verdict.ipIdentity).toBe(0);
    expect(verdict.bindingProofScheme).toBe('ethereum-personal-sign');
  });

  it('rejects replayed challenges across linkage attempts', async () => {
    const node = mockNode({ ownerOfKey: '00' });
    const challenges = new ChallengeService(600_000, undefined, () => NOW);
    const nonces = new NonceService(600_000, () => NOW);
    const issued = challenges.issue(f1owner.address, canonicalJson(STATEMENTS));
    const base = {
      presentation: {},
      challengeId: issued.id,
      challengeSecretHex: issued.secretHex,
      concordiumAccount: f1owner.address,
      externalKey: { namespace: 'eip155:1', keyType: 'secp256k1-uncompressed', publicKeyHex: `04${'11'.repeat(64)}` },
      borrowingWallet: '0x0000000000000000000000000000000000000001' as EvmAddress,
      agentId: 1n,
      arcChainId: CHAIN_ID,
      coSignature: { signature: `0x${'11'.repeat(65)}`, nonceHex: 'ab'.repeat(32), expiryMs: NOW + 1000 },
    };
    const deps = {
      node,
      challenges,
      nonces,
      now: () => NOW,
      cryptoVerify: () => ({
        challenge: issued.secretHex,
        credentialStatements: [
          { id: `did:ccd:testnet:cred:${f1owner.credential.credId}`, statement: STATEMENTS },
        ],
      }),
    };
    // First attempt fails late (no binding), but the challenge is consumed.
    await expectCode(verifyBorrowerLinkage(deps, base), 'CIS8_NOT_FOUND');
    // Replay of the same challenge fails immediately at step 1.
    await expectCode(verifyBorrowerLinkage(deps, base), 'CHALLENGE_REUSED');
  });

  it('rejects the live displaced binding through the full path', async () => {
    const node = mockNode({ ownerOfKey: displaced.returnValue });
    const challenges = new ChallengeService(600_000, undefined, () => NOW);
    const nonces = new NonceService(600_000, () => NOW);
    const issued = challenges.issue(f1owner.address, canonicalJson(STATEMENTS));
    await expectCode(
      verifyBorrowerLinkage(
        {
          node,
          challenges,
          nonces,
          now: () => NOW,
          cryptoVerify: () => ({
            challenge: issued.secretHex,
            credentialStatements: [
              { id: `did:ccd:testnet:cred:${f1owner.credential.credId}`, statement: STATEMENTS },
            ],
          }),
        },
        {
          presentation: { stubPresentation: true },
          challengeId: issued.id,
          challengeSecretHex: issued.secretHex,
          concordiumAccount: f1owner.address,
          externalKey: asKeyId(displaced.query),
          borrowingWallet: '0xfa7840126d187f9f86ed64bfe82d1614f72bcf6e' as EvmAddress,
          agentId: 9n,
          arcChainId: CHAIN_ID,
          coSignature: { signature: `0x${'11'.repeat(65)}`, nonceHex: 'ab'.repeat(32), expiryMs: NOW + 1000 },
        },
      ),
      'CIS8_OWNER_MISMATCH',
    );
  });

  it('rejects wrong-IDP credentials before any proof verification', async () => {
    const view = accountView();
    const tampered: AccountView = {
      ...view,
      credentials: [{ ...view.credentials[0], ipIdentity: 3 }],
    };
    const node = mockNode({ ownerOfKey: '00' });
    node.getAccount = async () => tampered;
    const challenges = new ChallengeService(600_000, undefined, () => NOW);
    const nonces = new NonceService(600_000, () => NOW);
    const issued = challenges.issue(f1owner.address, canonicalJson(STATEMENTS));
    let cryptoCalled = false;
    await expectCode(
      verifyBorrowerLinkage(
        {
          node,
          challenges,
          nonces,
          now: () => NOW,
          cryptoVerify: () => {
            cryptoCalled = true;
            throw new Error('must not reach crypto');
          },
        },
        {
          presentation: {},
          challengeId: issued.id,
          challengeSecretHex: issued.secretHex,
          concordiumAccount: f1owner.address,
          externalKey: { namespace: 'eip155:1', keyType: 'secp256k1-uncompressed', publicKeyHex: `04${'11'.repeat(64)}` },
          borrowingWallet: '0x0000000000000000000000000000000000000001' as EvmAddress,
          agentId: 1n,
          arcChainId: CHAIN_ID,
          coSignature: { signature: `0x${'11'.repeat(65)}`, nonceHex: 'ab'.repeat(32), expiryMs: NOW + 1000 },
        },
      ),
      'IDP_NOT_ALLOWLISTED',
    );
    expect(cryptoCalled).toBe(false);
  });
});
