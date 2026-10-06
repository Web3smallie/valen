// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ERC1967Proxy}    from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AgentRegistry}   from "../src/AgentRegistry.sol";
import {ActivityAttester} from "../src/ActivityAttester.sol";
import {IActivityAttester} from "../src/interfaces/IActivityAttester.sol";
import {ICreditRegistry}   from "../src/interfaces/ICreditRegistry.sol";

// ---------------------------------------------------------------------------
// Mock CreditRegistry — implements ICreditRegistry for test isolation.
// Tracks calls to recordActivity so tests can assert correct forwarding.
// ---------------------------------------------------------------------------
contract MockCreditRegistry is ICreditRegistry {
    // ICreditRegistry stubs
    function getLimit(uint256) external pure returns (uint256) { return 0; }
    function requiresApproval(uint256) external pure returns (bool) { return false; }
    function recordRepayment(uint256, uint256, bool) external {}
    function recordDefault(uint256, bool) external {}

    // Final V1 uint256 agentId interface
    struct ActivityCall {
        uint256 agentId;
        uint256 amount;
    }
    ActivityCall[] public activityCalls;
    bool public shouldRevertOnActivity;

    function recordActivity(uint256 agentId, uint256 amount) external {
        if (shouldRevertOnActivity) revert("MockCR: forced revert");
        activityCalls.push(ActivityCall({agentId: agentId, amount: amount}));
    }

    function activityCallCount() external view returns (uint256) {
        return activityCalls.length;
    }

    function lastActivityCall() external view returns (uint256 agentId, uint256 amount) {
        require(activityCalls.length > 0, "no calls");
        ActivityCall storage c = activityCalls[activityCalls.length - 1];
        return (c.agentId, c.amount);
    }

    function setShouldRevertOnActivity(bool v) external {
        shouldRevertOnActivity = v;
    }
}

