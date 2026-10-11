// Regenerated from out/CollateralVault.sol/CollateralVault.json (V3 multi-asset)
export const CollateralVaultAbi = [
  { "type": "constructor", "inputs": [], "stateMutability": "nonpayable" },
  {
    "type": "function", "name": "UPGRADE_INTERFACE_VERSION",
    "inputs": [], "outputs": [{ "name": "", "type": "string" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "assetConfigs",
    "inputs": [{ "name": "", "type": "address" }],
    "outputs": [
      { "name": "approved",     "type": "bool"    },
      { "name": "decimals",     "type": "uint8"   },
      { "name": "usdPriceE18", "type": "uint256"  }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "availableBalance",
    "inputs": [
      { "name": "borrower", "type": "address" },
      { "name": "asset",    "type": "address" }
    ],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "depositCollateral",
    "inputs": [
      { "name": "asset",  "type": "address" },
      { "name": "amount", "type": "uint256" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "initialize",
    "inputs": [
      { "name": "initialOwner", "type": "address" },
      { "name": "_usdc",        "type": "address" },
      { "name": "_registry",    "type": "address" },
      { "name": "_maxLTVBps",   "type": "uint16"  }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "maxLTVBps",
    "inputs": [], "outputs": [{ "name": "", "type": "uint16" }],
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
    "type": "function", "name": "registry",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "release",
    "inputs": [{ "name": "loanId", "type": "uint256" }],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "renounceOwnership",
    "inputs": [], "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "requiredCollateral",
    "inputs": [
      { "name": "principal", "type": "uint256" },
      { "name": "asset",     "type": "address" }
    ],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "reservations",
    "inputs": [{ "name": "loanId", "type": "uint256" }],
    "outputs": [
      { "name": "borrower",  "type": "address" },
      { "name": "asset",     "type": "address" },
      { "name": "amount",    "type": "uint256" },
      { "name": "resolved",  "type": "bool"    }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "reserveCollateral",
    "inputs": [
      { "name": "loanId",   "type": "uint256" },
      { "name": "borrower", "type": "address" },
      { "name": "asset",    "type": "address" },
      { "name": "amount",   "type": "uint256" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "seize",
    "inputs": [
      { "name": "loanId", "type": "uint256" },
      { "name": "lender", "type": "address" }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "setAssetConfig",
    "inputs": [
      { "name": "asset",        "type": "address" },
      { "name": "decimals",     "type": "uint8"   },
      { "name": "usdPriceE18", "type": "uint256"  }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
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
    "type": "function", "name": "usdc",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "withdrawCollateral",
    "inputs": [
      { "name": "asset",  "type": "address" },
      { "name": "amount", "type": "uint256" }
    ],
    "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "event", "name": "CollateralDeposited",
    "inputs": [
      { "name": "borrower", "type": "address", "indexed": true  },
      { "name": "asset",    "type": "address", "indexed": true  },
      { "name": "amount",   "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "Released",
    "inputs": [
      { "name": "loanId",   "type": "uint256", "indexed": true  },
      { "name": "borrower", "type": "address", "indexed": true  },
      { "name": "asset",    "type": "address", "indexed": true  },
      { "name": "amount",   "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "Reserved",
    "inputs": [
      { "name": "loanId",   "type": "uint256", "indexed": true  },
      { "name": "borrower", "type": "address", "indexed": true  },
      { "name": "asset",    "type": "address", "indexed": true  },
      { "name": "amount",   "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "Seized",
    "inputs": [
      { "name": "loanId",  "type": "uint256", "indexed": true  },
      { "name": "lender",  "type": "address", "indexed": true  },
      { "name": "asset",   "type": "address", "indexed": true  },
      { "name": "amount",  "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "Withdrawn",
    "inputs": [
      { "name": "borrower", "type": "address", "indexed": true  },
      { "name": "asset",    "type": "address", "indexed": true  },
      { "name": "amount",   "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  },
  { "type": "error", "name": "AlreadyReserved",              "inputs": [] },
  { "type": "error", "name": "AlreadyResolved",              "inputs": [] },
  { "type": "error", "name": "InsufficientAvailableBalance", "inputs": [] },
  { "type": "error", "name": "InsufficientCollateralForLTV", "inputs": [] },
  { "type": "error", "name": "NoReservation",                "inputs": [] },
  { "type": "error", "name": "NotRegistry",                  "inputs": [] },
  { "type": "error", "name": "PriceOutOfBounds",             "inputs": [] },
  { "type": "error", "name": "UnapprovedAsset",              "inputs": [] },
  { "type": "error", "name": "ZeroAddress",                  "inputs": [] },
  { "type": "error", "name": "ZeroAmount",                   "inputs": [] },
  { "type": "error", "name": "ZeroPrice",                    "inputs": [] }
] as const;
