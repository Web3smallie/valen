import { EvidenceCollector } from '../evidence.js';
import type { CheckOutcome } from '../types.js';
import { IMPL_SLOT, keccakOfCode, type ArcContractPin, type ArcReads } from './contracts.js';

/**
 * Proxy linkage check (C2d): the ERC-1967 implementation slot must equal
 * the pinned implementation address, and that implementation's code hash
 * must equal its pin. The slot sub-check goes INCONCLUSIVE when the
 * control read did not establish TRUSTED_FOR_SLOTS; the code-hash
 * comparison always evaluates.
 */
export async function checkProxyLinkage(
  arc: ArcReads,
  pin: ArcContractPin,
  finalizedBlock: string,
  controlTrusted: boolean,
): Promise<CheckOutcome> {
  const collector = new EvidenceCollector(`arc-${pin.name}-proxy`, 'Arc RPC reads', arc.endpoint);
  let slotWord: string;
  try {
    slotWord = await arc.getStorageAt(pin.proxy, IMPL_SLOT, 'finalized');
  } catch (error) {
    collector.row({
      block: finalizedBlock,
      raw: error instanceof Error ? error.message.slice(0, 160) : 'transport error',
      derived: 'implementation slot unreadable',
      verdict: 'INCONCLUSIVE',
    });
    return collector.finish();
  }
  const slotAddress = `0x${slotWord.slice(-40).toLowerCase()}`;
  if (!controlTrusted) {
    collector.row({
      block: finalizedBlock,
      raw: `impl slot: ${slotWord.slice(0, 66)} -> ${slotAddress}`,
      derived: 'control read untrusted: slot evidence recorded but not decisive',
      verdict: 'INCONCLUSIVE',
    });
  } else if (slotAddress !== pin.implementation.toLowerCase()) {
    collector.row({
      block: finalizedBlock,
      raw: `impl slot: ${slotWord.slice(0, 66)} -> ${slotAddress}`,
      derived: `pinned ${pin.implementation.toLowerCase()}: MISMATCH`,
      verdict: 'FAIL',
    });
    return collector.finish();
  } else {
    collector.row({
      block: finalizedBlock,
      raw: `impl slot -> ${slotAddress}`,
      derived: `matches pinned ${pin.implementation}`,
      verdict: 'PASS',
    });
  }
  let implCode: string;
  try {
    implCode = await arc.getCode(pin.implementation, 'finalized');
  } catch (error) {
    collector.row({
      block: finalizedBlock,
      raw: error instanceof Error ? error.message.slice(0, 160) : 'transport error',
      derived: `implementation code at ${pin.implementation} unreadable`,
      verdict: 'INCONCLUSIVE',
    });
    return collector.finish();
  }
  if (implCode === '0x' || implCode.length <= 2) {
    collector.row({
      block: finalizedBlock,
      raw: `code at ${pin.implementation}: empty`,
      derived: 'implementation has no deployed bytecode',
      verdict: 'FAIL',
    });
    return collector.finish();
  }
  let implHash: string;
  try {
    implHash = keccakOfCode(implCode);
  } catch {
    collector.row({
      block: finalizedBlock,
      raw: `code at ${pin.implementation}: ${implCode.slice(0, 40)}...`,
      derived: 'code is not valid hex',
      verdict: 'FAIL',
    });
    return collector.finish();
  }
  const hashOk = implHash.toLowerCase() === pin.implementationCodeHash.toLowerCase();
  collector.row({
    block: finalizedBlock,
    raw: `impl code ${implCode.length / 2 - 1} bytes, keccak ${implHash}`,
    derived: hashOk ? `matches pinned ${pin.implementationCodeHash}` : `pinned ${pin.implementationCodeHash}: MISMATCH`,
    verdict: hashOk ? 'PASS' : 'FAIL',
  });
  return collector.finish();
}
