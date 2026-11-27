/**
 * Valen CIS-8 binding preparation (Step 2).
 *
 * READ-ONLY: prints the exact binding to create and verifies the
 * result afterwards. This script NEVER signs, submits, or broadcasts —
 * it holds no keys. The Arc owner key signs the canonical bytes and
 * the Concordium account submits `registerExternalKey`, both as
 * human approval-gated actions.
 *
 * Usage (all identity inputs explicit — no fixture defaults):
 *   npx tsx src/prepareValenBinding.ts --account <base58> --pubkey <hex>
 *   npx tsx src/prepareValenBinding.ts --account <base58> --pubkey <hex> --verify
 *
 * Step 2 binds Valen's Concordium account to Valen's Arc contract-owner
 * key. Borrower identity, Agent Card, badge, MCP, and A2A are out of
 * scope. The F1 borrower fixture must never be used here.
 */
import { AccountAddress } from '@concordium/web-sdk';
import { publicClient } from './chain/publicClient.js';
import { contracts, manifest } from './config/contracts.js';
import { CONCORDIUM_TESTNET_POLICY } from './concordium/config.js';
import { parseOwnerOfKeyResponse, encodeExternalKeyId } from './concordium/cis8.js';
import { GrpcConcordiumNode } from './concordium/node.js';
import { ConcordiumError, type EvmAddress } from './concordium/types.js';
import {
  buildCis8CanonicalBytes,
  buildValenBindingKeyId,
  ethereumPersonalSignDigest,
  VALEN_ARC_OWNER,
  VALEN_CIS8_NAMESPACE,
  VALEN_CIS8_PROOF_SCHEME,
  verifyArcContractOwners,
  verifyValenBinding,
} from './concordium/valenBinding.js';

const OWNER_ABI = [
  {
    type: 'function',
    name: 'owner',
    inputs: [],
    outputs: [{ name: '', type: 'address' }],
    stateMutability: 'view',
  },
] as const;

const policy = CONCORDIUM_TESTNET_POLICY;
const node = new GrpcConcordiumNode(policy.grpcHost, policy.grpcPort, policy.grpcSecure);

function argValue(args: string[], flag: string): string {
  const index = args.indexOf(flag);
  if (index === -1 || index + 1 >= args.length) {
    console.error(`missing required ${flag} <value> (no defaults; never a fixture value)`);
    process.exit(1);
  }
  return args[index + 1];
}

function formatCcd(microCcd: string): string {
  const micro = BigInt(microCcd);
  const whole = micro / 1000000n;
  const frac = (micro % 1000000n).toString().padStart(6, '0').replace(/0+$/, '') || '0';
  return `${whole}.${frac}`;
}

async function checkArcOwners(): Promise<{ checked: number; code: string }> {
  if (manifest.chainId !== 5042002) {
    throw new ConcordiumError('VALEN_ARC_OWNER_MISMATCH', `manifest chain ${manifest.chainId} is not Arc Testnet`);
  }
  const addresses = Object.values(contracts) as string[];
  try {
    const result = await verifyArcContractOwners(
      {
        readOwner: (contractAddress) =>
          publicClient.readContract({
            address: contractAddress as `0x${string}`,
            abi: OWNER_ABI,
            functionName: 'owner',
          }) as Promise<EvmAddress>,
      },
      { contractAddresses: addresses, expectedWallet: VALEN_ARC_OWNER },
    );
    const code = await publicClient.getCode({ address: VALEN_ARC_OWNER });
    if (code !== undefined && code !== '0x') {
      throw new ConcordiumError('VALEN_ARC_OWNER_MISMATCH', 'Arc owner is not an EOA');
    }
    return { checked: result.checked, code: code ?? '0x' };
  } catch (error) {
    if (error instanceof ConcordiumError) {
      throw error;
    }
    const detail = error instanceof Error ? error.message.split('\n')[0] : String(error);
    throw new ConcordiumError('VALEN_ARC_OWNER_MISMATCH', `Arc RPC read failed: ${detail.slice(0, 160)}`);
  }
}

