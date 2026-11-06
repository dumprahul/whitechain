// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";
import {MockAToken} from "./MockAToken.sol";

/// @notice Minimal Aave V3 shaped pool for one asset. Yield is paid from a reserve the owner funds.
/// @dev Withdrawals can never exceed the pool's USDT balance, so if the reserve runs dry, accrued yield
///      stops being payable. Test/testnet use only; the real Aave pool replaces it for new businesses.
contract MockAavePool is IAavePool, Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    MockAToken public immutable aToken;

    event Supplied(address indexed user, address indexed onBehalfOf, uint256 amount);
    event Withdrawn(address indexed user, address indexed to, uint256 amount);
    event ReserveFunded(address indexed from, uint256 amount);
    event ApySet(uint256 apyBps);

    error WrongAsset();

    constructor(address asset_, uint8 decimals_, address owner_) Ownable(owner_) {
        asset = IERC20(asset_);
        aToken = new MockAToken(address(this), decimals_);
    }

    function supply(address asset_, uint256 amount, address onBehalfOf, uint16) external {
        if (asset_ != address(asset)) revert WrongAsset();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
        emit Supplied(msg.sender, onBehalfOf, amount);
    }

    /// @param amount type(uint256).max withdraws the caller's whole balance (as on Aave).
    function withdraw(address asset_, uint256 amount, address to) external returns (uint256) {
        if (asset_ != address(asset)) revert WrongAsset();
        if (amount == type(uint256).max) amount = aToken.balanceOf(msg.sender);
        aToken.burn(msg.sender, amount);
        asset.safeTransfer(to, amount);
        emit Withdrawn(msg.sender, to, amount);
        return amount;
    }

    /// @notice Add USDT that pays out yield.
    function fundReserve(uint256 amount) external {
        asset.safeTransferFrom(msg.sender, address(this), amount);
        emit ReserveFunded(msg.sender, amount);
    }

    function setApyBps(uint256 bps) external onlyOwner {
        aToken.setApyBps(bps);
        emit ApySet(bps);
    }
}
