// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAgentRegistry
/// @notice Interface for Valen's authoritative agent identity store.
///         Manages the mapping from Valen agentId to authorized wallet set.
///         Valen agentId is Valen's own persistent credit identity and is
///         distinct from any ERC-8004 agentId, which is stored only as an
///         informational external reference.
interface IAgentRegistry {
    /// @notice Register a new Valen agent identity.
    /// @param  erc8004TokenId  External ERC-8004 token ID for reference only.
    ///                         Pass 0 if no ERC-8004 identity is being linked.
    /// @return agentId         The newly assigned Valen agentId.
    function registerAgent(uint256 erc8004TokenId) external returns (uint256 agentId);

    /// @notice Add a wallet to the authorized set for an agent.
    ///         Only callable by the agent's current owner.
    ///         A wallet may only be authorized for one agentId at a time.
    function addWallet(uint256 agentId, address wallet) external;

    /// @notice Remove a wallet from the authorized set for an agent.
    ///         Only callable by the agent's current owner.
    ///         Reverts if removal would leave the agent with zero authorized wallets.
    function removeWallet(uint256 agentId, address wallet) external;

    /// @notice Returns true if wallet is currently authorized for agentId.
    function isAuthorizedWallet(uint256 agentId, address wallet) external view returns (bool);

    /// @notice Returns the agentId that wallet is currently authorized under,
    ///         or 0 if the wallet is not registered to any agent.
    function getAgentId(address wallet) external view returns (uint256);

    /// @notice Transfer the ownership role for an agent to a new address.
    ///         Does not affect wallet authorizations.
    ///         Only callable by the current agent owner.
    function transferAgentOwnership(uint256 agentId, address newOwner) external;
}
