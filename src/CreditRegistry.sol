// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ICreditRegistry} from "./interfaces/ICreditRegistry.sol";

/// @title CreditRegistry
/// @notice Tracks each agent's borrowing limit and grows/cuts it based on
///         repayment behavior. Deliberately minimal: no scoring model, no
///         collateral, no oracles — just a bounded step function.
contract CreditRegistry is Initializable, OwnableUpgradeable, UUPSUpgradeable, ICreditRegistry {
    uint256 private constant BPS_DENOMINATOR = 10000;

    struct AgentCredit {
        uint256 currentLimit;
        uint256 loansRepaid;
        uint256 loansDefaulted;
        bool exists;
    }

    mapping(address => AgentCredit) public credits;
    mapping(address => bool) public authorizedCallers;

    uint256 public initialLimit;
    uint16 public growthBps;
    uint16 public earlyBonusBps;
    uint256 public maxStepIncrease;
    uint16 public defaultPenaltyBps;
    uint256 public approvalThreshold;

    event LimitIncreased(address indexed agent, uint256 oldLimit, uint256 newLimit, bool early);
    event LimitDecreased(address indexed agent, uint256 oldLimit, uint256 newLimit, bool severe);
    event AuthorizedCallerSet(address indexed caller, bool allowed);
    event ParametersUpdated();

    error NotAuthorized();
    error ZeroAddress();

    modifier onlyAuthorized() {
        _onlyAuthorized();
        _;
    }

    function _onlyAuthorized() internal view {
        if (!authorizedCallers[msg.sender]) revert NotAuthorized();
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialOwner,
        uint256 _initialLimit,
        uint16 _growthBps,
        uint16 _earlyBonusBps,
        uint256 _maxStepIncrease,
        uint16 _defaultPenaltyBps,
        uint256 _approvalThreshold
    ) external initializer {
        __Ownable_init(initialOwner);
        initialLimit = _initialLimit;
        growthBps = _growthBps;
        earlyBonusBps = _earlyBonusBps;
        maxStepIncrease = _maxStepIncrease;
        defaultPenaltyBps = _defaultPenaltyBps;
        approvalThreshold = _approvalThreshold;
    }

    function setAuthorizedCaller(address caller, bool allowed) external onlyOwner {
        if (caller == address(0)) revert ZeroAddress();
        authorizedCallers[caller] = allowed;
        emit AuthorizedCallerSet(caller, allowed);
    }

    function setParameters(
        uint256 _initialLimit,
        uint16 _growthBps,
        uint16 _earlyBonusBps,
        uint256 _maxStepIncrease,
        uint16 _defaultPenaltyBps,
        uint256 _approvalThreshold
    ) external onlyOwner {
        initialLimit = _initialLimit;
        growthBps = _growthBps;
        earlyBonusBps = _earlyBonusBps;
        maxStepIncrease = _maxStepIncrease;
        defaultPenaltyBps = _defaultPenaltyBps;
        approvalThreshold = _approvalThreshold;
        emit ParametersUpdated();
    }

    function getLimit(address agent) external view returns (uint256) {
        AgentCredit storage credit = credits[agent];
        return credit.exists ? credit.currentLimit : initialLimit;
    }

    function requiresApproval(uint256 amount) external view returns (bool) {
        return amount > approvalThreshold;
    }

    function recordRepayment(address agent, uint256 repaidAmount, bool early) external onlyAuthorized {
        AgentCredit storage credit = credits[agent];
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
        credit.exists = true;
        credit.loansRepaid += 1;

        emit LimitIncreased(agent, oldLimit, newLimit, early);
    }

    function recordDefault(address agent, bool severe) external onlyAuthorized {
        AgentCredit storage credit = credits[agent];
        uint256 oldLimit = credit.exists ? credit.currentLimit : initialLimit;

        uint256 newLimit = severe ? 0 : (oldLimit * defaultPenaltyBps) / BPS_DENOMINATOR;
        credit.currentLimit = newLimit;
        credit.exists = true;
        credit.loansDefaulted += 1;

        emit LimitDecreased(agent, oldLimit, newLimit, severe);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}