// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/APYExtra.sol";

abstract contract APYExtraHelpers is Test {
    APYExtra public apyExtra;
    address public rebalancer = makeAddr("rebalancer");

    // Test addresses para reutilización
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public referrerAddr = makeAddr("referrerAddr");

    // Test parameters
    uint256 public constant TEST_DEPOSIT_AMOUNT = 1000 ether;
    uint256 public constant TEST_EXTRA_APY = 20; // 2%
    uint256 public constant TEST_EXPIRATION = 365 days;

    /**
     * @dev Encapsula lógica compleja de depósito con referrer opcional
     */
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

    /**
     * @dev Combina manipulación de tiempo + acumulación de earnings
     */
    function _warpAndAccumulate(address user, uint256 timeToWarp) internal {
        vm.warp(block.timestamp + timeToWarp);
        // Force accumulation by doing a zero deposit
        vm.prank(rebalancer);
        apyExtra.deposit(user, 0, 0, 0);
    }

    /**
     * @dev Setup común para tests de referral system
     */
    function _setupReferralScenario() internal {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            referrerAddr
        );
        _depositForUser(
            user2,
            TEST_DEPOSIT_AMOUNT * 2,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            referrerAddr
        );
    }

    /**
     * @dev Helper para assertions complejas de UserInfo
     */
    function _getUserInfo(
        address user
    )
        internal
        view
        returns (
            uint256 expirationTime,
            uint256 lastUpdateTime,
            uint256 extraAPY,
            uint256 balance,
            uint256 accumulatedEarnings,
            address referrer
        )
    {
        return apyExtra.userInfo(user);
    }
}
