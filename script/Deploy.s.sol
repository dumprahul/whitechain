// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {OrgFactory} from "../src/OrgFactory.sol";
import {OrgVault} from "../src/OrgVault.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";

/// @notice Deploys MockAavePool, OrgFactory and the OrgVault implementation, and wires them together.
/// @dev Env: USDT_ADDRESS (required), FEE_RECIPIENT (default: deployer), PLATFORM_OWNER (default: deployer),
///      POOL_APY_BPS (default 500), POOL_RESERVE (whole USDT pre-funded for yield, default 0).
///      All amounts are scaled by the token's `decimals()`.
///      Run: forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
contract Deploy is Script {
    function run() external returns (OrgFactory factory, OrgVault implementation, MockAavePool pool) {
        address usdt = vm.envAddress("USDT_ADDRESS");
        uint256 unit = 10 ** uint256(IERC20Metadata(usdt).decimals());
        uint256 apyBps = vm.envOr("POOL_APY_BPS", uint256(500));
        uint256 reserve = vm.envOr("POOL_RESERVE", uint256(0)) * unit;

        vm.startBroadcast();
        // The account that signs (--account / --private-key / --ledger), not the script's default sender.
        // `msg.sender` is the default sender and would make the wrong address the owner.
        (, address deployer,) = vm.readCallers();
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);
        address platformOwner = vm.envOr("PLATFORM_OWNER", deployer);
        pool = new MockAavePool(usdt, uint8(IERC20Metadata(usdt).decimals()), deployer);
        factory = new OrgFactory(usdt, 5 * unit, feeRecipient, deployer);
        implementation = new OrgVault(address(factory), usdt, address(pool), address(pool.aToken()), unit);
        factory.setImplementation(address(implementation));
        pool.setApyBps(apyBps);
        if (reserve != 0) {
            IERC20Metadata(usdt).approve(address(pool), reserve);
            pool.fundReserve(reserve);
        }
        if (platformOwner != deployer) {
            factory.transferOwnership(platformOwner);
            pool.transferOwnership(platformOwner);
        }
        vm.stopBroadcast();

        console.log("MockAavePool   ", address(pool));
        console.log("MockAToken     ", address(pool.aToken()));
        console.log("OrgFactory     ", address(factory));
        console.log("OrgVault (impl)", address(implementation));
    }
}
