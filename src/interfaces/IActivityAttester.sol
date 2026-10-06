// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IActivityAttester
/// @notice Interface for the ActivityAttester contract, which verifies ERC-8183
///         PaymentReleased events as evidence of external economic activity and
///         forwards verified activity amounts to the CreditRegistry.
interface IActivityAttester {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted when an activity source is added or removed from the whitelist.
    event ActivitySourceSet(address indexed source, bool approved);

    /// @notice Emitted when a valid activity attestation is recorded.
    /// @param agentId   The Valen agentId credited with the activity.
    /// @param source    The approved ERC-8183 contract that emitted PaymentReleased.
    /// @param jobId     The ERC-8183 jobId from the PaymentReleased event.
    /// @param providerWallet The provider address from the PaymentReleased event.
    /// @param amount    The net amount from the PaymentReleased event.
    /// @param evidenceKey keccak256(abi.encodePacked(source, jobId)) — replay-protection key.
    event ActivityAttested(
        uint256 indexed agentId,
        address indexed source,
        uint256 indexed jobId,
        address         providerWallet,
        uint256         amount,
        bytes32         evidenceKey
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice The activity source is not on the owner-controlled approved whitelist.
    error NotApprovedSource();

    /// @notice The providerWallet is not authorized for the given Valen agentId.
    error UnauthorizedProvider();

    /// @notice This (source, jobId) pair has already been attested.
    error AlreadyAttested();

    /// @notice A required address parameter was the zero address.
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Owner functions
    // -------------------------------------------------------------------------

    /// @notice Add or remove an ERC-8183-compatible contract from the approved source whitelist.
    /// @dev Only callable by the contract owner. Emits ActivitySourceSet.
    /// @param source   The contract address to approve or revoke.
    /// @param approved True to approve, false to remove.
    function setActivitySource(address source, bool approved) external;

    // -------------------------------------------------------------------------
    // Core attestation
    // -------------------------------------------------------------------------

    /// @notice Attest a verified ERC-8183 PaymentReleased activity event.
    ///
    /// @dev Validation order (all must pass before state is written):
    ///      1. source is in approvedActivitySources
    ///      2. providerWallet is authorized for agentId in AgentRegistry
    ///      3. evidenceKey (keccak256(source, jobId)) has not been attested before
    ///
    ///      On success:
    ///      - Sets attestedActivity[evidenceKey] = true
    ///      - Calls creditRegistry.recordActivity(agentId, amount)
    ///      - Emits ActivityAttested
    ///
    ///      Does NOT revert if CreditRegistry's activityLimit is already at maxActivityLimit.
    ///      The attestation is recorded and activityAttested still grows.
    ///
    /// @param source         The approved ERC-8183 contract address (must be whitelisted).
    /// @param jobId          The ERC-8183 jobId from the PaymentReleased event.
    /// @param agentId        The Valen agentId to credit.
    /// @param providerWallet The provider address from the PaymentReleased event.
    /// @param amount         The net payment amount from the PaymentReleased event.
    function attestActivity(
        address source,
        uint256 jobId,
        uint256 agentId,
        address providerWallet,
        uint256 amount
    ) external;
}
