// Regenerated from out/LiquidityPool.sol/LiquidityPool.json
export const LiquidityPoolAbi = [
  { "type": "constructor", "inputs": [], "stateMutability": "nonpayable" },
  {
    "type": "function", "name": "activeLoanCount",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "activeLoanIds",
    "inputs": [{ "name": "", "type": "uint256" }],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "canFund",
    "inputs": [{ "name": "amount", "type": "uint256" }],
    "outputs": [{ "name": "", "type": "bool" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "collateralVault",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "defaultRecoveryCounted",
    "inputs": [{ "name": "", "type": "uint256" }],
    "outputs": [{ "name": "", "type": "bool" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "deposit",
    "inputs": [{ "name": "amount", "type": "uint256" }],
    "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "finalized",
    "inputs": [{ "name": "", "type": "uint256" }],
    "outputs": [{ "name": "", "type": "bool" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "fundLoan",
    "inputs": [
      { "name": "loanId", "type": "uint256" },
      { "name": "amount", "type": "uint256" }
    ],
    "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "idleLedger",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "initializedLiquidity",
    "inputs": [], "outputs": [{ "name": "", "type": "bool" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "loanRegistry",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "loanVault",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "maxActiveLoans",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "owner",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "principalAdvanced",
    "inputs": [{ "name": "", "type": "uint256" }],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "principalReturned",
    "inputs": [{ "name": "", "type": "uint256" }],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "proxiableUUID",
    "inputs": [], "outputs": [{ "name": "", "type": "bytes32" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "reconcileLoan",
    "inputs": [{ "name": "loanId", "type": "uint256" }],
    "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "reservePool",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "revenueRouter",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "setMaxActiveLoans",
    "inputs": [{ "name": "newMax", "type": "uint256" }],
    "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "sharePrice",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "sharesOf",
    "inputs": [{ "name": "", "type": "address" }],
    "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "sweepToken",
    "inputs": [
      { "name": "token", "type": "address" },
      { "name": "to",    "type": "address" }
    ],
    "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "function", "name": "totalAssets",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "totalDeployed",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "totalShares",
    "inputs": [], "outputs": [{ "name": "", "type": "uint256" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "underwriterPool",
    "inputs": [], "outputs": [{ "name": "", "type": "address" }],
    "stateMutability": "view"
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
    "type": "function", "name": "vaultSettlementCounted",
    "inputs": [{ "name": "", "type": "uint256" }],
    "outputs": [{ "name": "", "type": "bool" }],
    "stateMutability": "view"
  },
  {
    "type": "function", "name": "withdraw",
    "inputs": [{ "name": "sharesToBurn", "type": "uint256" }],
    "outputs": [], "stateMutability": "nonpayable"
  },
  {
    "type": "event", "name": "Deposited",
    "inputs": [
      { "name": "lender", "type": "address", "indexed": true  },
      { "name": "amount", "type": "uint256", "indexed": false },
      { "name": "shares", "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "LiquidityInitialized",
    "inputs": [
      { "name": "amount", "type": "uint256", "indexed": false },
      { "name": "shares", "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "LoanFundedFromPool",
    "inputs": [
      { "name": "loanId",  "type": "uint256", "indexed": true  },
      { "name": "amount",  "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "LoanReconciled",
    "inputs": [
      { "name": "loanId",          "type": "uint256", "indexed": true  },
      { "name": "delta",           "type": "uint256", "indexed": false },
      { "name": "principalPortion","type": "uint256", "indexed": false },
      { "name": "profitPortion",   "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "LoanWrittenOff",
    "inputs": [
      { "name": "loanId",     "type": "uint256", "indexed": true  },
      { "name": "lossAmount", "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  },
  {
    "type": "event", "name": "LoanFinalized",
    "inputs": [{ "name": "loanId", "type": "uint256", "indexed": true }],
    "anonymous": false
  },
  {
    "type": "event", "name": "Withdrawn",
    "inputs": [
      { "name": "lender", "type": "address", "indexed": true  },
      { "name": "shares", "type": "uint256", "indexed": false },
      { "name": "amount", "type": "uint256", "indexed": false }
    ],
    "anonymous": false
  },
  { "type": "error", "name": "AlreadyFunded",        "inputs": [] },
  { "type": "error", "name": "AlreadyInitialized",   "inputs": [] },
  { "type": "error", "name": "InsufficientLiquidity","inputs": [] },
  { "type": "error", "name": "InsufficientShares",   "inputs": [] },
  { "type": "error", "name": "NotInitialized",       "inputs": [] },
  { "type": "error", "name": "NotLoanVault",         "inputs": [] },
  { "type": "error", "name": "NoSharesOutstanding",  "inputs": [] },
  { "type": "error", "name": "ReentrantCall",        "inputs": [] },
  { "type": "error", "name": "TooManyActiveLoans",   "inputs": [] },
  { "type": "error", "name": "ZeroAddress",          "inputs": [] },
  { "type": "error", "name": "ZeroAmount",           "inputs": [] },
  { "type": "error", "name": "ZeroRecipient",        "inputs": [] },
  { "type": "error", "name": "ZeroToken",            "inputs": [] }
] as const;
