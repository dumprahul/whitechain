// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

/// @notice The two Aave V3 pool calls the vault uses (signature-compatible with the real pool).
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
