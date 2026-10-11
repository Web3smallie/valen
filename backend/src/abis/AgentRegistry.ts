// Regenerated from out/AgentRegistry.sol/AgentRegistry.json
export const AgentRegistryAbi = [
  { "type": "constructor", "inputs": [], "stateMutability": "nonpayable" },
  {
    "type": "function", "name": "addWallet",
    "inputs": [
      { "name": "agentId", "type": "uint256" },
      { "name": "wallet",  "type": "address" }
    ],
    "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "agentOwner",
    "inputs": [{ "name": "", "type": "uint256" }],
    "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "erc8004Ref",
    "inputs": [{ "name": "", "type": "uint256" }],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "getAgentId",
    "inputs": [{ "name": "wallet", "type": "address" }],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "initialize",
    "inputs": [{ "name": "initialOwner", "type": "address" }],
    "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "isAuthorizedWallet",
    "inputs": [
      { "name": "agentId", "type": "uint256" },
      { "name": "wallet",  "type": "address" }
    ],
    "outputs": [{ "name": "", "type": "bool" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "nextAgentId",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "owner",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "proxiableUUID",
    "inputs": [], "outputs": [{ "name": "", "type": "bytes32" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "registerAgent",
    "inputs": [{ "name": "erc8004TokenId", "type": "uint256" }],
    "outputs": [{ "name": "agentId", "type": "uint256" }],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "removeWallet",
    "inputs": [
      { "name": "agentId", "type": "uint256" },
      { "name": "wallet",  "type": "address" }
    ],
    "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "renounceOwnership",
    "inputs": [], "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "transferAgentOwnership",
    "inputs": [
      { "name": "agentId",  "type": "uint256" },
      { "name": "newOwner", "type": "address" }
    ],
    "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "transferOwnership",
    "inputs": [{ "name": "newOwner", "type": "address" }],
    "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "upgradeToAndCall",
    "inputs": [
      { "name": "newImplementation", "type": "address" },
      { "name": "data",              "type": "bytes"   }
    ],
    "outputs": [], "stateMutability": "payable"
  },
  {
    "type": "function", "name": "walletCount",
    "inputs": [{ "name": "agentId", "type": "uint256" }],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "walletToAgent",
    "inputs": [{ "name": "", "type": "address" }],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "event", "name": "AgentRegistered",
    "inputs": [
      { "name": "agentId",        "type": "uint256", "indexed": true  },
      { "name": "owner",          "type": "address", "indexed": true  },
      { "name": "erc8004TokenId", "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "AgentOwnershipTransferred",
    "inputs": [
      { "name": "agentId",  "type": "uint256", "indexed": true },
      { "name": "oldOwner", "type": "address", "indexed": true },
      { "name": "newOwner", "type": "address", "indexed": true }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "WalletAdded",
    "inputs": [
      { "name": "agentId", "type": "uint256", "indexed": true },
      { "name": "wallet",  "type": "address", "indexed": true }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "WalletRemoved",
    "inputs": [
      { "name": "agentId", "type": "uint256", "indexed": true },
      { "name": "wallet",  "type": "address", "indexed": true }
    ],
    "anonymous": false
  },
  { "type": "error", "name": "AgentDoesNotExist",      "inputs": [] },
  { "type": "error", "name": "CannotRemoveLastWallet", "inputs": [] },
  { "type": "error", "name": "NotAgentOwner",          "inputs": [] },
  { "type": "error", "name": "WalletAlreadyRegistered","inputs": [] },
  { "type": "error", "name": "WalletNotAuthorized",    "inputs": [] },
  { "type": "error", "name": "ZeroAddress",            "inputs": [] }
] as const;
