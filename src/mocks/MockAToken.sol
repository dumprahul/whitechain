// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Rebasing receipt token for MockAavePool. Balances grow with a linear (simple-interest) index.
/// @dev Not transferable. Only the pool can mint, burn and set the rate. Test/testnet use only.
contract MockAToken {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant YEAR = 365 days;

    string public constant name = "Mock aUSDT";
    string public constant symbol = "maUSDT";
    uint8 public immutable decimals;
    address public immutable pool;

    uint256 public apyBps;
    uint256 internal _index = RAY;
    uint256 internal _lastUpdate;
    uint256 internal _scaledTotal;
    mapping(address => uint256) internal _scaled;

    error OnlyPool();
    error InsufficientBalance();

    modifier onlyPool() {
        if (msg.sender != pool) revert OnlyPool();
        _;
    }

    constructor(address pool_, uint8 decimals_) {
        pool = pool_;
        decimals = decimals_;
        _lastUpdate = block.timestamp;
    }

    /// @notice Current liquidity index (ray), including interest accrued since the last update.
    function currentIndex() public view returns (uint256) {
        return _index + (_index * apyBps * (block.timestamp - _lastUpdate)) / (BPS * YEAR);
    }

    function balanceOf(address user) external view returns (uint256) {
        return (_scaled[user] * currentIndex()) / RAY;
    }

    function totalSupply() external view returns (uint256) {
        return (_scaledTotal * currentIndex()) / RAY;
    }

    function setApyBps(uint256 bps) external onlyPool {
        _accrue();
        apyBps = bps;
    }

    function mint(address to, uint256 amount) external onlyPool {
        uint256 idx = _accrue();
        uint256 scaled = Math.ceilDiv(amount * RAY, idx);
        _scaled[to] += scaled;
        _scaledTotal += scaled;
    }

    function burn(address from, uint256 amount) external onlyPool {
        uint256 idx = _accrue();
        uint256 scaled = Math.ceilDiv(amount * RAY, idx);
        if (scaled > _scaled[from]) revert InsufficientBalance();
        _scaled[from] -= scaled;
        _scaledTotal -= scaled;
    }

    function _accrue() internal returns (uint256 idx) {
        idx = currentIndex();
        _index = idx;
        _lastUpdate = block.timestamp;
    }
}
