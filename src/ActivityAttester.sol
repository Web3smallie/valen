// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable}     from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable}   from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IActivityAttester} from "./interfaces/IActivityAttester.sol";
import {IAgentRegistry}    from "./interfaces/IAgentRegistry.sol";
import {ICreditRegistry}   from "./interfaces/ICreditRegistry.sol";

/// @title ActivityAttester
/// @notice Verifies ERC-8183 PaymentReleased events as evidence of external economic
///         activity and forwards verified amounts to CreditRegistry.recordActivity(agentId, amount).
///
/// @dev Trust model:
///      - Only contract-owner-approved source addresses may provide activity evidence.
///      - The providerWallet in a PaymentReleased event must be authorized for the
///        Valen agentId in AgentRegistry. Valen does not manufacture economic history.
///      - Each (source, jobId) pair may be attested exactly once (replay protection).
///      - Reaching the CreditRegistry activityLimit cap does NOT revert an attestation.
///        activityAttested continues to grow as a permanent historical record.
///
///      Evidence key: keccak256(abi.encodePacked(source, jobId))
///      This is sufficient because a given jobId on a given ERC-8183 source contract
///      produces exactly one PaymentReleased event.
contract ActivityAttester is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IActivityAttester
{
    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice Owner-controlled whitelist of approved ERC-8183 source contracts.
    mapping(address => bool)  public approvedActivitySources;

    /// @notice Replay-protection map. True when a (source, jobId) has been attested.
    mapping(bytes32 => bool)  public attestedActivity;

    /// @notice The Valen AgentRegistry used to verify wallet authorization.
    IAgentRegistry public agentRegistry;

    /// @notice The CreditRegistry that receives verified activity amounts.
    ICreditRegistry public creditRegistry;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // -------------------------------------------------------------------------
    // Initializer
    // -------------------------------------------------------------------------

    /// @notice Initialize the proxy.
    /// @param initialOwner   Contract owner (can set sources, upgrade).
    /// @param _agentRegistry Valen AgentRegistry address.
    /// @param _creditRegistry Valen CreditRegistry address.
    function initialize(
        address initialOwner,
        address _agentRegistry,
        address _creditRegistry
    ) external initializer {
        if (_agentRegistry  == address(0)) revert ZeroAddress();
        if (_creditRegistry == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        agentRegistry  = IAgentRegistry(_agentRegistry);
        creditRegistry = ICreditRegistry(_creditRegistry);
    }

    // -------------------------------------------------------------------------
    // Owner: activity source management
    // -------------------------------------------------------------------------

    /// @inheritdoc IActivityAttester
    function setActivitySource(address source, bool approved) external onlyOwner {
        if (source == address(0)) revert ZeroAddress();
        approvedActivitySources[source] = approved;
        emit ActivitySourceSet(source, approved);
    }

    // -------------------------------------------------------------------------
    // Core attestation
    // -------------------------------------------------------------------------

    /// @inheritdoc IActivityAttester
    function attestActivity(
        address source,
        uint256 jobId,
        uint256 agentId,
        address providerWallet,
        uint256 amount
    ) external {
        // 1. Source must be on the approved whitelist.
        if (!approvedActivitySources[source]) revert NotApprovedSource();

        // 2. providerWallet must be authorized for agentId in AgentRegistry.
        if (!agentRegistry.isAuthorizedWallet(agentId, providerWallet)) revert UnauthorizedProvider();

        // 3. Replay protection: each (source, jobId) pair may be attested exactly once.
        bytes32 evidenceKey = keccak256(abi.encodePacked(source, jobId));
        if (attestedActivity[evidenceKey]) revert AlreadyAttested();

        // Write state before external call (CEI pattern).
        attestedActivity[evidenceKey] = true;

        // Forward verified activity to CreditRegistry.
        // Does not revert when activityLimit is at maxActivityLimit — the ceiling
        // is handled silently by CreditRegistry; activityAttested still grows.
        creditRegistry.recordActivity(agentId, amount);

        emit ActivityAttested(agentId, source, jobId, providerWallet, amount, evidenceKey);
    }

    // -------------------------------------------------------------------------
    // UUPS
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
