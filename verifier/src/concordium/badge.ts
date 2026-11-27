import { createHash } from 'node:crypto';

/**
 * Badge (CIS-2 token address) parsing, implemented independently from the
 * public encoding: Base58Check (version byte 0x02, 4-byte double-SHA256
 * checksum, Bitcoin alphabet) over ULEB128(contract index) +
 * ULEB128(contract subindex) + token-id bytes. For CIS-8004 agent tokens
 * the id is a fixed 8-byte little-endian u64 with NO length prefix
 * (proven: this construction reproduces the live badge byte-for-byte).
 */

const BITCOIN_ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

export interface DecodedBadge {
  readonly shortForm: string;
  readonly contractIndex: bigint;
  readonly contractSubindex: bigint;
  readonly tokenId: bigint;
}

export class BadgeError extends Error {}

function decodeBase58(value: string): Buffer {
  if (value.length === 0) {
    throw new BadgeError('empty badge string');
  }
  let n = 0n;
  for (const ch of value) {
    const digit = BITCOIN_ALPHABET.indexOf(ch);
    if (digit < 0) {
      throw new BadgeError(`invalid base58 character: ${ch}`);
    }
    n = n * 58n + BigInt(digit);
  }
  let hex = n.toString(16);
  if (hex.length % 2 === 1) {
    hex = `0${hex}`;
  }
  const body = Buffer.from(hex, 'hex');
  let leadingOnes = 0;
  while (value[leadingOnes] === '1') {
    leadingOnes += 1;
  }
  return Buffer.concat([Buffer.alloc(leadingOnes), body]);
}

function readUleb128(bytes: Buffer, offset: number, what: string): { value: bigint; next: number } {
  let result = 0n;
  let shift = 0n;
  let pos = offset;
  for (;;) {
    if (pos >= bytes.length) {
      throw new BadgeError(`truncated ULEB128 (${what})`);
    }
    const byte = bytes[pos] as number;
    pos += 1;
    result |= BigInt(byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) {
      return { value: result, next: pos };
    }
    shift += 7n;
    if (shift > 70n) {
      throw new BadgeError(`ULEB128 overflow (${what})`);
    }
  }
}

/** Decode a bare badge short form (e.g. `JyP9...`). Checksum is mandatory. */
export function decodeBadgeShortForm(shortForm: string): DecodedBadge {
  const raw = decodeBase58(shortForm);
  if (raw.length < 1 + 4) {
    throw new BadgeError('badge too short for version + checksum');
  }
  if (raw[0] !== 0x02) {
    throw new BadgeError(`unexpected version byte: ${raw[0] as number}`);
  }
  const body = raw.subarray(1, raw.length - 4);
  const checksum = raw.subarray(raw.length - 4);
  const computed = createHash('sha256')
    .update(createHash('sha256').update(raw.subarray(0, raw.length - 4)).digest())
    .digest()
    .subarray(0, 4);
  if (!computed.equals(checksum)) {
    throw new BadgeError('checksum mismatch');
  }
  const index = readUleb128(body, 0, 'contract index');
  const subindex = readUleb128(body, index.next, 'contract subindex');
  const rest = body.subarray(subindex.next);
  if (rest.length !== 8) {
    throw new BadgeError(`expected 8 raw token-id bytes, found ${rest.length}`);
  }
  return {
    shortForm,
    contractIndex: index.value,
    contractSubindex: subindex.value,
    tokenId: rest.readBigUInt64LE(0),
  };
}

export interface DecodedCaip19 {
  readonly genesisPrefix: string;
  readonly shortForm: string;
}

/**
 * Split a CAIP-19 badge reference `ccd:<32hex>/cis-2:<short>`.
 * The genesis prefix is returned for comparison against the pinned chain.
 */
export function splitBadgeCaip19(value: string): DecodedCaip19 {
  const match = /^ccd:([0-9a-f]{32})\/cis-2:([1-9A-HJ-NP-Za-km-z]+)$/.exec(value);
  if (!match?.[1] || !match[2]) {
    throw new BadgeError('not a ccd/cis-2 CAIP-19 badge reference');
  }
  return { genesisPrefix: match[1], shortForm: match[2] };
}

/**
 * Encode a badge short form (the inverse of decodeBadgeShortForm).
 * Used to craft test vectors; the verifier itself only ever decodes.
 */
export function encodeBadgeShortForm(contractIndex: bigint, contractSubindex: bigint, tokenId: bigint): string {
  if (contractIndex < 0n || contractSubindex < 0n || tokenId < 0n || tokenId > (1n << 64n) - 1n) {
    throw new BadgeError('badge components out of range');
  }
  const uleb = (n: bigint): Buffer => {
    const bytes: number[] = [];
    let rest = n;
    for (;;) {
      const low = Number(rest & 0x7fn);
      rest >>= 7n;
      if (rest === 0n) {
        bytes.push(low);
        return Buffer.from(bytes);
      }
      bytes.push(low | 0x80);
    }
  };
  const id = Buffer.alloc(8);
  id.writeBigUInt64LE(tokenId);
  const payload = Buffer.concat([Buffer.from([0x02]), uleb(contractIndex), uleb(contractSubindex), id]);
  const checksum = createHash('sha256').update(createHash('sha256').update(payload).digest()).digest().subarray(0, 4);
  return encodeBase58(Buffer.concat([payload, checksum]));
}

/** Plain Bitcoin-alphabet Base58 encode (no version, no checksum): Concordium account display form. */
export function encodeBase58(bytes: Buffer): string {
  let n = BigInt(`0x${bytes.toString('hex') || '00'}`);
  let out = '';
  while (n > 0n) {
    const digit = Number(n % 58n);
    out = BITCOIN_ALPHABET[digit] + out;
    n /= 58n;
  }
  let leadingZeros = 0;
  while (leadingZeros < bytes.length && bytes[leadingZeros] === 0) {
    leadingZeros += 1;
  }
  return '1'.repeat(leadingZeros) + out;
}

/**
 * Render a 32-byte account address in Concordium display form for CAIP-10
 * comparison: Base58Check with version byte 0x01 over the 32 bytes plus a
 * 4-byte double-SHA256 checksum (37 bytes total). Verified against two
 * live SDK-decoded account vectors.
 */
export function accountHexToBase58(accountHex: string): string {
  if (!/^[0-9a-fA-F]{64}$/.test(accountHex)) {
    throw new BadgeError('account hex must be 32 bytes');
  }
  const payload = Buffer.concat([Buffer.from([0x01]), Buffer.from(accountHex, 'hex')]);
  const checksum = createHash('sha256').update(createHash('sha256').update(payload).digest()).digest().subarray(0, 4);
  return encodeBase58(Buffer.concat([payload, checksum]));
}
