// Regenerated from out/ActivityAttester.sol/ActivityAttester.json
export const ActivityAttesterAbi = [
  { "type": "constructor", "inputs": [], "stateMutability": "nonpayable" },
  {
    "type": "function", "name": "agentRegistry",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "approvedActivitySources",
    "inputs": [{ "name": "", "type": "address" }],
    "outputs": [{ "name": "", "type": "bool" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "attestActivity",
    "inputs": [
      { "name": "source",         "type": "address" },
      { "name": "jobId",          "type": "uint256" },
      { "name": "agentId",        "type": "uint256" },
      { "name": "providerWallet", "type": "address" },
      { "name": "amount",         "type": "uint256" }
    ],
    "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "attestedActivity",
    "inputs": [{ "name": "", "type": "bytes32" }],
    "outputs": [{ "name": "", "type": "bool" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "creditRegistry",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "initialize",
    "inputs": [
      { "name": "initialOwner",   "type": "address" },
      { "name": "_agentRegistry", "type": "address" },
      { "name": "_creditRegistry","type": "address" }
    ],
    "outputs": [], "stateMutability": "nonpayable"
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
    "type": "function", "name": "renounceOwnership",
    "inputs": [], "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "setActivitySource",
    "inputs": [
      { "name": "source",   "type": "address" },
      { "name": "approved", "type": "bool"    }
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
    "type": "event", "name": "ActivityAttested",
    "inputs": [
      { "name": "agentId",      "type": "uint256", "indexed": true  },
      { "name": "source",       "type": "address", "indexed": true  },
      { "name": "jobId",        "type": "uint256", "indexed": true  },
      { "name": "providerWallet","type": "address","indexed": false },
      { "name": "amount",       "type": "uint256", "indexed": false },
      { "name": "evidenceKey",  "type": "bytes32", "indexed": false }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "ActivitySourceSet",
    "inputs": [
      { "name": "source",   "type": "address", "indexed": true  },
      { "name": "approved", "type": "bool",    "indexed": false }
    ],
    "anonymous": false
  },
  { "type": "error", "name": "AlreadyAttested",     "inputs": [] },
  { "type": "error", "name": "NotApprovedSource",   "inputs": [] },
  { "type": "error", "name": "UnauthorizedProvider","inputs": [] },
  { "type": "error", "name": "ZeroAddress",         "inputs": [] }
] as const;
