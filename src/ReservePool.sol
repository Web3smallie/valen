// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ILoanRegistry} from "./interfaces/ILoanRegistry.sol";
import {IReservePool} from "./interfaces/IReservePool.sol";

contract ReservePool is Initializable, OwnableUpgradeable, UUPSUpgradeable, IReservePool {
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    ILoanRegistry public registry;

    mapping(address => bool) public authorizedContributors;

    uint256 public totalContributed;
    uint256 public totalPaidOut;
    mapping(uint256 => uint256) public loanPayout; // NEW — per-loan payout, so LiquidityPool can attribute recovery precisely

    event ContributionRecorded(uint256 indexed loanId, address indexed from, uint256 amount);
    event PayoutMade(uint256 indexed loanId, address indexed lender, uint256 requested, uint256 paid);
    event AuthorizedContributorSet(address indexed contributor, bool allowed);

    error ZeroAddress();
    error NotAuthorizedContributor();
    error NotRegistry();

    modifier onlyAuthorizedContributor() {
        if (!authorizedContributors[msg.sender]) revert NotAuthorizedContributor();
        _;
    }

    modifier onlyRegistry() {
        if (msg.sender != address(registry)) revert NotRegistry();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address initialOwner, address _usdc, address _registry) external initializer {
        if (_usdc == address(0) || _registry == address(0)) revert ZeroAddress();
        __Ownable_init(initialOwner);
        usdc = IERC20(_usdc);
        registry = ILoanRegistry(_registry);
    }

    function setAuthorizedContributor(address contributor, bool allowed) external onlyOwner {
        if (contributor == address(0)) revert ZeroAddress();
        authorizedContributors[contributor] = allowed;
        emit AuthorizedContributorSet(contributor, allowed);
    }

    function recordContribution(uint256 loanId, uint256 amount) external onlyAuthorizedContributor {
        totalContributed += amount;
        emit ContributionRecorded(loanId, msg.sender, amount);
    }

    function payout(uint256 loanId, address lender, uint256 shortfall) external onlyRegistry returns (uint256 paid) {
        uint256 available = usdc.balanceOf(address(this));
        paid = shortfall > available ? available : shortfall;
        if (paid > 0) {
            totalPaidOut += paid;
            loanPayout[loanId] += paid; // NEW
            usdc.safeTransfer(lender, paid);
        }
        emit PayoutMade(loanId, lender, shortfall, paid);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}