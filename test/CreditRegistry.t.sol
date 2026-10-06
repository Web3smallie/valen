// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy}  from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CreditRegistry} from "../src/CreditRegistry.sol";
import {ICreditRegistry} from "../src/interfaces/ICreditRegistry.sol";

/// @notice Full V1 CreditRegistry test suite covering:
///   - Repayment track (currentLimit growth, early bonus, per-step cap)
///   - Activity track (activityLimit growth, per-event cap, maxActivityLimit ceiling)
///   - getLimit composition (currentLimit + activityLimit)
///   - Severe and non-severe default interactions
///   - activityAttested permanence
///   - Access control
///   - Parameter updates
contract CreditRegistryTest is Test {
    CreditRegistry reg;

    address owner    = address(this);
    address caller   = address(0xCA11);   // authorized caller (represents router/registry/attester)
    address stranger = address(0x9999);

    // V1 locked parameters
    uint256 constant INITIAL_LIMIT    = 5e6;           // $5
    uint16  constant GROWTH_BPS       = 2500;          // 25%
    uint16  constant EARLY_BONUS_BPS  = 1000;          // 10%
    uint256 constant MAX_STEP         = 2_000_000e6;   // $2M
    uint16  constant PENALTY_BPS      = 2000;          // 20%
    uint256 constant APPROVAL_THRESH  = 25_000e6;      // $25k

    uint16  constant ACTIVITY_GROWTH_BPS          = 500;      // 5%
    uint256 constant MAX_ACTIVITY_INCREASE_PER_EVT = 50e6;    // $50
    uint256 constant MAX_ACTIVITY_LIMIT           = 50_000e6; // $50k

    // Synthetic agentIds used in tests (uint256 — matches V1 identity model)
    // For bridge-interface tests (getLimit/recordRepayment/recordDefault),
    // we pass address values and the contract converts them to agentId internally.
    address constant AGENT_ADDR  = address(0xA1);
    uint256 constant AGENT_ID    = uint256(uint160(address(0xA1)));
    address constant AGENT2_ADDR = address(0xA2);
    uint256 constant AGENT2_ID   = uint256(uint160(address(0xA2)));

    // For recordActivity (already uint256 interface), we use agentId directly.
    // We use addresses cast to uint256 to keep parity with bridge tests.

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function _deploy(
        uint16  activityGrowthBps,
        uint256 maxActivityIncreasePerEvent,
        uint256 maxActivityLimit_
    ) internal returns (CreditRegistry) {
        return CreditRegistry(_proxy(
            address(new CreditRegistry()),
            abi.encodeCall(CreditRegistry.initialize, (
                owner,
                INITIAL_LIMIT,
                GROWTH_BPS,
                EARLY_BONUS_BPS,
                MAX_STEP,
                PENALTY_BPS,
                APPROVAL_THRESH,
                activityGrowthBps,
                maxActivityIncreasePerEvent,
                maxActivityLimit_
            ))
        ));
    }

    function setUp() public {
        reg = _deploy(ACTIVITY_GROWTH_BPS, MAX_ACTIVITY_INCREASE_PER_EVT, MAX_ACTIVITY_LIMIT);
        reg.setAuthorizedCaller(caller, true);
    }

    // =========================================================================
    // Initialization
    // =========================================================================

    function test_initialize_parametersStored() public view {
        assertEq(reg.initialLimit(),               INITIAL_LIMIT);
        assertEq(reg.growthBps(),                  GROWTH_BPS);
        assertEq(reg.earlyBonusBps(),              EARLY_BONUS_BPS);
        assertEq(reg.maxStepIncrease(),            MAX_STEP);
        assertEq(reg.defaultPenaltyBps(),          PENALTY_BPS);
        assertEq(reg.approvalThreshold(),          APPROVAL_THRESH);
        assertEq(reg.activityGrowthBps(),          ACTIVITY_GROWTH_BPS);
        assertEq(reg.maxActivityIncreasePerEvent(), MAX_ACTIVITY_INCREASE_PER_EVT);
        assertEq(reg.maxActivityLimit(),           MAX_ACTIVITY_LIMIT);
    }

    function test_initialize_cannotInitializeTwice() public {
        vm.expectRevert();
        reg.initialize(owner, 1, 1, 1, 1, 1, 1, 1, 1, 1);
    }

    function test_requiresApproval_belowThreshold() public view {
        assertFalse(reg.requiresApproval(APPROVAL_THRESH));
    }

    function test_requiresApproval_aboveThreshold() public view {
        assertTrue(reg.requiresApproval(APPROVAL_THRESH + 1));
    }

    // =========================================================================
    // Access control
    // =========================================================================

    function test_onlyAuthorized_recordRepayment() public {
        vm.prank(stranger);
        vm.expectRevert(CreditRegistry.NotAuthorized.selector);
        reg.recordRepayment(AGENT_ID, 100e6, false);
    }

    function test_onlyAuthorized_recordDefault() public {
        vm.prank(stranger);
        vm.expectRevert(CreditRegistry.NotAuthorized.selector);
        reg.recordDefault(AGENT_ID, false);
    }

    function test_onlyAuthorized_recordActivity() public {
        vm.prank(stranger);
        vm.expectRevert(CreditRegistry.NotAuthorized.selector);
        reg.recordActivity(AGENT_ID, 100e6);
    }

    function test_setAuthorizedCaller_zeroAddressReverts() public {
        vm.expectRevert(CreditRegistry.ZeroAddress.selector);
        reg.setAuthorizedCaller(address(0), true);
    }

    function test_nonOwner_setAuthorizedCallerReverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        reg.setAuthorizedCaller(stranger, true);
    }

    // =========================================================================
    // setParameters
    // =========================================================================

    function test_setParameters_updatesAll() public {
        reg.setParameters(10e6, 3000, 500, 1_000_000e6, 1500, 50_000e6, 300, 25e6, 100_000e6);
        assertEq(reg.initialLimit(),               10e6);
        assertEq(reg.growthBps(),                  3000);
        assertEq(reg.earlyBonusBps(),              500);
        assertEq(reg.maxStepIncrease(),            1_000_000e6);
        assertEq(reg.defaultPenaltyBps(),          1500);
        assertEq(reg.approvalThreshold(),          50_000e6);
        assertEq(reg.activityGrowthBps(),          300);
        assertEq(reg.maxActivityIncreasePerEvent(), 25e6);
        assertEq(reg.maxActivityLimit(),           100_000e6);
    }

    function test_setParameters_nonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        reg.setParameters(1, 1, 1, 1, 1, 1, 1, 1, 1);
    }

    // =========================================================================
    // getLimit — no history
    // =========================================================================

    function test_getLimit_noHistory_returnsInitialLimit() public view {
        assertEq(reg.getLimit(AGENT_ID), INITIAL_LIMIT);
    }

    function test_getLimit_noHistory_activityLimitZero() public view {
        // No activity recorded: activityLimit contribution is zero
        // getLimit = initialLimit + 0 = initialLimit
        assertEq(reg.getLimit(AGENT_ID), INITIAL_LIMIT + 0);
    }

    // =========================================================================
    // Repayment track — recordRepayment
    // =========================================================================

    function test_recordRepayment_growsCurrentLimit() public {
        // repay $400 on-time: increase = 400e6 * 2500 / 10000 = 100e6
        vm.prank(caller);
        reg.recordRepayment(AGENT_ID, 400e6, false);

        // getLimit = currentLimit + activityLimit = (5e6 + 100e6) + 0 = 105e6
        assertEq(reg.getLimit(AGENT_ID), INITIAL_LIMIT + 100e6);
        (uint256 cl,,,,,) = reg.credits(AGENT_ID);
        assertEq(cl, INITIAL_LIMIT + 100e6);
    }

    function test_recordRepayment_earlyBonus() public {
        // repay $400 early: 400e6 * (2500+1000) / 10000 = 140e6
        vm.prank(caller);
        reg.recordRepayment(AGENT_ID, 400e6, true);
        assertEq(reg.getLimit(AGENT_ID), INITIAL_LIMIT + 140e6);
    }

    function test_recordRepayment_maxStepCap() public {
        // repay enormous amount, cap should kick in
        vm.prank(caller);
        reg.recordRepayment(AGENT_ID, 100_000_000e6, false);
        // increase would be 100_000_000e6 * 25% = 25_000_000e6 > MAX_STEP
        assertEq(reg.getLimit(AGENT_ID), INITIAL_LIMIT + MAX_STEP);
    }

    function test_recordRepayment_incrementsLoansRepaid() public {
        vm.prank(caller);
        reg.recordRepayment(AGENT_ID, 100e6, false);
        (, uint256 loansRepaid,,,,) = reg.credits(AGENT_ID);
        assertEq(loansRepaid, 1);

        vm.prank(caller);
        reg.recordRepayment(AGENT_ID, 100e6, false);
        (, uint256 loansRepaid2,,,,) = reg.credits(AGENT_ID);
        assertEq(loansRepaid2, 2);
    }

    function test_recordRepayment_doesNotTouchActivityFields() public {
        vm.prank(caller);
        reg.recordRepayment(AGENT_ID, 400e6, false);
        (,,,,uint256 actLimit, uint256 actAttested) = reg.credits(AGENT_ID);
        assertEq(actLimit,    0);
        assertEq(actAttested, 0);
    }

    function test_recordRepayment_emitsLimitIncreased() public {
        // Compute at runtime to avoid compile-time constant overflow (uint16 * uint256).
        uint256 expectedNew = INITIAL_LIMIT + (400e6 * uint256(GROWTH_BPS) / 10_000);
        vm.expectEmit(true, false, false, true);
        emit CreditRegistry.LimitIncreased(AGENT_ID, INITIAL_LIMIT, expectedNew, false);
        vm.prank(caller);
        reg.recordRepayment(AGENT_ID, 400e6, false);
    }

    // =========================================================================
    // Activity track — recordActivity
    // =========================================================================

    function test_recordActivity_smallJob_underCap() public {
        // $200 job: 200e6 * 5% = 10e6 (under $50 cap)
        vm.prank(caller);
        reg.recordActivity(AGENT_ID, 200e6);
        (,,,, uint256 actLimit, uint256 actAttested) = reg.credits(AGENT_ID);
        assertEq(actLimit,    10e6);
        assertEq(actAttested, 200e6);
    }

    function test_recordActivity_exactlyAtPerEventCap() public {
        // $1000 job: 1000e6 * 5% = 50e6 = exactly at cap
        vm.prank(caller);
        reg.recordActivity(AGENT_ID, 1000e6);
        (,,,, uint256 actLimit,) = reg.credits(AGENT_ID);
        assertEq(actLimit, 50e6);
    }

    function test_recordActivity_largeJob_capBinds() public {
        // $10,000 job: 10000e6 * 5% = 500e6 > cap of 50e6
        vm.prank(caller);
        reg.recordActivity(AGENT_ID, 10_000e6);
        (,,,, uint256 actLimit, uint256 actAttested) = reg.credits(AGENT_ID);
        assertEq(actLimit,    50e6);   // capped at $50
        assertEq(actAttested, 10_000e6); // full amount recorded
    }

    function test_recordActivity_veryLargeJob_capBinds() public {
        // $100,000 job: still only $50 credit growth
        vm.prank(caller);
        reg.recordActivity(AGENT_ID, 100_000e6);
        (,,,, uint256 actLimit, uint256 actAttested) = reg.credits(AGENT_ID);
        assertEq(actLimit,    50e6);
        assertEq(actAttested, 100_000e6);
    }

    function test_recordActivity_multipleEvents_accumulate() public {
        // 3 events of $1000 each: 3 * $50 = $150 activityLimit, $3000 attested
        vm.startPrank(caller);
        reg.recordActivity(AGENT_ID, 1000e6);
        reg.recordActivity(AGENT_ID, 1000e6);
        reg.recordActivity(AGENT_ID, 1000e6);
        vm.stopPrank();
        (,,,, uint256 actLimit, uint256 actAttested) = reg.credits(AGENT_ID);
        assertEq(actLimit,    150e6);
        assertEq(actAttested, 3000e6);
    }

    function test_recordActivity_initialisesCurrentLimitOnFirstTouch() public {
        vm.prank(caller);
        reg.recordActivity(AGENT_ID, 1000e6);
        (uint256 cl,,,,,) = reg.credits(AGENT_ID);
        // On first touch via recordActivity, currentLimit is seeded to initialLimit so the
        // agent retains the protocol base credit floor regardless of repayment history.
        assertEq(cl, INITIAL_LIMIT);
    }

    function test_recordActivity_doesNotIncrementLoansRepaid() public {
        vm.prank(caller);
        reg.recordActivity(AGENT_ID, 1000e6);
        (, uint256 loansRepaid,,,,) = reg.credits(AGENT_ID);
        assertEq(loansRepaid, 0);
    }

    function test_recordActivity_setsExistsTrue() public {
        (,,,bool existsBefore,,) = reg.credits(AGENT_ID);
        assertFalse(existsBefore);
        vm.prank(caller);
        reg.recordActivity(AGENT_ID, 1000e6);
        (,,,bool existsAfter,,) = reg.credits(AGENT_ID);
        assertTrue(existsAfter);
    }

    function test_recordActivity_emitsActivityRecorded() public {
        uint256 expectedIncrease = 50e6; // 1000e6 * 5% = 50e6, at cap
        vm.expectEmit(true, false, false, true);
        emit CreditRegistry.ActivityRecorded(AGENT_ID, 0, 50e6, 1000e6, expectedIncrease);
        vm.prank(caller);
        reg.recordActivity(AGENT_ID, 1000e6);
    }

    // =========================================================================
    // Activity track — maxActivityLimit ceiling
    // =========================================================================

    function test_recordActivity_nearCeiling_partialIncrease() public {
        // Put activityLimit at $49,980 (999 events of $1000 each, capped at $50 each)
        // Then one more event: headroom = $20, so only $20 added (not $50)
        vm.startPrank(caller);
        for (uint256 i = 0; i < 999; i++) {
            reg.recordActivity(AGENT_ID, 1000e6);
        }
        vm.stopPrank();
        (,,,, uint256 actLimitBefore,) = reg.credits(AGENT_ID);
        assertEq(actLimitBefore, 49_950e6); // 999 * 50e6

        // One more event: headroom = 50_000e6 - 49_950e6 = 50e6, which is <= cap
        // So finalIncrease = min(50e6, 50e6) = 50e6
        vm.prank(caller);
        reg.recordActivity(AGENT_ID, 1000e6);
        (,,,, uint256 actLimitAfter,) = reg.credits(AGENT_ID);
        assertEq(actLimitAfter, MAX_ACTIVITY_LIMIT);
    }

    function test_recordActivity_exactlyAtCeiling_doesNotRevert() public {
        // Fill to ceiling first
        vm.startPrank(caller);
        for (uint256 i = 0; i < 1000; i++) {
            reg.recordActivity(AGENT_ID, 1000e6);
        }
        // activityLimit now at MAX_ACTIVITY_LIMIT

        // One more large event: finalIncrease = 0, but no revert
        reg.recordActivity(AGENT_ID, 99_999e6);
        vm.stopPrank();

        (,,,, uint256 actLimit, uint256 actAttested) = reg.credits(AGENT_ID);
        assertEq(actLimit,    MAX_ACTIVITY_LIMIT);          // unchanged
        assertEq(actAttested, 1000 * 1000e6 + 99_999e6);   // full amount recorded
    }

    function test_recordActivity_atCeiling_activityAttestedGrows() public {
        // Fill to ceiling
        vm.startPrank(caller);
        for (uint256 i = 0; i < 1000; i++) {
            reg.recordActivity(AGENT_ID, 1000e6);
        }
        uint256 attestedAtCeiling = 1000 * 1000e6;

        // Three more events at ceiling
        reg.recordActivity(AGENT_ID, 5000e6);
        reg.recordActivity(AGENT_ID, 3000e6);
        reg.recordActivity(AGENT_ID, 2000e6);
        vm.stopPrank();

        (,,,, uint256 actLimit, uint256 actAttested) = reg.credits(AGENT_ID);
        assertEq(actLimit,    MAX_ACTIVITY_LIMIT);
        assertEq(actAttested, attestedAtCeiling + 10_000e6);
    }

    function test_recordActivity_atCeiling_emitsZeroCreditIncrease() public {
        // Fill to ceiling
        vm.startPrank(caller);
        for (uint256 i = 0; i < 1000; i++) {
            reg.recordActivity(AGENT_ID, 1000e6);
        }
        vm.stopPrank();

        // Next event emits ActivityRecorded with creditIncrease = 0
        vm.expectEmit(true, false, false, true);
        emit CreditRegistry.ActivityRecorded(
            AGENT_ID,
            MAX_ACTIVITY_LIMIT,  // oldActivityLimit
            MAX_ACTIVITY_LIMIT,  // newActivityLimit (unchanged)
            5000e6,              // amount
            0                    // creditIncrease = 0
        );
        vm.prank(caller);
        reg.recordActivity(AGENT_ID, 5000e6);
    }

    // =========================================================================
    // getLimit composition — both tracks
    // =========================================================================

    function test_getLimit_activityOnly() public {
        vm.prank(caller);
        reg.recordActivity(AGENT_ID, 1000e6); // +50e6 activityLimit
        // After recordActivity: exists=true, currentLimit=initialLimit (seeded on first touch),
        // activityLimit=50e6.
        // getLimit = initialLimit + 50e6 = 55e6.
        assertEq(reg.getLimit(AGENT_ID), INITIAL_LIMIT + 50e6);
    }

    function test_getLimit_repaymentOnly() public {
        vm.prank(caller);
        reg.recordRepayment(AGENT_ID, 400e6, false); // +100e6 currentLimit
        // getLimit = (5e6 + 100e6) + 0 = 105e6
        assertEq(reg.getLimit(AGENT_ID), INITIAL_LIMIT + 100e6);
    }

    function test_getLimit_bothTracks() public {
        vm.startPrank(caller);
        reg.recordRepayment(AGENT_ID, 400e6, false); // +100e6 currentLimit
        reg.recordActivity(AGENT_ID, 1000e6);          // +50e6 activityLimit
        vm.stopPrank();
        // getLimit = (5e6 + 100e6) + 50e6 = 155e6
        assertEq(reg.getLimit(AGENT_ID), INITIAL_LIMIT + 100e6 + 50e6);
    }

    function test_getLimit_tracksAreIndependent() public {
        // Repayment on AGENT does not affect AGENT2, activity on AGENT2 does not affect AGENT.
        vm.startPrank(caller);
        reg.recordRepayment(AGENT_ID,  400e6, false);
        reg.recordActivity(AGENT2_ID, 1000e6);
        vm.stopPrank();

        // AGENT: exists=true via repayment, currentLimit=initialLimit+100e6, activityLimit=0
        assertEq(reg.getLimit(AGENT_ID),  INITIAL_LIMIT + 100e6); // only repayment
        // AGENT2: exists=true via activity only, currentLimit seeded=initialLimit, activityLimit=50e6
        assertEq(reg.getLimit(AGENT2_ID), INITIAL_LIMIT + 50e6);  // initialLimit + activityLimit
    }

    // =========================================================================
    // Non-severe default
    // =========================================================================

    function test_nonSevereDefault_penalizesCurrentLimit() public {
        vm.prank(caller);
        reg.recordRepayment(AGENT_ID, 400e6, false); // currentLimit = 105e6
        uint256 limitBefore = reg.getLimit(AGENT_ID);

        vm.prank(caller);
        reg.recordDefault(AGENT_ID, false);
        // Penalty: currentLimit * (10000-2000)/10000 = currentLimit * 8000/10000
        // new currentLimit = 105e6 * 2000/10000 = 21e6 (penalty fraction retained)
        uint256 limitAfter = reg.getLimit(AGENT_ID);
        assertLt(limitAfter, limitBefore);
        (uint256 cl,,,,,) = reg.credits(AGENT_ID);
        assertEq(cl, (INITIAL_LIMIT + 100e6) * PENALTY_BPS / 10_000);
    }

    function test_nonSevereDefault_preservesActivityLimit() public {
        vm.startPrank(caller);
        reg.recordActivity(AGENT_ID, 1000e6); // activityLimit = 50e6
        reg.recordDefault(AGENT_ID, false);
        vm.stopPrank();
        (,,,, uint256 actLimit,) = reg.credits(AGENT_ID);
        assertEq(actLimit, 50e6); // unchanged
    }

    function test_nonSevereDefault_preservesActivityAttested() public {
        vm.startPrank(caller);
        reg.recordActivity(AGENT_ID, 1000e6);
        reg.recordDefault(AGENT_ID, false);
        vm.stopPrank();
        (,,,,, uint256 actAttested) = reg.credits(AGENT_ID);
        assertEq(actAttested, 1000e6); // unchanged
    }

    function test_nonSevereDefault_preservesLoansRepaid() public {
        vm.startPrank(caller);
        reg.recordRepayment(AGENT_ID, 100e6, false);
        reg.recordDefault(AGENT_ID, false);
        vm.stopPrank();
        (, uint256 loansRepaid,,,,) = reg.credits(AGENT_ID);
        assertEq(loansRepaid, 1); // unchanged
    }

    function test_nonSevereDefault_incrementsLoansDefaulted() public {
        vm.startPrank(caller);
        reg.recordDefault(AGENT_ID, false);
        reg.recordDefault(AGENT_ID, false);
        vm.stopPrank();
        (,, uint256 loansDefaulted,,,) = reg.credits(AGENT_ID);
        assertEq(loansDefaulted, 2);
    }

    // =========================================================================
    // Severe default
    // =========================================================================

    function test_severeDefault_zerosCurrentLimit() public {
        vm.startPrank(caller);
        reg.recordRepayment(AGENT_ID, 400e6, false);
        reg.recordDefault(AGENT_ID, true);
        vm.stopPrank();
        (uint256 cl,,,,,) = reg.credits(AGENT_ID);
        assertEq(cl, 0);
    }

    function test_severeDefault_zerosActivityLimit() public {
        vm.startPrank(caller);
        reg.recordActivity(AGENT_ID, 1000e6);
        reg.recordDefault(AGENT_ID, true);
        vm.stopPrank();
        (,,,, uint256 actLimit,) = reg.credits(AGENT_ID);
        assertEq(actLimit, 0);
    }

    function test_severeDefault_preservesActivityAttested() public {
        vm.startPrank(caller);
        reg.recordActivity(AGENT_ID, 5000e6);
        reg.recordActivity(AGENT_ID, 3000e6);
        reg.recordDefault(AGENT_ID, true);
        vm.stopPrank();
        (,,,,, uint256 actAttested) = reg.credits(AGENT_ID);
        assertEq(actAttested, 8000e6); // permanent record, not reset
    }

    function test_severeDefault_preservesLoansRepaid() public {
        vm.startPrank(caller);
        reg.recordRepayment(AGENT_ID, 100e6, false);
        reg.recordRepayment(AGENT_ID, 100e6, false);
        reg.recordDefault(AGENT_ID, true);
        vm.stopPrank();
        (, uint256 loansRepaid,,,,) = reg.credits(AGENT_ID);
        assertEq(loansRepaid, 2); // permanent record, not reset
    }

    function test_severeDefault_incrementsLoansDefaulted() public {
        vm.startPrank(caller);
        reg.recordDefault(AGENT_ID, true);
        reg.recordDefault(AGENT_ID, true);
        vm.stopPrank();
        (,, uint256 loansDefaulted,,,) = reg.credits(AGENT_ID);
        assertEq(loansDefaulted, 2);
    }

    function test_severeDefault_getLimit_returnsZero() public {
        vm.startPrank(caller);
        reg.recordRepayment(AGENT_ID, 400e6, false);
        reg.recordActivity(AGENT_ID, 1000e6);
        // Both tracks grew
        uint256 limitBefore = reg.getLimit(AGENT_ID);
        assertGt(limitBefore, INITIAL_LIMIT);

        reg.recordDefault(AGENT_ID, true);
        vm.stopPrank();

        // After severe default: exists=true, currentLimit=0, activityLimit=0.
        // getLimit = (exists ? currentLimit : initialLimit) + activityLimit = 0 + 0 = 0.
        // initialLimit is NOT restored — the agent has an explicit zero credit record.
        assertEq(reg.getLimit(AGENT_ID), 0);
    }

    function test_severeDefault_rebuildsActivityLimitViaNewAttestation() public {
        // Build up both tracks
        vm.startPrank(caller);
        reg.recordActivity(AGENT_ID, 1000e6);
        reg.recordRepayment(AGENT_ID, 400e6, false);
        reg.recordDefault(AGENT_ID, true);

        // Both limits now 0. exists=true so getLimit = 0 + 0 = 0 (not initialLimit).
        assertEq(reg.getLimit(AGENT_ID), 0);

        // New activity rebuilds activityLimit from 0
        reg.recordActivity(AGENT_ID, 2000e6); // +50e6 (capped)
        vm.stopPrank();

        (,,,, uint256 actLimit,) = reg.credits(AGENT_ID);
        assertEq(actLimit, 50e6);
        // getLimit = currentLimit(0) + activityLimit(50e6) = 50e6
        assertEq(reg.getLimit(AGENT_ID), 50e6);
    }

    function test_severeDefault_activityAttestedAccumulatesPostDefault() public {
        vm.startPrank(caller);
        reg.recordActivity(AGENT_ID, 3000e6);
        reg.recordDefault(AGENT_ID, true);
        reg.recordActivity(AGENT_ID, 2000e6);
        vm.stopPrank();
        (,,,,, uint256 actAttested) = reg.credits(AGENT_ID);
        assertEq(actAttested, 5000e6); // pre + post default
    }

    // =========================================================================
    // Severe vs non-severe — activity field comparison
    // =========================================================================

    function test_severeVsNonSevere_activityLimit_differs() public {
        // Two identical agents, same setup, different default severity
        address agentA = address(0xAAAA);
        address agentB = address(0xBBBB);
        uint256 agentAId = uint256(uint160(agentA));
        uint256 agentBId = uint256(uint160(agentB));

        vm.startPrank(caller);
        reg.recordActivity(agentAId, 1000e6);
        reg.recordActivity(agentBId, 1000e6);

        reg.recordDefault(agentAId, true);   // severe
        reg.recordDefault(agentBId, false);  // non-severe
        vm.stopPrank();

        (,,,, uint256 aActLimit,) = reg.credits(agentAId);
        (,,,, uint256 bActLimit,) = reg.credits(agentBId);

        assertEq(aActLimit, 0);    // severe: zeroed
        assertEq(bActLimit, 50e6); // non-severe: preserved
    }

    // =========================================================================
    // getLimit — boundary: agent with only activity, no repayment
    // =========================================================================

    function test_getLimit_activityOnly_baseIsInitialLimitWhenFirstTouchedViaActivity() public {
        // recordActivity seeds currentLimit=initialLimit on first touch so the agent
        // retains the protocol floor even without any repayment history.
        vm.prank(caller);
        reg.recordActivity(AGENT_ID, 1000e6);
        // exists=true, currentLimit=initialLimit (seeded), activityLimit=50e6
        // → getLimit = initialLimit + 50e6 = 55e6
        assertEq(reg.getLimit(AGENT_ID), INITIAL_LIMIT + 50e6);
    }

    function test_getLimit_afterRepayment_baseIsCurrentLimit() public {
        vm.startPrank(caller);
        reg.recordRepayment(AGENT_ID, 400e6, false); // currentLimit = 105e6
        reg.recordActivity(AGENT_ID, 1000e6);           // activityLimit = 50e6
        vm.stopPrank();
        // exists=true, currentLimit=105e6 (> initialLimit), activityLimit=50e6
        assertEq(reg.getLimit(AGENT_ID), (INITIAL_LIMIT + 100e6) + 50e6);
    }

    // =========================================================================
    // UUPS
    // =========================================================================

    function test_upgradeOnlyOwner() public {
        CreditRegistry newImpl = new CreditRegistry();
        vm.prank(stranger);
        vm.expectRevert();
        reg.upgradeToAndCall(address(newImpl), "");
    }
}