async function prepare(account: string, pubkey: string): Promise<void> {
  const key = buildValenBindingKeyId(pubkey);
  const ownerHex = Buffer.from(AccountAddress.fromBase58(account).decodedAddress).toString('hex');

  // Fail closed: Concordium account must exist with exactly one normal credential.
  const ccdAccount = await node.getAccount(account);
  if (ccdAccount.credentials.length !== 1 || ccdAccount.credentials[0].type !== 'normal') {
    throw new ConcordiumError('PROVER_MULTI_CREDENTIAL', 'binding account must hold exactly one normal credential');
  }

  // Fail closed: no active binding may already exist for this key.
  const existing = await node.invokeOwnerOfKey(
    policy.cis8ContractIndex,
    policy.cis8ContractSubindex,
    encodeExternalKeyId(key),
  );
  const parsed = parseOwnerOfKeyResponse(existing);
  if (parsed.found) {
    throw new ConcordiumError(
      'CIS8_OWNER_MISMATCH',
      `key already bound (owner ${parsed.ownerHex}, ${parsed.status}); revoke or displace deliberately, never blindly`,
    );
  }

  const arc = await checkArcOwners();
  const canonicalHex = buildCis8CanonicalBytes({
    concordiumAccount: account,
    contractIndex: policy.cis8ContractIndex,
    contractSubindex: policy.cis8ContractSubindex,
    genesisHashHex: policy.genesisHashHex,
    key,
  });
  const digest = ethereumPersonalSignDigest(canonicalHex);

  console.log('Valen CIS-8 binding — prepare (nothing submitted, nothing signed)\n');
  console.log(`concordium account: ${account}`);
  console.log(`concordium owner:   ${ownerHex}`);
  console.log(`arc owner key:      ${key.publicKeyHex}`);
  console.log(`arc owner address:  ${VALEN_ARC_OWNER} (all ${arc.checked} contracts agree; EOA code ${arc.code})`);
  console.log(`namespace:          ${key.namespace}`);
  console.log(`key type:           ${key.keyType}`);
  console.log(`proof scheme:       ${VALEN_CIS8_PROOF_SCHEME}`);
  console.log(`existing binding:   none (clean slate)`);
  console.log(`sender standing:    nonce ${ccdAccount.nonce}, ${formatCcd(ccdAccount.microCcd)} CCD, IP ${ccdAccount.credentials[0].ipIdentity}`);
  console.log(`\ncanonical bytes (${canonicalHex.length / 2} bytes, sign exactly these):`);
  console.log(canonicalHex);
  console.log(`\npersonal-sign digest to sign (EIP-191 envelope + keccak):`);
  console.log(digest);
  console.log('\nApproval-gated procedure (human actions, in order):');
  console.log('  1. Approve THIS binding (account + key + namespace above).');
  console.log('  2. Sign the digest with the Arc owner key (personal_sign / eth_sign).');
  console.log('  3. Submit CIS-8 registerExternalKey from the Concordium account with');
  console.log('     the key id + {scheme: ethereum-personal-sign, signature} proof.');
  console.log('  4. Re-run with --verify to confirm from live chain state.');
}

async function verify(account: string, pubkey: string): Promise<void> {
  const key = buildValenBindingKeyId(pubkey);
  const ownerHex = Buffer.from(AccountAddress.fromBase58(account).decodedAddress).toString('hex');
  const verified = await verifyValenBinding(node, {
    contractIndex: policy.cis8ContractIndex,
    contractSubindex: policy.cis8ContractSubindex,
    key,
    expectedOwnerHex: ownerHex,
    expectedWallet: VALEN_ARC_OWNER,
  });
  const arc = await checkArcOwners();
  console.log('Valen CIS-8 binding CONFIRMED:');
  console.log(`  owner:      ${verified.ownerHex}`);
  console.log(`  namespace:  ${verified.namespace} / ${verified.keyType}`);
  console.log(`  scheme:     ${verified.proofScheme}`);
  console.log(`  wallet:     ${verified.address}`);
  console.log(`  arc owners: all ${arc.checked} contracts report ${VALEN_ARC_OWNER}`);
}

const args = process.argv.slice(2);
try {
  const account = argValue(args, '--account');
  const pubkey = argValue(args, '--pubkey');
  if (args.includes('--verify')) {
    await verify(account, pubkey);
  } else {
    await prepare(account, pubkey);
  }
} catch (error) {
  if (error instanceof ConcordiumError) {
    console.error(`rejected: ${error.message}`);
    process.exit(2);
  }
  throw error;
}
