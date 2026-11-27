import { describe, expect, it } from 'vitest';
import { parseAccountDid, verifyPresentationAndMatch } from './presentation.js';
import { ConcordiumError } from './types.js';

const CHALLENGE = 'c72859a7db5da25fa12aa4cfbefada2f62d2d616b2326ece3aa85735cf3bf5c3';
const CRED_ID = 'b425f0b3b767291458f6e18909eaa45729fc57e85201c505cf82b23718f9c9630c3e1a58d79ecd761a616ec3c81949db';
const DID = `did:ccd:testnet:cred:${CRED_ID}`;
const STATEMENTS = [{ type: 'AttributeInRange', attributeTag: 'dob', lower: '18000101', upper: '20081122' }];

function stubProven(overrides: Record<string, unknown> = {}) {
  return () => ({
    challenge: CHALLENGE,
    credentialStatements: [{ id: DID, statement: STATEMENTS }],
    ...overrides,
  });
}

function expectCodeSync(fn: () => unknown, code: string): void {
  try {
    fn();
  } catch (error) {
    expect(error).toBeInstanceOf(ConcordiumError);
    expect((error as ConcordiumError).code).toBe(code);
    return;
  }
  throw new Error(`expected ConcordiumError(${code}), nothing thrown`);
}

describe('verifyPresentationAndMatch (real crypto fail-closed)', () => {
  // No cryptoVerify override: these execute the REAL SDK verification path
  // and must all fail closed. (Positive-path execution requires a genuine
  // wallet credential proof; see the CONCORDIUM_TEST_PROOF-gated test below.)
  const base = {
    globalContext: {},
    publicData: [{ type: 'account', commitments: {} }],
    expectedChallengeHex: CHALLENGE,
    expectedStatements: STATEMENTS,
    expectedNetwork: 'testnet' as const,
  };

  it('rejects null presentation without touching crypto', () => {
    expectCodeSync(
      () => verifyPresentationAndMatch({ ...base, presentation: null }),
      'PRESENTATION_MALFORMED',
    );
  });

  it('rejects garbage that reaches the real SDK verifier', () => {
    expectCodeSync(
      () => verifyPresentationAndMatch({ ...base, presentation: { bogus: true } }),
      'PRESENTATION_CRYPTO_REJECTED',
    );
  });

  it('rejects structurally-shaped but invalid proofs', () => {
    expectCodeSync(
      () =>
        verifyPresentationAndMatch({
          ...base,
          presentation: { presentationContext: '00', verifiableCredential: [] },
        }),
      'PRESENTATION_CRYPTO_REJECTED',
    );
  });
});

describe('verifyPresentationAndMatch (decision logic, stubbed crypto core)', () => {
  const base = {
    presentation: { stub: true },
    globalContext: {},
    publicData: [],
    expectedChallengeHex: CHALLENGE,
    expectedStatements: STATEMENTS,
    expectedNetwork: 'testnet' as const,
  };

  it('accepts an exactly-matching proven request', () => {
    const proven = verifyPresentationAndMatch({ ...base, cryptoVerify: stubProven() });
    expect(proven).toEqual({ proverCredIdHex: CRED_ID, network: 'testnet' });
  });

  it('rejects challenge mismatch (replay across sessions)', () => {
    expect(() =>
      verifyPresentationAndMatch({
        ...base,
        cryptoVerify: stubProven({ challenge: 'f'.repeat(64) }),
      }),
    ).toThrowError(expect.objectContaining({ code: 'PRESENTATION_CHALLENGE_MISMATCH' }));
  });

  it('rejects statement mismatch (weaker/different predicates)', () => {
    expect(() =>
      verifyPresentationAndMatch({
        ...base,
        cryptoVerify: stubProven({
          credentialStatements: [{ id: DID, statement: [{ type: 'AttributeInRange', attributeTag: 'dob', lower: '18000101', upper: '20081231' }] }],
        }),
      }),
    ).toThrowError(expect.objectContaining({ code: 'PRESENTATION_STATEMENT_MISMATCH' }));
  });

  it('rejects multi-credential and Web3ID-typed statements', () => {
    expect(() =>
      verifyPresentationAndMatch({
        ...base,
        cryptoVerify: stubProven({
          credentialStatements: [
            { id: DID, statement: STATEMENTS },
            { id: DID, statement: STATEMENTS },
          ],
        }),
      }),
    ).toThrowError(expect.objectContaining({ code: 'PRESENTATION_STATEMENT_MISMATCH' }));
    expect(() =>
      verifyPresentationAndMatch({
        ...base,
        cryptoVerify: stubProven({
          credentialStatements: [{ id: DID, statement: STATEMENTS, type: ['VerifiableCredential'] }],
        }),
      }),
    ).toThrowError(expect.objectContaining({ code: 'PRESENTATION_MALFORMED' }));
  });

  it('rejects wrong-network DIDs and malformed DIDs', () => {
    const mainnetDid = DID.replace('testnet', 'mainnet');
    expect(() =>
      verifyPresentationAndMatch({
        ...base,
        cryptoVerify: stubProven({ credentialStatements: [{ id: mainnetDid, statement: STATEMENTS }] }),
      }),
    ).toThrowError(expect.objectContaining({ code: 'PRESENTATION_NETWORK_MISMATCH' }));
    expect(() =>
      verifyPresentationAndMatch({
        ...base,
        cryptoVerify: stubProven({ credentialStatements: [{ id: 'did:ccd:testnet:cred:short', statement: STATEMENTS }] }),
      }),
    ).toThrowError(expect.objectContaining({ code: 'PRESENTATION_MALFORMED' }));
  });

  it('wraps crypto-core throws as rejection, never success', () => {
    expect(() =>
      verifyPresentationAndMatch({
        ...base,
        cryptoVerify: () => {
          throw new Error('wasm boom');
        },
      }),
    ).toThrowError(expect.objectContaining({ code: 'PRESENTATION_CRYPTO_REJECTED' }));
  });

  it('parses account DIDs strictly', () => {
    expect(parseAccountDid(DID)).toEqual({ network: 'testnet', credIdHex: CRED_ID });
    expect(() => parseAccountDid('did:ccd:testnet:cred:zz')).toThrowError(
      expect.objectContaining({ code: 'PRESENTATION_MALFORMED' }),
    );
  });
});

describe('verifyPresentationAndMatch (live proof, gated)', () => {
  const raw = process.env['CONCORDIUM_TEST_PROOF'];
  const run = raw !== undefined && raw !== '' ? it : it.skip;
  run('accepts a genuine wallet presentation end to end', () => {
    if (!raw) {
      throw new Error('unreachable');
    }
    const fixture = JSON.parse(raw) as {
      presentation: unknown;
      globalContext: unknown;
      publicData: unknown;
      expectedChallengeHex: string;
      expectedStatements: unknown;
      expectedNetwork: 'testnet';
      expectedCredIdHex: string;
    };
    // No cryptoVerify override: real SDK verification of a genuine proof.
    // Supply via CONCORDIUM_TEST_PROOF=<json> (acceptance runs only: the
    // proof is single-credential evidence, never committed to the repo).
    const proven = verifyPresentationAndMatch({
      presentation: fixture.presentation,
      globalContext: fixture.globalContext,
      publicData: fixture.publicData,
      expectedChallengeHex: fixture.expectedChallengeHex,
      expectedStatements: fixture.expectedStatements,
      expectedNetwork: fixture.expectedNetwork,
    });
    expect(proven.proverCredIdHex).toBe(fixture.expectedCredIdHex.toLowerCase());
  });
});
