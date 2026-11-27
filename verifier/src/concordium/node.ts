import { ChannelCredentials } from '@grpc/grpc-js';
import { GrpcTransport } from '@protobuf-ts/grpc-transport';
import {
  AccountTransactionType,
  BlockHash,
  ConcordiumGRPCClient,
  ContractAddress,
  Energy,
  Parameter,
  ReceiveName,
} from '@concordium/web-sdk';
import { encodeTokenIdParam } from './agentView.js';
import { encodeExternalKeyId, type Cis8KeyId } from './cis8.js';

/**
 * Concordium read transport. The SDK is used ONLY as a gRPC pipe:
 * every byte it returns is parsed by the hand-written modules above.
 * Read-only by construction: this module exposes no submission path.
 *
 * Every read pins to an explicit block hash (normally the last finalized
 * block) so results are reproducible and attributable.
 */
export interface ConcordiumTransports {
  getFinalizedBlock(): Promise<{ hash: string; height: string }>;
  invokeAgentOf(
    contract: { index: bigint; subindex: bigint },
    tokenId: bigint,
    blockHash: string,
  ): Promise<string>;
  invokeOwnerOfKey(
    contract: { index: bigint; subindex: bigint },
    key: Cis8KeyId,
    blockHash: string,
  ): Promise<string>;
  invokeAgentByExternalReference(
    contract: { index: bigint; subindex: bigint },
    externalReferenceHex: string,
    blockHash: string,
  ): Promise<string>;
  readonly endpoint: string;
}

const INVOKE_ENERGY = 30000;

export class LiveConcordiumNode implements ConcordiumTransports {
  readonly endpoint: string;
  private readonly client: ConcordiumGRPCClient;

  constructor(host = 'grpc.testnet.concordium.com', port = 20000) {
    this.endpoint = `${host}:${port}`;
    const transport = new GrpcTransport({
      host: `${host}:${port}`,
      channelCredentials: ChannelCredentials.createSsl(),
    });
    this.client = new ConcordiumGRPCClient(transport);
  }

  async getFinalizedBlock(): Promise<{ hash: string; height: string }> {
    const status = await this.client.getConsensusStatus();
    return {
      hash: Buffer.from(status.lastFinalizedBlock.buffer).toString('hex'),
      height: status.lastFinalizedBlockHeight.toString(),
    };
  }

  private async invoke(
    contract: { index: bigint; subindex: bigint },
    receiveName: string,
    parameterHex: string,
    blockHash: string,
  ): Promise<string> {
    const result = await this.client.invokeContract(
      {
        contract: ContractAddress.create(contract.index, contract.subindex),
        method: ReceiveName.fromStringUnchecked(receiveName),
        parameter: Parameter.fromHexString(parameterHex),
        energy: Energy.create(INVOKE_ENERGY),
      },
      BlockHash.fromHexString(blockHash),
    );
    if (result.tag !== 'success') {
      throw new Error(`contract invoke rejected: ${String(result.reason).slice(0, 200)}`);
    }
    const buffer = (result.returnValue as { buffer?: Uint8Array } | undefined)?.buffer;
    if (!(buffer instanceof Uint8Array) && !Buffer.isBuffer(buffer)) {
      throw new Error('contract invoke returned no bytes');
    }
    return Buffer.from(buffer as Uint8Array).toString('hex');
  }

  invokeAgentOf(
    contract: { index: bigint; subindex: bigint },
    tokenId: bigint,
    blockHash: string,
  ): Promise<string> {
    return this.invoke(contract, 'CIS-8004.agentOf', encodeTokenIdParam(tokenId), blockHash);
  }

  invokeOwnerOfKey(
    contract: { index: bigint; subindex: bigint },
    key: Cis8KeyId,
    blockHash: string,
  ): Promise<string> {
    return this.invoke(contract, 'CIS-8.ownerOfKey', encodeExternalKeyId(key), blockHash);
  }

  invokeAgentByExternalReference(
    contract: { index: bigint; subindex: bigint },
    externalReferenceHex: string,
    blockHash: string,
  ): Promise<string> {
    return this.invoke(contract, 'CIS-8004.agentByExternalReference', externalReferenceHex, blockHash);
  }
}

export { AccountTransactionType };
