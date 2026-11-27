/**
 * Arc control-read helper (Part A of the verifier plan). This module
 * contains ONLY the storage control read used to audit RPC behavior:
 * it reads one storage slot through a caller-supplied transport and
 * compares it against an independently derived expected value.
 *
 * No Arc contract checks live here yet (owner(), bytecode, proxies are a
 * later phase). The transport is injected so tests run fully offline.
 */

export type ArcBlockTag = 'latest' | 'finalized' | 'safe';

export interface ArcStorageTransport {
  /** Raw storage word at (address, slot, block) as 0x-hex. */
  readStorage(address: string, slot: string, block: ArcBlockTag | bigint): Promise<string>;
  /** Result of eth_call owner() on the address (independent expectation source). */
  readOwnerCall(address: string): Promise<string>;
}

export interface ControlReadInput {
  readonly address: string;
  readonly slot: string;
  readonly blocks: ReadonlyArray<ArcBlockTag | bigint>;
}

export interface ControlReadEntry {
  readonly block: string;
  readonly observed: string;
  readonly match: boolean;
}

export interface ControlReadResult {
  readonly expected: string;
  readonly entries: readonly ControlReadEntry[];
  /** True only if every read matched. A single mismatch fails the control. */
  readonly allMatch: boolean;
}

function normalizeWord(value: string): string {
  const clean = value.startsWith('0x') ? value.slice(2) : value;
  if (!/^[0-9a-fA-F]{64}$/.test(clean)) {
    throw new Error(`expected 32-byte hex word, got: ${value.slice(0, 40)}`);
  }
  return `0x${clean.toLowerCase()}`;
}

/**
 * Run the control matrix: expected value from eth_call owner(), then the
 * slot read at each requested block. Any transport error propagates to
 * the caller (control reads must never silently pass).
 */
export async function runControlRead(
  transport: ArcStorageTransport,
  input: ControlReadInput,
): Promise<ControlReadResult> {
  if (input.blocks.length === 0) {
    throw new Error('control requires at least one block tag; zero reads prove nothing');
  }
  const expected = normalizeWord(await transport.readOwnerCall(input.address));
  const entries: ControlReadEntry[] = [];
  for (const block of input.blocks) {
    const observed = normalizeWord(await transport.readStorage(input.address, input.slot, block));
    entries.push({
      block: typeof block === 'bigint' ? `number:${block.toString()}` : `tag:${block}`,
      observed,
      match: observed === expected,
    });
  }
  return { expected, entries, allMatch: entries.every((entry) => entry.match) };
}
