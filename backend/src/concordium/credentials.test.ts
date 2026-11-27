import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { checkCredentialStanding, checkProverCredential, resolveProver } from './credentials.js';
import type { AccountView, ConcordiumNode } from './node.js';
import { ConcordiumError } from './types.js';

const fixtureDir = join(dirname(fileURLToPath(import.meta.url)), 'testdata');
const fixture = JSON.parse(readFileSync(join(fixtureDir, 'accountCredential.json'), 'utf8')) as {
  address: string;
  credential: {
    ipIdentity: number;
    credId: string;
    policy: { validTo: string; createdAt: string };
    commitments: Record<string, string>;
  };
};

// Live-recorded.testnet credential: our controlled account 49BGJ… (IP 0,
// valid 202611–202711). `type` was observed as "normal" via the SDK.
const LIVE_NOW = Date.UTC(2026, 10, 22);
const LIVE_CRED = fixture.credential as {
  ipIdentity: number;
  credId: string;
  policy: { validTo: string; createdAt: string };
  commitments: Record<string, string>;
};

function accountView(overrides: Partial<AccountView['credentials'][number]> = {}, address = fixture.address): AccountView {
  // Mirror node.ts normalization: AccountView.commitments holds ONLY the
  // per-attribute map (the fixture stores the raw credential object).
  const attributes = (LIVE_CRED.commitments as Record<string, unknown>)['cmmAttributes'] as Record<string, string>;
  return {
    address,
    nonce: '2',
    microCcd: '19983049628',
    credentials: [
      {
        index: 0,
        type: 'normal',
        ipIdentity: LIVE_CRED.ipIdentity,
        credIdHex: LIVE_CRED.credId,
        validToYYYYMM: LIVE_CRED.policy.validTo,
        createdAtYYYYMM: LIVE_CRED.policy.createdAt,
        commitments: { ...attributes },
        ...overrides,
      },
    ],
  };
}

function expectCode(fn: () => unknown, code: string): void {
  try {
    fn();
  } catch (error) {
    expect(error).toBeInstanceOf(ConcordiumError);
    expect((error as ConcordiumError).code).toBe(code);
    return;
  }
  throw new Error(`expected ConcordiumError(${code}), nothing thrown`);
}

async function expectCodeAsync(fn: () => Promise<unknown>, code: string): Promise<void> {
  try {
    await fn();
  } catch (error) {
    expect(error).toBeInstanceOf(ConcordiumError);
    expect((error as ConcordiumError).code).toBe(code);
    return;
  }
  throw new Error(`expected ConcordiumError(${code}), nothing thrown`);
}

describe('checkProverCredential (live-recorded credential)', () => {
  it('accepts the genuine standing credential', () => {
    const checked = checkProverCredential(accountView(), LIVE_CRED.credId, [0], LIVE_NOW);
    expect(checked.ipIdentity).toBe(0);
    expect(checked.credIdHex).toBe(LIVE_CRED.credId.toLowerCase());
    const publicInputs = checked.publicData as { type: string; commitments: Record<string, string> }[];
    expect(publicInputs[0].type).toBe('account');
    // Per-attribute commitments keyed by attribute name (feeds verifyPresentation).
    expect(Object.keys(publicInputs[0].commitments)).toEqual(
      expect.arrayContaining(['dob', 'firstName', 'countryOfResidence']),
    );
  });

  it('rejects wrong-IDP credentials independently of wallet filtering', () => {
    expectCode(
      () => checkCredentialStanding(accountView({ ipIdentity: 3 }), [0], LIVE_NOW),
      'IDP_NOT_ALLOWLISTED',
    );
  });

  it('rejects expired, not-yet-valid, and malformed windows', () => {
    expectCode(
      () => checkCredentialStanding(accountView({ validToYYYYMM: '202001' }), [0], LIVE_NOW),
      'CREDENTIAL_EXPIRED',
    );
    expectCode(
      () => checkCredentialStanding(accountView({ createdAtYYYYMM: '203001' }), [0], LIVE_NOW),
      'CREDENTIAL_NOT_YET_VALID',
    );
    expectCode(
      () => checkCredentialStanding(accountView({ validToYYYYMM: 'soon' }), [0], LIVE_NOW),
      'CREDENTIAL_EXPIRED',
    );
  });

  it('rejects multi-credential accounts and non-normal types', () => {
    const multi = accountView();
    const doubled: AccountView = { ...multi, credentials: [multi.credentials[0], multi.credentials[0]] };
    expectCode(() => checkCredentialStanding(doubled, [0], LIVE_NOW), 'PROVER_MULTI_CREDENTIAL');
    expectCode(
      () => checkCredentialStanding(accountView({ type: 'initial' }), [0], LIVE_NOW),
      'PROVER_INITIAL_CREDENTIAL',
    );
  });

  it('rejects prover credential mismatch', () => {
    expectCode(
      () => checkProverCredential(accountView(), 'ab'.repeat(48), [0], LIVE_NOW),
      'PROVER_CRED_MISMATCH',
    );
  });
});

describe('resolveProver', () => {
  const nodeFor = (view: AccountView): ConcordiumNode =>
    ({
      getAccount: async () => view,
      getAccountByCredId: async () => {
        throw new Error('unused');
      },
      invokeOwnerOfKey: async () => {
        throw new Error('unused');
      },
      getGlobalContext: async () => ({}),
      getBestBlockHeight: async () => '1',
    }) as unknown as ConcordiumNode;

  it('resolves the expected account and checks standing', async () => {
    const checked = await resolveProver(
      nodeFor(accountView()),
      fixture.address,
      LIVE_CRED.credId,
      [0],
      LIVE_NOW,
    );
    expect(checked.accountAddress).toBe(fixture.address);
  });

  it('fails closed on node errors and address mismatch', async () => {
    const failing: ConcordiumNode = nodeFor(accountView());
    failing.getAccount = async () => {
      throw new Error('boom');
    };
    await expectCodeAsync(
      () => resolveProver(failing, fixture.address, LIVE_CRED.credId, [0], LIVE_NOW),
      'PROVER_NOT_FOUND',
    );
    await expectCodeAsync(
      () =>
        resolveProver(
          nodeFor(accountView({}, '3oPfuWN3BfDHa2GFstC9SkrSFkTWFKdrg2c9cLdpGjphewLJeL')),
          fixture.address,
          LIVE_CRED.credId,
          [0],
          LIVE_NOW,
        ),
      'PROVER_CRED_MISMATCH',
    );
  });
});