// ---------------------------------------------------------------------------
// ActivityAttesterTest
// ---------------------------------------------------------------------------
contract ActivityAttesterTest is Test {

    AgentRegistry    agentReg;
    MockCreditRegistry mockCR;
    ActivityAttester attester;

    address owner    = address(this);
    address alice    = address(0xA11CE);   // registered agent wallet
    address bob      = address(0xB0B);     // second wallet for same agent
    address stranger = address(0x9999);   // unregistered wallet
    address source1  = address(0x50001);  // approved ERC-8183 source
    address source2  = address(0x50002);  // another source (unapproved by default)

    uint256 agentId; // alice's Valen agentId

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function setUp() public {
        // Deploy real AgentRegistry proxy
        agentReg = AgentRegistry(_proxy(
            address(new AgentRegistry()),
            abi.encodeCall(AgentRegistry.initialize, (owner))
        ));

        // Register alice as an agent
        vm.prank(alice);
        agentId = agentReg.registerAgent(0);

        // Deploy mock CreditRegistry
        mockCR = new MockCreditRegistry();

        // Deploy ActivityAttester proxy
        attester = ActivityAttester(_proxy(
            address(new ActivityAttester()),
            abi.encodeCall(ActivityAttester.initialize, (owner, address(agentReg), address(mockCR)))
        ));

        // Approve source1
        attester.setActivitySource(source1, true);
    }

    // -----------------------------------------------------------------------
    // Helper: build the evidence key the same way the contract does
    // -----------------------------------------------------------------------
    function _evidenceKey(address src, uint256 jobId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(src, jobId));
    }

    // -----------------------------------------------------------------------
    // Initialization
    // -----------------------------------------------------------------------

    function test_initialize_zeroAgentRegistryReverts() public {
        // vm.expectRevert must wrap the exact reverting external call.
        // ERC1967Proxy propagates the init revert, so we call the proxy constructor directly.
        address impl = address(new ActivityAttester());
        bytes memory initData = abi.encodeCall(
            ActivityAttester.initialize, (owner, address(0), address(mockCR))
        );
        vm.expectRevert(IActivityAttester.ZeroAddress.selector);
        new ERC1967Proxy(impl, initData);
    }

    function test_initialize_zeroCreditRegistryReverts() public {
        address impl = address(new ActivityAttester());
        bytes memory initData = abi.encodeCall(
            ActivityAttester.initialize, (owner, address(agentReg), address(0))
        );
        vm.expectRevert(IActivityAttester.ZeroAddress.selector);
        new ERC1967Proxy(impl, initData);
    }

    function test_cannotInitializeTwice() public {
        vm.expectRevert();
        attester.initialize(owner, address(agentReg), address(mockCR));
    }

    // -----------------------------------------------------------------------
    // setActivitySource
    // -----------------------------------------------------------------------

    function test_setActivitySource_approve() public {
        assertFalse(attester.approvedActivitySources(source2));
        vm.expectEmit(true, false, false, true);
        emit IActivityAttester.ActivitySourceSet(source2, true);
        attester.setActivitySource(source2, true);
        assertTrue(attester.approvedActivitySources(source2));
    }

    function test_setActivitySource_remove() public {
        // source1 is approved in setUp
        assertTrue(attester.approvedActivitySources(source1));
        vm.expectEmit(true, false, false, true);
        emit IActivityAttester.ActivitySourceSet(source1, false);
        attester.setActivitySource(source1, false);
        assertFalse(attester.approvedActivitySources(source1));
    }

    function test_setActivitySource_nonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        attester.setActivitySource(source2, true);
    }

    function test_setActivitySource_zeroAddressReverts() public {
        vm.expectRevert(IActivityAttester.ZeroAddress.selector);
        attester.setActivitySource(address(0), true);
    }

    function test_setActivitySource_afterRemoval_attestReverts() public {
        attester.setActivitySource(source1, false);
        vm.expectRevert(IActivityAttester.NotApprovedSource.selector);
        attester.attestActivity(source1, 1, agentId, alice, 1000e6);
    }

    // -----------------------------------------------------------------------
    // attestActivity — happy path
    // -----------------------------------------------------------------------

    function test_attestActivity_success() public {
        uint256 jobId  = 42;
        uint256 amount = 1000e6;
        bytes32 expKey = _evidenceKey(source1, jobId);

        vm.expectEmit(true, true, true, true);
        emit IActivityAttester.ActivityAttested(agentId, source1, jobId, alice, amount, expKey);

        attester.attestActivity(source1, jobId, agentId, alice, amount);

        // Replay protection set
        assertTrue(attester.attestedActivity(expKey));

        // CreditRegistry called once with correct args
        assertEq(mockCR.activityCallCount(), 1);
        (uint256 calledAgentId, uint256 calledAmount) = mockCR.lastActivityCall();
        assertEq(calledAgentId, agentId);
        assertEq(calledAmount, amount);
    }

    function test_attestActivity_anyCallerCanAttest() public {
        // attestActivity is permissionless
        vm.prank(stranger);
        attester.attestActivity(source1, 100, agentId, alice, 500e6);
        assertEq(mockCR.activityCallCount(), 1);
    }

    function test_attestActivity_secondAuthorizedWallet() public {
        // Add bob as a second wallet for the same agent
        vm.prank(alice);
        agentReg.addWallet(agentId, bob);

        // bob can be the providerWallet
        attester.attestActivity(source1, 200, agentId, bob, 300e6);
        assertEq(mockCR.activityCallCount(), 1);
        (uint256 calledAgentId2,) = mockCR.lastActivityCall();
        assertEq(calledAgentId2, agentId);
    }

    // -----------------------------------------------------------------------
    // attestActivity — error paths (Rev 3 validation order)
    // -----------------------------------------------------------------------

    function test_attestActivity_unapprovedSourceReverts() public {
        // source2 was never approved
        vm.expectRevert(IActivityAttester.NotApprovedSource.selector);
        attester.attestActivity(source2, 1, agentId, alice, 1000e6);
    }

    function test_attestActivity_unauthorizedProviderReverts() public {
        // stranger is not authorized for agentId
        vm.expectRevert(IActivityAttester.UnauthorizedProvider.selector);
        attester.attestActivity(source1, 1, agentId, stranger, 1000e6);
    }

    function test_attestActivity_replayReverts() public {
        uint256 jobId = 77;
        attester.attestActivity(source1, jobId, agentId, alice, 500e6);

        // Same (source1, jobId) again
        vm.expectRevert(IActivityAttester.AlreadyAttested.selector);
        attester.attestActivity(source1, jobId, agentId, alice, 500e6);
    }

    function test_attestActivity_sameJobDifferentSourceNotReplay() public {
        // (source1, jobId=1) and (source2, jobId=1) are different keys
        attester.setActivitySource(source2, true);
        attester.attestActivity(source1, 1, agentId, alice, 100e6);
        // source2 with same jobId is a different evidenceKey — should succeed
        attester.attestActivity(source2, 1, agentId, alice, 200e6);
        assertEq(mockCR.activityCallCount(), 2);
    }

    // -----------------------------------------------------------------------
    // Validation order: source check fires before provider check
    // -----------------------------------------------------------------------

    function test_validationOrder_sourceBeforeProvider() public {
        // unapproved source + unauthorized provider: source error fires first
        vm.expectRevert(IActivityAttester.NotApprovedSource.selector);
        attester.attestActivity(source2, 1, agentId, stranger, 100e6);
    }

    // -----------------------------------------------------------------------
    // attestActivity — ceiling behavior (CreditRegistry does not revert)
    // -----------------------------------------------------------------------

    function test_attestActivity_atCapSucceeds() public {
        // Mock CR does NOT revert — attester must not revert either
        // This test verifies the attester succeeds even when the ceiling is reached.
        attester.attestActivity(source1, 999, agentId, alice, 999_999e6);

        // Attestation was recorded
        assertTrue(attester.attestedActivity(_evidenceKey(source1, 999)));
        assertEq(mockCR.activityCallCount(), 1);
    }

    function test_attestActivity_atCap_attestedKeyConsumed() public {
        // Even if CR were to somehow no-op, replay protection still fires on repeat
        attester.attestActivity(source1, 888, agentId, alice, 50_000e6);
        vm.expectRevert(IActivityAttester.AlreadyAttested.selector);
        attester.attestActivity(source1, 888, agentId, alice, 50_000e6);
    }

    // -----------------------------------------------------------------------
    // Evidence key construction
    // -----------------------------------------------------------------------

    function test_evidenceKeyConstruction_matchesContract() public {
        uint256 jobId = 12345;
        bytes32 expected = keccak256(abi.encodePacked(source1, jobId));

        attester.attestActivity(source1, jobId, agentId, alice, 100e6);

        assertTrue(attester.attestedActivity(expected));
        // A different key (same jobId, different source) is not set
        bytes32 other = keccak256(abi.encodePacked(source2, jobId));
        assertFalse(attester.attestedActivity(other));
    }

    // -----------------------------------------------------------------------
    // UUPS upgrade guard
    // -----------------------------------------------------------------------

    function test_upgradeOnlyOwner() public {
        ActivityAttester newImpl = new ActivityAttester();
        vm.prank(stranger);
        vm.expectRevert();
        attester.upgradeToAndCall(address(newImpl), "");
    }
}
