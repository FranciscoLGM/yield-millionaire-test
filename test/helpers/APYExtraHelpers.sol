// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/APYExtra.sol";

abstract contract APYExtraHelpers is Test {
    APYExtra public apyExtra;
    address public rebalancer = makeAddr("rebalancer");

    // ============ HELPER FUNCTIONS ============
    function _depositForUser(
        address user,
        uint256 amount,
        uint256 extraAPY,
        uint256 expirationTime,
        address referrer_
    ) internal returns (uint256) {
        vm.prank(rebalancer);
        if (referrer_ == address(0)) {
            apyExtra.deposit(user, expirationTime, extraAPY, amount);
        } else {
            apyExtra.deposit(user, expirationTime, extraAPY, amount, referrer_);
        }
        return amount;
    }

    function _warpAndAccumulate(address user, uint256 timeToWarp) internal {
        vm.warp(block.timestamp + timeToWarp);
        // Force accumulation by doing a zero deposit
        vm.prank(rebalancer);
        apyExtra.deposit(user, 0, 0, 0);
    }
}
