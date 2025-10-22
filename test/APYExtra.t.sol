// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {APYExtraHelpers} from "./helpers/APYExtraHelpers.sol";
import "../src/APYExtra.sol";

contract APYExtraTest is Test, APYExtraHelpers {
    address public admin = makeAddr("admin");
    address public apyManager = makeAddr("apyManager");
    address public attacker = makeAddr("attacker");

    uint256 public constant INITIAL_REFERRAL_APY = 100; // 10%

    function setUp() public {
        vm.startPrank(admin);
        apyExtra = new APYExtra(admin, INITIAL_REFERRAL_APY);
        apyExtra.grantRole(apyExtra.REBALANCER_ROLE(), rebalancer);
        apyExtra.grantRole(apyExtra.APY_MANAGER_ROLE(), apyManager);
        vm.stopPrank();
    }

    // ============ CONSTRUCTOR TESTS ============

    /// @dev Test que verifica la inicialización correcta del contrato
    function test_Constructor_InitialState() public view {
        assertEq(apyExtra.referralAPY(), INITIAL_REFERRAL_APY);
        assertTrue(apyExtra.apyEnabled());
        assertTrue(apyExtra.hasRole(apyExtra.DEFAULT_ADMIN_ROLE(), admin));
    }

    /// @dev Test que verifica que el constructor revierte cuando el admin es cero
    function test_Constructor_ZeroAdmin() public {
        vm.expectRevert(APYExtra.InvalidAdmin.selector);
        new APYExtra(address(0), INITIAL_REFERRAL_APY);
    }

    // ============ DEPOSIT TESTS ============

    /// @dev Test que verifica un depósito sin referrer
    function test_Deposit_WithoutReferrer() public {
        uint256 amount = _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            address(0)
        );

        (
            ,
            ,
            uint256 apy,
            uint256 balance,
            uint256 accumulated,
            address ref
        ) = _getUserInfo(user1);

        assertEq(balance, amount);
        assertEq(apy, TEST_EXTRA_APY);
        assertEq(ref, address(0));
        assertEq(accumulated, 0);
    }

    /// @dev Test que verifica un depósito con referrer
    function test_Deposit_WithReferrer() public {
        uint256 amount = _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            referrerAddr
        );

        (, , , uint256 balance, , address actualReferrer) = _getUserInfo(user1);
        assertEq(balance, amount);
        assertEq(actualReferrer, referrerAddr);
    }

    /// @dev Test que verifica un depósito con cantidad cero
    function test_Deposit_ZeroAmount() public {
        vm.prank(rebalancer);
        apyExtra.deposit(user1, TEST_EXPIRATION, TEST_EXTRA_APY, 0);

        (, , , uint256 balance, , ) = _getUserInfo(user1);
        assertEq(balance, 0);
    }

    /// @dev Test que verifica que solo el rebalancer puede depositar
    function test_Deposit_OnlyRebalancer() public {
        vm.prank(attacker);
        vm.expectRevert(APYExtra.CallerNotRebalancer.selector);
        apyExtra.deposit(
            user1,
            TEST_EXPIRATION,
            TEST_EXTRA_APY,
            TEST_DEPOSIT_AMOUNT
        );
    }

    /// @dev Test que verifica que el APY solo se actualiza si es mayor
    function test_Deposit_UpdateAPY_OnlyIfHigher() public {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            50,
            TEST_EXPIRATION,
            address(0)
        );
        (, , uint256 apy1, , , ) = _getUserInfo(user1);
        assertEq(apy1, 50);

        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            150,
            TEST_EXPIRATION,
            address(0)
        );
        (, , uint256 apy2, , , ) = _getUserInfo(user1);
        assertEq(apy2, 150);

        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            100,
            TEST_EXPIRATION,
            address(0)
        );
        (, , uint256 apy3, , , ) = _getUserInfo(user1);
        assertEq(apy3, 150);
    }

    /// @dev Test que verifica que un not rebalancer no puede depositar con referrer
    function test_Deposit_NotRebalancer_WithReferrer_Reverts() public {
        address testAttacker = makeAddr("testAttacker2");
        uint256 testExpirationTime = 365 days;
        uint256 testExtraAPY = 1000;
        uint256 testAmount = 100e18;
        address testUser = makeAddr("testUser2");
        address testReferrer = makeAddr("testReferrer2");

        vm.prank(testAttacker);
        vm.expectRevert(APYExtra.CallerNotRebalancer.selector);
        apyExtra.deposit(
            testUser,
            testExpirationTime,
            testExtraAPY,
            testAmount,
            testReferrer
        );
    }

    // ============ WITHDRAW TESTS ============

    /// @dev Test que verifica un retiro normal
    function test_Withdraw_NormalFlow() public {
        uint256 depositAmount = _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            address(0)
        );

        vm.prank(user1);
        uint256 withdrawnAmount = apyExtra.withdraw(depositAmount);

        (, , , uint256 balanceAfter, , ) = _getUserInfo(user1);
        assertEq(balanceAfter, 0);
        assertEq(withdrawnAmount, depositAmount);
    }

    /// @dev Test que verifica un retiro de cantidad cero
    function test_Withdraw_ZeroAmount() public {
        vm.prank(user1);
        uint256 result = apyExtra.withdraw(0);
        assertEq(result, 0);
    }

    /// @dev Test que verifica que retirar con balance insuficiente retorna cero
    function test_Withdraw_InsufficientBalance_ReturnsZero() public {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            address(0)
        );

        vm.prank(user1);
        uint256 result = apyExtra.withdraw(TEST_DEPOSIT_AMOUNT + 1);

        assertEq(result, 0);
        (, , , uint256 balance, , ) = _getUserInfo(user1);
        assertEq(balance, TEST_DEPOSIT_AMOUNT);
    }

    // ============ EARNINGS CALCULATION TESTS ============

    /// @dev Test que verifica el cálculo de ganancias
    function test_GetLastEarnings_BasicCalculation() public {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            365 days,
            address(0)
        );

        _warpAndAccumulate(user1, 30 days);

        uint256 expected = (TEST_DEPOSIT_AMOUNT * TEST_EXTRA_APY * 30 days) /
            (apyExtra.APY_DENOMINATOR() * 365 days);
        uint256 actual = apyExtra.getLastEarnings(user1);

        assertEq(actual, expected);
    }

    /// @dev Test que verifica que las ganancias son cero cuando APY está deshabilitado
    function test_GetLastEarnings_APYDisabled() public {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            address(0)
        );

        vm.prank(apyManager);
        apyExtra.toggleAPY();

        _warpAndAccumulate(user1, 30 days);
        uint256 earnings = apyExtra.getLastEarnings(user1);

        assertEq(earnings, 0);
    }

    /// @dev Test que verifica el cálculo de ganancias totales
    function test_GetTotalEarnings() public {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            address(0)
        );

        _warpAndAccumulate(user1, 30 days);

        uint256 lastEarnings = apyExtra.getLastEarnings(user1);
        uint256 totalEarnings = apyExtra.getTotalEarnings(user1);

        assertEq(totalEarnings, lastEarnings);
    }

    /// @dev Test que verifica que las ganancias de referidos son cero con APY deshabilitado
    function test_GetReferralsEarnings_APYDisabled() public {
        _setupReferralScenario();

        vm.prank(apyManager);
        apyExtra.toggleAPY();

        uint256 earnings = apyExtra.getReferralsEarnings(referrerAddr);
        assertEq(earnings, 0);
    }

    /// @dev Test que verifica la acumulación de ganancias para usuario y referrer
    function test_AccumulateUserAndReferrerEarnings_WithReferrerEarnings()
        public
    {
        _setupReferralScenario();

        vm.warp(365 days);

        vm.prank(rebalancer);
        apyExtra.deposit(user1, 0, 0, 1);

        (uint256 lastUpdateTime, uint256 accumulatedEarnings) = apyExtra
            .referralInfo(referrerAddr);
        assertGt(accumulatedEarnings, 0);
        assertEq(lastUpdateTime, block.timestamp);
    }

    // ============ REFERRAL SYSTEM TESTS ============

    /// @dev Test que verifica el cálculo básico de ganancias de referidos
    function test_ReferralEarnings_Basic() public {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            referrerAddr
        );
        _warpAndAccumulate(referrerAddr, 30 days);

        uint256 expected = (TEST_DEPOSIT_AMOUNT *
            INITIAL_REFERRAL_APY *
            30 days) / (apyExtra.APY_DENOMINATOR() * 365 days);
        uint256 actual = apyExtra.getReferralsEarnings(referrerAddr);

        assertEq(actual, expected);
    }

    /// @dev Test que verifica que el referrer solo se establece en el primer depósito
    function test_Referral_OnlySetOnFirstDeposit() public {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            referrerAddr
        );

        (, , , , , address referrer1) = _getUserInfo(user1);
        assertEq(referrer1, referrerAddr);

        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            user2
        );

        (, , , , , address referrer2) = _getUserInfo(user1);
        assertEq(referrer2, referrerAddr);
    }

    /// @dev Test que verifica que el balance de referidos se actualiza al retirar
    function test_ReferralBalance_UpdatesOnWithdraw() public {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            referrerAddr
        );
        assertEq(
            apyExtra.referralTotalBalance(referrerAddr),
            TEST_DEPOSIT_AMOUNT
        );

        vm.prank(user1);
        apyExtra.withdraw(TEST_DEPOSIT_AMOUNT);

        assertEq(apyExtra.referralTotalBalance(referrerAddr), 0);
    }

    // ============ APY MANAGEMENT TESTS ============

    /// @dev Test que verifica la actualización del APY de referidos
    function test_UpdateReferralAPY() public {
        uint256 newAPY = 200; // 20%

        vm.prank(apyManager);
        apyExtra.updateReferralAPY(newAPY);

        assertEq(apyExtra.referralAPY(), newAPY);
    }

    // ============ FUZZ TESTS ============

    /// @dev Test de fuzzing para depósito y retiro
    function testFuzz_DepositWithdraw(
        uint256 amount,
        uint256 extraAPY,
        uint256 timeDelta
    ) public {
        amount = bound(amount, 1, 1000000 ether);
        extraAPY = bound(extraAPY, 1, 1000);
        timeDelta = bound(timeDelta, 1, 365 days);

        _depositForUser(user1, amount, extraAPY, 365 days, address(0));
        _warpAndAccumulate(user1, timeDelta);

        vm.prank(user1);
        uint256 result = apyExtra.withdraw(amount);

        assertEq(result, amount);
        (, , , uint256 balance, , ) = _getUserInfo(user1);
        assertEq(balance, 0);
    }

    /// @dev Test de fuzzing para retiro con balance insuficiente
    function testFuzz_Withdraw_InsufficientBalance(
        uint256 depositAmount,
        uint256 withdrawAmount
    ) public {
        depositAmount = bound(depositAmount, 1, 1000000 ether);
        withdrawAmount = bound(
            withdrawAmount,
            depositAmount + 1,
            type(uint128).max
        );

        _depositForUser(
            user1,
            depositAmount,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            address(0)
        );

        vm.prank(user1);
        uint256 result = apyExtra.withdraw(withdrawAmount);

        assertEq(result, 0);
        (, , , uint256 balance, , ) = _getUserInfo(user1);
        assertEq(balance, depositAmount);
    }

    // ============ INVARIANT TESTS ============

    /// @dev Test que verifica que el balance total nunca sea negativo
    function test_Invariant_TotalBalanceNeverNegative() public {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            address(0)
        );
        (, , , uint256 balance, , ) = _getUserInfo(user1);
        assertGe(balance, 0);

        vm.prank(user1);
        apyExtra.withdraw(TEST_DEPOSIT_AMOUNT);

        (, , , balance, , ) = _getUserInfo(user1);
        assertEq(balance, 0);
    }

    /// @dev Test que verifica la consistencia del balance de referidos
    function test_Invariant_ReferralBalanceConsistency() public {
        _setupReferralScenario();

        assertEq(apyExtra.referralTotalBalance(referrerAddr), 3000 ether);

        vm.prank(user1);
        apyExtra.withdraw(TEST_DEPOSIT_AMOUNT);

        assertEq(apyExtra.referralTotalBalance(referrerAddr), 2000 ether);
    }
}
