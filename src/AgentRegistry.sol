// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAgentRegistry} from "./interfaces/IAgentRegistry.sol";

/// @title AgentRegistry
/// @notice Valen's authoritative agent identity store.
///
///         Each Valen agent has a persistent `agentId` (Valen's own credit
///         identity) and a set of authorized wallets. Wallet rotation is
///         supported: wallets can be added or removed without affecting the
///         agent's credit or debt history, which is keyed to `agentId`.
///
///         An ERC-8004 token ID may be stored as an informational external
///         reference. It carries no trust or authorization in Valen — Valen
///         does not delegate wallet authorization or credit ownership to
///         ERC-8004. Valen agentId is distinct from ERC-8004 agentId.
///
///         One wallet may be authorized for at most one agentId at a time.
///         This prevents a wallet from accumulating credit against multiple
///         agent identities.
contract AgentRegistry is Initializable, OwnableUpgradeable, UUPSUpgradeable, IAgentRegistry {

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Auto-incrementing Valen agentId counter. nextAgentId is the
    ///         next ID that will be assigned; IDs start at 1.
    uint256 public nextAgentId;

    /// @notice The controlling owner address for each agentId.
    ///         The agent owner can add/remove wallets and transfer ownership.
    ///         This is distinct from the contract owner (Valen protocol admin).
    mapping(uint256 => address) public agentOwner;

    /// @notice agentId → wallet → authorized.
    mapping(uint256 => mapping(address => bool)) private _authorizedWallets;

    /// @notice Reverse lookup: wallet → agentId it is authorized under.
    ///         Returns 0 for unregistered wallets.
    ///         Enforces the one-wallet-per-agent constraint at addWallet time.
    mapping(address => uint256) public walletToAgent;

    /// @notice Stores an informational ERC-8004 external token ID reference
    ///         for each agentId. Not used in any Valen authorization logic.
    mapping(uint256 => uint256) public erc8004Ref;

    /// @notice Tracks the number of authorized wallets per agentId so that
    ///         removeWallet can enforce the minimum-one-wallet invariant
    ///         without iterating.
    mapping(uint256 => uint256) private _walletCount;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event AgentRegistered(uint256 indexed agentId, address indexed owner, uint256 erc8004TokenId);
    event WalletAdded(uint256 indexed agentId, address indexed wallet);
    event WalletRemoved(uint256 indexed agentId, address indexed wallet);
    event AgentOwnershipTransferred(
        uint256 indexed agentId,
        address indexed oldOwner,
        address indexed newOwner
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error WalletAlreadyRegistered();
    error CannotRemoveLastWallet();
    error NotAgentOwner();
    error ZeroAddress();
    error AgentDoesNotExist();
    error WalletNotAuthorized();

    // -------------------------------------------------------------------------
    // Constructor / initializer
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner) external initializer {
        if (initialOwner == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        nextAgentId = 1; // agentId 0 is reserved as "not registered"
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyAgentOwner(uint256 agentId) {
        if (agentOwner[agentId] == address(0)) revert AgentDoesNotExist();
        if (msg.sender != agentOwner[agentId]) revert NotAgentOwner();
        _;
    }

    // -------------------------------------------------------------------------
    // IAgentRegistry implementation
    // -------------------------------------------------------------------------

    /// @inheritdoc IAgentRegistry
    /// @dev msg.sender becomes the agent owner and first authorized wallet.
    ///      Reverts if msg.sender is already registered to any agentId.
    function registerAgent(uint256 erc8004TokenId) external returns (uint256 agentId) {
        if (walletToAgent[msg.sender] != 0) revert WalletAlreadyRegistered();

        agentId = nextAgentId++;
        agentOwner[agentId]                    = msg.sender;
        _authorizedWallets[agentId][msg.sender] = true;
        walletToAgent[msg.sender]               = agentId;
        _walletCount[agentId]                   = 1;

        if (erc8004TokenId != 0) {
            erc8004Ref[agentId] = erc8004TokenId;
        }

        emit AgentRegistered(agentId, msg.sender, erc8004TokenId);
    }

    /// @inheritdoc IAgentRegistry
    /// @dev Only the agent owner may add wallets. A wallet may only be
    ///      authorized for one agentId — reverts if already registered.
    function addWallet(uint256 agentId, address wallet) external onlyAgentOwner(agentId) {
        if (wallet == address(0)) revert ZeroAddress();
        if (walletToAgent[wallet] != 0) revert WalletAlreadyRegistered();

        _authorizedWallets[agentId][wallet] = true;
        walletToAgent[wallet]               = agentId;
        _walletCount[agentId]              += 1;

        emit WalletAdded(agentId, wallet);
    }

    /// @inheritdoc IAgentRegistry
    /// @dev Cannot remove the last remaining authorized wallet.
    function removeWallet(uint256 agentId, address wallet) external onlyAgentOwner(agentId) {
        if (wallet == address(0)) revert ZeroAddress();
        if (!_authorizedWallets[agentId][wallet]) revert WalletNotAuthorized();
        if (_walletCount[agentId] <= 1) revert CannotRemoveLastWallet();

        _authorizedWallets[agentId][wallet] = false;
        walletToAgent[wallet]               = 0;
        _walletCount[agentId]              -= 1;

        emit WalletRemoved(agentId, wallet);
    }

    /// @inheritdoc IAgentRegistry
    function isAuthorizedWallet(uint256 agentId, address wallet) external view returns (bool) {
        return _authorizedWallets[agentId][wallet];
    }

    /// @inheritdoc IAgentRegistry
    function getAgentId(address wallet) external view returns (uint256) {
        return walletToAgent[wallet];
    }

    /// @inheritdoc IAgentRegistry
    /// @dev Does not affect wallet authorizations. Only the current agent
    ///      owner may call this. The new owner does not need to hold a wallet
    ///      authorized for this agentId (ownership and wallet authorization
    ///      are separate concepts).
    function transferAgentOwnership(uint256 agentId, address newOwner)
        external
        onlyAgentOwner(agentId)
    {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = agentOwner[agentId];
        agentOwner[agentId] = newOwner;
        emit AgentOwnershipTransferred(agentId, oldOwner, newOwner);
    }

    // -------------------------------------------------------------------------
    // View helpers
    // -------------------------------------------------------------------------

    /// @notice Returns the number of authorized wallets for an agentId.
    function walletCount(uint256 agentId) external view returns (uint256) {
        return _walletCount[agentId];
    }

    // -------------------------------------------------------------------------
    // UUPS
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
