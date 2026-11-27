/**
 * Concordium node access behind a narrow, mockable interface.
 *
 * Only read operations are exposed: account info (by address or credential
 * id), CIS-8 `ownerOfKey` and CIS-8004 `agentOf` contract invokes, global
 * cryptographic parameters, and consensus status. Transaction submission
 * is deliberately absent — this module NEVER signs or broadcasts.
 *
 * All values crossing this boundary are normalized to plain JSON-safe data
 * (bigints become decimal strings, byte arrays become lowercase hex) so
 * fixtures are stable and logging is safe.
 */

import { ChannelCredentials } from '@grpc/grpc-js';
import { GrpcTransport } from '@protobuf-ts/grpc-transport';
import {
  AccountAddress,
  ConcordiumGRPCClient,
  ContractAddress,
  CredentialRegistrationId,
  Energy,
  Parameter,
  ReceiveName,
} from '@concordium/web-sdk';
import { ConcordiumError } from './types.js';

/** Normalized on-chain credential (subset Valen enforces). */
export interface CredentialView {
  readonly index: number;
  /** 'normal' for standard credentials; anything else must be rejected. */
  readonly type: string;
  readonly ipIdentity: number;
  readonly credIdHex: string;
  readonly validToYYYYMM: string;
  readonly createdAtYYYYMM: string;
  /** Attribute commitments keyed by commitment name (hex values). */
  readonly commitments: Record<string, string>;
}

export interface AccountView {
  readonly address: string;
  readonly nonce: string;
  readonly microCcd: string;
  readonly credentials: CredentialView[];
}

export interface ConcordiumNode {
  getAccount(addressBase58: string): Promise<AccountView>;
  getAccountByCredId(credIdHex: string): Promise<AccountView>;
  invokeOwnerOfKey(contractIndex: bigint, contractSubindex: bigint, paramHex: string): Promise<string>;
  invokeAgentOf(contractIndex: bigint, contractSubindex: bigint, paramHex: string): Promise<string>;
  getGlobalContext(): Promise<unknown>;
  getBestBlockHeight(): Promise<string>;
}

function hexOf(value: unknown): string {
  if (typeof value === 'string') {
    return value.startsWith('0x') ? value.slice(2).toLowerCase() : value.toLowerCase();
  }
  if (value instanceof Uint8Array) {
    return Buffer.from(value).toString('hex');
  }
  if (Buffer.isBuffer(value)) {
    return value.toString('hex');
  }
  throw new ConcordiumError('NODE_ERROR', 'unexpected binary encoding from node client');
}

function asRecord(value: unknown, what: string): Record<string, unknown> {
  if (typeof value !== 'object' || value === null) {
    throw new ConcordiumError('NODE_ERROR', `malformed node response (${what})`);
  }
  return value as Record<string, unknown>;
}

function normalizeCredential(index: number, raw: unknown): CredentialView {
  const entry = asRecord(raw, 'credential entry');
  const value = asRecord(entry['value'], 'credential value');
  if (typeof value['type'] !== 'string') {
    throw new ConcordiumError('NODE_ERROR', 'credential missing type');
  }
  const contents = asRecord(value['contents'], 'credential contents');
  const policy = asRecord(contents['policy'], 'credential policy');
  // Only the per-attribute commitments feed presentation verification
  // (`CredentialsInputsAccount.commitments`, keyed by attribute name).
  // The sibling top-level entries (cmmPrf, sharing coefficients, ...) are
  // not verification inputs and are intentionally dropped.
  const commitmentsRaw = asRecord(contents['commitments'], 'credential commitments');
  const attributesRaw = asRecord(commitmentsRaw['cmmAttributes'], 'attribute commitments');
  const commitments: Record<string, string> = {};
  for (const [name, commitment] of Object.entries(attributesRaw)) {
    if (typeof commitment !== 'string') {
      throw new ConcordiumError('NODE_ERROR', `attribute commitment '${name}' malformed`);
    }
    commitments[name] = hexOf(commitment);
  }
  if (typeof contents['ipIdentity'] !== 'number') {
    throw new ConcordiumError('NODE_ERROR', 'credential missing ipIdentity');
  }
  if (typeof policy['validTo'] !== 'string' || typeof policy['createdAt'] !== 'string') {
    throw new ConcordiumError('NODE_ERROR', 'credential policy missing validity window');
  }
  return {
    index,
    type: value['type'] as string,
    ipIdentity: contents['ipIdentity'] as number,
    credIdHex: hexOf(contents['credId']),
    validToYYYYMM: policy['validTo'] as string,
    createdAtYYYYMM: policy['createdAt'] as string,
    commitments,
  };
}

