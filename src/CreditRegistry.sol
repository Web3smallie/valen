// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable}      from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable}    from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ICreditRegistry}    from "./interfaces/ICreditRegistry.sol";

/// @title CreditRegistry
/// @notice Tracks each agent's borrowing capacity across two independent credit tracks:
///         - currentLimit: earned through Valen loan repayment performance.
///         - activityLimit: earned through verified external economic activity (ERC-8183).
///
///         Available credit = currentLimit + activityLimit.
///
///         All credit state is keyed by uint256 agentId. Step 5 completes the
///         identity migration: all three write paths (recordRepayment, recordDefault,
///         recordActivity) now use uint256 agentId as the authoritative key.
///
/// @dev Fresh V1 deployment only. No migration path for legacy address-keyed records.
///      Storage layout documented in contracts/storage-snapshots/CreditRegistry.json.
contract CreditRegistry is Initializable, OwnableUpgradeable, UUPSUpgradeable, ICreditRegistry {
    uint256 private constant BPS_DENOMINATOR = 10_000;

    // -------------------------------------------------------------------------
    // Storage: AgentCredit
    // -------------------------------------------------------------------------

    /// @notice Per-agent credit record, keyed by uint256 agentId.
    struct AgentCredit {
        // --- Repayment track ---
        /// @notice Credit capacity earned through Valen loan repayment performance.
        uint256 currentLimit;
        /// @notice Count of successfully repaid Valen loans.
        uint256 loansRepaid;
        /// @notice Count of defaults (severe and non-severe combined).
        uint256 loansDefaulted;
        /// @notice True once any record has been written for this agentId.
        bool    exists;

        // --- Activity track ---
        /// @notice Current activity-derived credit capacity.
        ///         Capped at maxActivityLimit. Reset to 0 on severe default.
        ///         Rebuilt from 0 via new attestations after a severe default.
        uint256 activityLimit;
        /// @notice Permanent cumulative lifetime verified economic activity amount.
        ///         Never reset — not by defaults, not by any protocol rule.
        uint256 activityAttested;
    }

    /// @notice Credit records keyed by Valen agentId (uint256).
    mapping(uint256 => AgentCredit) public credits;

    // -------------------------------------------------------------------------
    // Storage: access control
    // -------------------------------------------------------------------------

    /// @notice Addresses permitted to call recordRepayment, recordDefault, recordActivity.
    mapping(address => bool) public authorizedCallers;

    // -------------------------------------------------------------------------
    // Storage: repayment-track parameters
    // -------------------------------------------------------------------------

    uint256 public initialLimit;
    uint16  public growthBps;
    uint16  public earlyBonusBps;
    uint256 public maxStepIncrease;
    uint16  public defaultPenaltyBps;
    uint256 public approvalThreshold;

    // -------------------------------------------------------------------------
    // Storage: activity-track parameters
    // -------------------------------------------------------------------------

    uint16  public activityGrowthBps;
    uint256 public maxActivityIncreasePerEvent;
    uint256 public maxActivityLimit;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event LimitIncreased(uint256 indexed agentId, uint256 oldLimit, uint256 newLimit, bool early);
    event LimitDecreased(uint256 indexed agentId, uint256 oldLimit, uint256 newLimit, bool severe);
    event ActivityRecorded(
        uint256 indexed agentId,
        uint256 oldActivityLimit,
        uint256 newActivityLimit,
        uint256 amount,
        uint256 creditIncrease
    );
    event AuthorizedCallerSet(address indexed caller, bool allowed);
    event ParametersUpdated();

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error NotAuthorized();
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Access control
    // -------------------------------------------------------------------------

    modifier onlyAuthorized() {
        _onlyAuthorized();
        _;
    }

    function _onlyAuthorized() internal view {
        if (!authorizedCallers[msg.sender]) revert NotAuthorized();
    }

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

    function initialize(
        address initialOwner,
        uint256 _initialLimit,
        uint16  _growthBps,
        uint16  _earlyBonusBps,
        uint256 _maxStepIncrease,
        uint16  _defaultPenaltyBps,
        uint256 _approvalThreshold,
        uint16  _activityGrowthBps,
        uint256 _maxActivityIncreasePerEvent,
        uint256 _maxActivityLimit
    ) external initializer {
        __Ownable_init(initialOwner);
        initialLimit              = _initialLimit;
        growthBps                 = _growthBps;
        earlyBonusBps             = _earlyBonusBps;
        maxStepIncrease           = _maxStepIncrease;
        defaultPenaltyBps         = _defaultPenaltyBps;
        approvalThreshold         = _approvalThreshold;
        activityGrowthBps         = _activityGrowthBps;
        maxActivityIncreasePerEvent = _maxActivityIncreasePerEvent;
        maxActivityLimit          = _maxActivityLimit;
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    function setAuthorizedCaller(address caller, bool allowed) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();
        authorizedCallers[caller] = allowed;
        emit AuthorizedCallerSet(caller, allowed);
    }

    function setParameters(
        uint256 _initialLimit,
        uint16  _growthBps,
        uint16  _earlyBonusBps,
        uint256 _maxStepIncrease,
        uint16  _defaultPenaltyBps,
        uint256 _approvalThreshold,
        uint16  _activityGrowthBps,
        uint256 _maxActivityIncreasePerEvent,
        uint256 _maxActivityLimit
    ) external onlyOwner {
        initialLimit              = _initialLimit;
        growthBps                 = _growthBps;
        earlyBonusBps             = _earlyBonusBps;
        maxStepIncrease           = _maxStepIncrease;
        defaultPenaltyBps         = _defaultPenaltyBps;
        approvalThreshold         = _approvalThreshold;
        activityGrowthBps         = _activityGrowthBps;
        maxActivityIncreasePerEvent = _maxActivityIncreasePerEvent;
        maxActivityLimit          = _maxActivityLimit;
        emit ParametersUpdated();
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    /// @notice Returns available credit = currentLimit + activityLimit.
    /// @param  agentId Valen agentId — Step 4 final signature.
    function getLimit(uint256 agentId) external view returns (uint256) {
        AgentCredit storage credit = credits[agentId];
        uint256 base = credit.exists ? credit.currentLimit : initialLimit;
        return base + credit.activityLimit;
    }

    function requiresApproval(uint256 amount) external view returns (bool) {
        return amount > approvalThreshold;
    }

    // -------------------------------------------------------------------------
    // Repayment track
    // -------------------------------------------------------------------------

    /// @notice Records a successful Valen loan repayment, growing currentLimit.
    /// @param  agentId      Valen agentId — authoritative credit identity key.
    /// @param  repaidAmount Total principal+interest amount repaid on this loan.
    /// @param  early        True if repaid before the loan's expiresAt timestamp.
    function recordRepayment(uint256 agentId, uint256 repaidAmount, bool early)
        external
        onlyAuthorized
    {
        AgentCredit storage credit = credits[agentId];
        uint256 oldLimit = credit.exists ? credit.currentLimit : initialLimit;

        uint256 increase = (repaidAmount * growthBps) / BPS_DENOMINATOR;
        if (early) {
            increase += (repaidAmount * earlyBonusBps) / BPS_DENOMINATOR;
        }
        if (increase > maxStepIncrease) {
            increase = maxStepIncrease;
        }

        uint256 newLimit = oldLimit + increase;
        credit.currentLimit = newLimit;
        credit.exists       = true;
        credit.loansRepaid += 1;

        emit LimitIncreased(agentId, oldLimit, newLimit, early);
    }

    // -------------------------------------------------------------------------
    // Default track
    // -------------------------------------------------------------------------

    /// @notice Records a default against the agent identified by agentId.
    ///         severe=true resets both currentLimit and activityLimit to 0.
    ///         severe=false applies defaultPenaltyBps reduction to currentLimit only.
    ///         activityAttested, loansRepaid history are never reset.
    /// @param agentId Valen agentId — Step 4 final signature.
    function recordDefault(uint256 agentId, bool severe) external onlyAuthorized {
        AgentCredit storage credit = credits[agentId];
        uint256 oldLimit = credit.exists ? credit.currentLimit : initialLimit;

        if (severe) {
            credit.currentLimit  = 0;
            credit.activityLimit = 0;
        } else {
            credit.currentLimit = (oldLimit * defaultPenaltyBps) / BPS_DENOMINATOR;
        }

        credit.exists         = true;
        credit.loansDefaulted += 1;

        emit LimitDecreased(agentId, oldLimit, credit.currentLimit, severe);
    }

    // -------------------------------------------------------------------------
    // Activity track
    // -------------------------------------------------------------------------

    /// @param agentId Valen agentId (uint256) — final V1 identity key.
    /// @param amount  Verified activity amount from ERC-8183 PaymentReleased.
    function recordActivity(uint256 agentId, uint256 amount) external onlyAuthorized {
        AgentCredit storage credit = credits[agentId];

        uint256 rawIncrease    = (amount * activityGrowthBps) / BPS_DENOMINATOR;
        uint256 cappedIncrease = rawIncrease > maxActivityIncreasePerEvent
            ? maxActivityIncreasePerEvent
            : rawIncrease;

        uint256 headroom = maxActivityLimit > credit.activityLimit
            ? maxActivityLimit - credit.activityLimit
            : 0;
        uint256 finalIncrease = cappedIncrease > headroom ? headroom : cappedIncrease;

        uint256 oldActivityLimit = credit.activityLimit;

        // Initialise currentLimit to the protocol floor the first time this
        // agentId is touched, so getLimit() = initialLimit + activityLimit
        // rather than 0 + activityLimit after the first activity attestation.
        if (!credit.exists) {
            credit.currentLimit = initialLimit;
        }

        credit.activityLimit    += finalIncrease;
        credit.activityAttested += amount;
        credit.exists            = true;

        emit ActivityRecorded(agentId, oldActivityLimit, credit.activityLimit, amount, finalIncrease);
    }

    // -------------------------------------------------------------------------
    // UUPS
    // -------------------------------------------------------------------------

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
