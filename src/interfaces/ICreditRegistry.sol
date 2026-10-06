// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICreditRegistry {
    // -------------------------------------------------------------------------
    // View
    // -------------------------------------------------------------------------

    /// @notice Returns the agent's total available credit capacity.
    /// @dev    Returns currentLimit + activityLimit.
    ///         For agents with no record, currentLimit defaults to initialLimit
    ///         and activityLimit is 0.
    function getLimit(uint256 agentId) external view returns (uint256);

    /// @notice Returns true if the amount exceeds the manual-approval threshold.
    function requiresApproval(uint256 amount) external view returns (bool);

    // -------------------------------------------------------------------------
    // Repayment / default (called by LoanRegistry and RevenueRouter)
    // -------------------------------------------------------------------------

    /// @notice Records a successful Valen loan repayment, growing the agent's
    ///         currentLimit. Step 5 final signature: keyed by uint256 agentId.
    function recordRepayment(uint256 agentId, uint256 repaidAmount, bool early) external;

    /// @notice Records a default against the agent identified by agentId.
    ///         severe=true resets both currentLimit and activityLimit to 0.
    ///         severe=false applies the defaultPenaltyBps reduction to currentLimit only.
    function recordDefault(uint256 agentId, bool severe) external;

    // -------------------------------------------------------------------------
    // Activity track (called only by ActivityAttester)
    // -------------------------------------------------------------------------

    /// @notice Records verified external economic activity for an agent.
    /// @dev    Grows activityLimit (capped at maxActivityLimit) by a fraction of
    ///         the verified amount (activityGrowthBps), subject to maxActivityIncreasePerEvent.
    ///         activityAttested is always incremented regardless of whether the cap is reached.
    ///         Does not revert when activityLimit is already at maxActivityLimit.
    function recordActivity(uint256 agentId, uint256 amount) external;
}