function normalizeAccountInfo(raw: unknown, address: string): AccountView {
  const info = asRecord(raw, 'account info');
  const credentialsRaw = asRecord(info['accountCredentials'], 'account credentials');
  const credentials = Object.entries(credentialsRaw).map(([index, credential]) =>
    normalizeCredential(Number.parseInt(index, 10), credential),
  );
  return {
    address,
    nonce: String(info['accountNonce']),
    microCcd: String(
      (info['accountAmount'] as { microCcdAmount?: unknown } | undefined)?.microCcdAmount ??
        info['accountAmount'],
    ),
    credentials,
  };
}

export class GrpcConcordiumNode implements ConcordiumNode {
  private readonly client: ConcordiumGRPCClient;

  constructor(host: string, port: number, secure: boolean) {
    const transport = new GrpcTransport({
      host: `${host}:${port}`,
      channelCredentials: secure ? ChannelCredentials.createSsl() : ChannelCredentials.createInsecure(),
    });
    this.client = new ConcordiumGRPCClient(transport);
  }

  async getAccount(addressBase58: string): Promise<AccountView> {
    try {
      const info = await this.client.getAccountInfo(AccountAddress.fromBase58(addressBase58));
      return normalizeAccountInfo(info, addressBase58);
    } catch (error) {
      throw this.wrap(error, 'getAccountInfo');
    }
  }

  async getAccountByCredId(credIdHex: string): Promise<AccountView> {
    try {
      const info = await this.client.getAccountInfo(
        CredentialRegistrationId.fromHexString(credIdHex),
      );
      const view = normalizeAccountInfo(info, '');
      return { ...view, address: view.address };
    } catch (error) {
      throw this.wrap(error, 'getAccountInfo');
    }
  }

  async invokeOwnerOfKey(
    contractIndex: bigint,
    contractSubindex: bigint,
    paramHex: string,
  ): Promise<string> {
    try {
      const result = await this.client.invokeContract({
        contract: ContractAddress.create(contractIndex, contractSubindex),
        method: ReceiveName.fromStringUnchecked('CIS-8.ownerOfKey'),
        parameter: Parameter.fromHexString(paramHex),
        energy: Energy.create(30000),
      });
      if (result.tag !== 'success') {
        throw new ConcordiumError('NODE_ERROR', `ownerOfKey rejected: ${String(result.reason)}`);
      }
      const buffer = (result.returnValue as { buffer?: Uint8Array } | undefined)?.buffer;
      if (!(buffer instanceof Uint8Array) && !Buffer.isBuffer(buffer)) {
        throw new ConcordiumError('NODE_ERROR', 'ownerOfKey missing return value');
      }
      return Buffer.from(buffer as Uint8Array).toString('hex');
    } catch (error) {
      if (error instanceof ConcordiumError) {
        throw error;
      }
      throw this.wrap(error, 'invokeContract');
    }
  }

  async invokeAgentOf(
    contractIndex: bigint,
    contractSubindex: bigint,
    paramHex: string,
  ): Promise<string> {
    try {
      const result = await this.client.invokeContract({
        contract: ContractAddress.create(contractIndex, contractSubindex),
        method: ReceiveName.fromStringUnchecked('CIS-8004.agentOf'),
        parameter: Parameter.fromHexString(paramHex),
        energy: Energy.create(30000),
      });
      if (result.tag !== 'success') {
        throw new ConcordiumError('NODE_ERROR', `agentOf rejected: ${String(result.reason)}`);
      }
      const buffer = (result.returnValue as { buffer?: Uint8Array } | undefined)?.buffer;
      if (!(buffer instanceof Uint8Array) && !Buffer.isBuffer(buffer)) {
        throw new ConcordiumError('NODE_ERROR', 'agentOf missing return value');
      }
      return Buffer.from(buffer as Uint8Array).toString('hex');
    } catch (error) {
      if (error instanceof ConcordiumError) {
        throw error;
      }
      throw this.wrap(error, 'invokeContract');
    }
  }

  async getGlobalContext(): Promise<unknown> {
    try {
      return await this.client.getCryptographicParameters();
    } catch (error) {
      throw this.wrap(error, 'getCryptographicParameters');
    }
  }

  async getBestBlockHeight(): Promise<string> {
    try {
      const status = await this.client.getConsensusStatus();
      return String(status.bestBlockHeight);
    } catch (error) {
      throw this.wrap(error, 'getConsensusStatus');
    }
  }

  private wrap(error: unknown, operation: string): ConcordiumError {
    if (error instanceof ConcordiumError) {
      return error;
    }
    const detail = error instanceof Error ? error.message : String(error);
    return new ConcordiumError('NODE_ERROR', `${operation}: ${detail.slice(0, 200)}`);
  }
}
