import { describe, expect, it } from 'vitest';
import {
  accountHexToBase58,
  BadgeError,
  decodeBadgeShortForm,
  encodeBadgeShortForm,
  splitBadgeCaip19,
} from '../src/concordium/badge.js';

describe('badge decoding', () => {
  it('decodes the live Valen badge to (12802, 0, 1507)', () => {
    const decoded = decodeBadgeShortForm('JyP9YAskQ5pWBESxthBcf');
    expect(decoded.contractIndex).toBe(12802n);
    expect(decoded.contractSubindex).toBe(0n);
    expect(decoded.tokenId).toBe(1507n);
  });

  it('round-trips encode/decode', () => {
    expect(encodeBadgeShortForm(12802n, 0n, 1507n)).toBe('JyP9YAskQ5pWBESxthBcf');
    const other = encodeBadgeShortForm(99999n, 3n, 42n);
    const back = decodeBadgeShortForm(other);
    expect(back.contractIndex).toBe(99999n);
    expect(back.contractSubindex).toBe(3n);
    expect(back.tokenId).toBe(42n);
  });

  it('rejects a checksum-tampered badge', () => {
    const good = 'JyP9YAskQ5pWBESxthBcf';
    const last = good[good.length - 1] === 'f' ? 'g' : 'f';
    expect(() => decodeBadgeShortForm(good.slice(0, -1) + last)).toThrowError(BadgeError);
  });

  it('rejects malformed input', () => {
    for (const bad of ['', '0OIl+/=', 'JyP9', 'x'.repeat(60)]) {
      expect(() => decodeBadgeShortForm(bad), bad).toThrowError(BadgeError);
    }
  });

  it('rejects out-of-range components when encoding', () => {
    expect(() => encodeBadgeShortForm(-1n, 0n, 1n)).toThrowError(BadgeError);
    expect(() => encodeBadgeShortForm(1n, 0n, 1n << 64n)).toThrowError(BadgeError);
  });
});

describe('CAIP-19 splitting', () => {
  it('splits the pinned badge reference', () => {
    const parts = splitBadgeCaip19('ccd:4221332d34e1694168c2a0c0b3fd0f27/cis-2:JyP9YAskQ5pWBESxthBcf');
    expect(parts.genesisPrefix).toBe('4221332d34e1694168c2a0c0b3fd0f27');
    expect(parts.shortForm).toBe('JyP9YAskQ5pWBESxthBcf');
  });

  it('rejects malformed references', () => {
    for (const bad of [
      'ccd:4221332d34e1694168c2a0c0b3fd0f27/cis-2:',
      'ccd:ZZZ/cis-2:JyP9YAskQ5pWBESxthBcf',
      'ccd:4221332d34e1694168c2a0c0b3fd0f27/JyP9YAskQ5pWBESxthBcf',
      'JyP9YAskQ5pWBESxthBcf',
      '',
    ]) {
      expect(() => splitBadgeCaip19(bad), bad).toThrowError(BadgeError);
    }
  });
});

describe('account base58 encoding', () => {
  it('encodes a known account (SDK-verified vector)', () => {
    expect(accountHexToBase58('90c861057951b4439e0843295393c870cb59a521d2325b149578b62a9d7bd7fc')).toBe(
      '43WTW9mXTvFheLNjmsso5hDEJyYTdn8cssFXYDUHruUjqSSpMu',
    );
  });

  it('encodes the Valen service account', () => {
    expect(accountHexToBase58('b376ffb2f41efa8a524ab6f6cf7b2f481c271d968ec21c4dd0a063647c516fea')).toBe(
      '4JnNAPh8mrS2BF2wcaB9Cdp83JscgvXuboxoUnnxesv39kcrCR',
    );
  });

  it('rejects non-32-byte input', () => {
    expect(() => accountHexToBase58('abcd')).toThrowError(BadgeError);
    expect(() => accountHexToBase58('zz'.repeat(32))).toThrowError(BadgeError);
  });
});
