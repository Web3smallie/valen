/**
 * Valen service-agent registration preparation (Step 1).
 *
 * READ-ONLY: prints the exact transaction to sign and verifies the
 * result afterwards. This script NEVER signs, submits, or broadcasts —
 * it holds no keys. A human signs with the owner wallet.
 *
 * Usage:
 *   npx tsx src/prepareServiceAgentRegistration.ts <sender-base58>
 *   npx tsx src/prepareServiceAgentRegistration.ts --verify <tokenId> <owner-base58-or-hex>
 *
 * Step 1 registers Valen's SERVICE identity (bare: no URI, hash,
 * external reference, or metadata). Borrower agents, CIS-8 binding,
 * Agent Card, badge, and verifier work are out of scope.
 */
import { AccountAddress } from '@concordium/web-sdk';
import { CONCORDIUM_TESTNET_POLICY } from './concordium/config.js';
import { GrpcConcordiumNode } from './concordium/node.js';
import {
  buildServiceAgentRegistration,
  verifyServiceAgentRegistration,
} from './concordium/serviceAgent.js';
import { ConcordiumError } from './concordium/types.js';

const policy = CONCORDIUM_TESTNET_POLICY;
const node = new GrpcConcordiumNode(policy.grpcHost, policy.grpcPort, policy.grpcSecure);

function formatCcd(microCcd: string): string {
  const micro = BigInt(microCcd);
  const whole = micro / 1000000n;
  const frac = (micro % 1000000n).toString().padStart(6, '0').replace(/0+$/, '') || '0';
  return `${whole}.${frac}`;
}

function ownerToHex(owner: string): string {
  if (/^(0x)?[0-9a-fA-F]{64}$/.test(owner)) {
    return owner.replace(/^0x/i, '').toLowerCase();
  }
  return Buffer.from(AccountAddress.fromBase58(owner).decodedAddress).toString('hex');
}

async function prepare(sender: string): Promise<void> {
  const descriptor = buildServiceAgentRegistration({
    sender,
    contractIndex: policy.cis8004ContractIndex,
    contractSubindex: policy.cis8004ContractSubindex,
  });

  // Fail closed: the sender must exist on testnet before anything is signed.
  const account = await node.getAccount(descriptor.sender);
  if (account.credentials.length !== 1 || account.credentials[0].type !== 'normal') {
    throw new ConcordiumError('PROVER_MULTI_CREDENTIAL', 'sender must hold exactly one normal credential');
  }

  console.log('Valen service-agent registration — prepare (nothing submitted)\n');
  console.log(JSON.stringify(
    {
      ...descriptor,
      contractIndex: descriptor.contractIndex.toString(),
      contractSubindex: descriptor.contractSubindex.toString(),
    },
    null,
    2,
  ));
  console.log('\nSender standing (live):');
  console.log(`  nonce:        ${account.nonce}`);
  console.log(`  balance:      ${formatCcd(account.microCcd)} CCD`);
  console.log(`  credentials:  ${account.credentials.length} (${account.credentials[0].type}, IP ${account.credentials[0].ipIdentity})`);
  console.log(`  valid:        ${account.credentials[0].createdAtYYYYMM}–${account.credentials[0].validToYYYYMM}`);
  console.log('\nOn submit, testnet CIS-8004 will: mint a new agent NFT to the sender,');
  console.log('set status Active, and emit Registered. No URI/hash is set (Step 2).');
  console.log('\nSubmit with the owner wallet (pick one):');
  console.log('  1. Agent Registry app: https://agent-registry.concordium.com/ (register flow)');
  console.log('  2. Wallet `contract update`: contract 12802,0 / CIS-8004.register /');
  console.log(`     parameter-hex ${descriptor.parameterHex} / energy ${descriptor.suggestedEnergy}`);
  console.log('\nAfter submit, verify with:');
  console.log('  npx tsx src/prepareServiceAgentRegistration.ts --verify <tokenId> <sender>');
}

async function verify(tokenIdRaw: string, ownerRaw: string): Promise<void> {
  let tokenId: bigint;
  try {
    tokenId = BigInt(tokenIdRaw);
    if (tokenId < 0n) {
      throw new Error('negative');
    }
  } catch {
    throw new ConcordiumError('SERVICE_AGENT_TOKEN_ID_INVALID', 'token id must be a non-negative integer');
  }
  let expectedOwnerHex: string;
  try {
    expectedOwnerHex = ownerToHex(ownerRaw);
  } catch {
    throw new ConcordiumError('SERVICE_AGENT_SENDER_MALFORMED', 'owner must be base58 account or 32-byte hex');
  }
  const verified = await verifyServiceAgentRegistration(node, {
    contractIndex: policy.cis8004ContractIndex,
    contractSubindex: policy.cis8004ContractSubindex,
    tokenId,
    expectedOwnerHex,
  });
  console.log('Service-agent registration CONFIRMED:');
  console.log(JSON.stringify(
    { ...verified, tokenId: verified.tokenId.toString() },
    null,
    2,
  ));
  console.log(`CCDScan: https://testnet.ccdscan.io/?dcount=1&dentity=contract&daddress=${policy.cis8004ContractIndex}`);
}

const args = process.argv.slice(2);
try {
  if (args[0] === '--verify') {
    if (args.length !== 3) {
      console.error('usage: prepareServiceAgentRegistration.ts --verify <tokenId> <owner-base58-or-hex>');
      process.exit(1);
    }
    await verify(args[1], args[2]);
  } else {
    if (args.length !== 1) {
      console.error('usage: prepareServiceAgentRegistration.ts <sender-base58>');
      process.exit(1);
    }
    await prepare(args[0]);
  }
} catch (error) {
  if (error instanceof ConcordiumError) {
    console.error(`rejected: ${error.message}`);
    process.exit(2);
  }
  throw error;
}
