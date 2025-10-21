// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/APYExtra.sol";
import "../src/mocks/MockTokenConverter.sol";
import "../src/mocks/MockERC20.sol";

contract APYExtraTest is Test {
    APYExtra public apyExtra;
    MockTokenConverter public converter;

    // Test addresses
    address public admin = makeAddr("admin");
    address public rebalancer = makeAddr("rebalancer");
    address public apyManager = makeAddr("apyManager");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public referrer = makeAddr("referrer");
    address public attacker = makeAddr("attacker");

    // Test parameters
    uint256 public constant INITIAL_REFERRAL_APY = 100; // 10%
    uint256 public constant TEST_DEPOSIT_AMOUNT = 1000 ether;
    uint256 public constant TEST_EXTRA_APY = 20; // 2%
    uint256 public constant TEST_EXPIRATION = 365 days;

    // Mock tokens
    address public sourceToken = makeAddr("sourceToken");
    address public targetToken = makeAddr("targetToken");

    function setUp() public {
        vm.startPrank(admin);

        // Deploy mock tokens
        MockERC20 source = new MockERC20("SourceToken", "SRC");
        MockERC20 target = new MockERC20("TargetToken", "TGT");

        // Deploy converter
        converter = new MockTokenConverter(address(source), address(target));

        // Mint tokens to converter for testing
        target.mint(address(converter), 1_000_000 ether);

        // Deploy APYExtra
        apyExtra = new APYExtra(
            admin,
            INITIAL_REFERRAL_APY,
            address(converter)
        );

        // Roles
        apyExtra.grantRole(apyExtra.REBALANCER_ROLE(), rebalancer);
        apyExtra.grantRole(apyExtra.APY_MANAGER_ROLE(), apyManager);

        vm.stopPrank();
    }

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

    // ============ CONSTRUCTOR AND SETUP TESTS ============

    function test_Constructor_InitialState() public view {
        assertEq(apyExtra.referralAPY(), INITIAL_REFERRAL_APY);
        assertTrue(apyExtra.apyEnabled());
        assertEq(address(apyExtra.tokenConverter()), address(converter));
        assertTrue(apyExtra.hasRole(apyExtra.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Constructor_ZeroAdmin() public {
        vm.expectRevert(APYExtra.InvalidAdmin.selector);
        new APYExtra(address(0), INITIAL_REFERRAL_APY, address(converter));
    }

    // ============ DEPOSIT TESTS ============

    function test_Deposit_WithoutReferrer() public {
        uint256 amount = _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            block.timestamp + TEST_EXPIRATION,
            address(0)
        );

        (
            ,
            uint256 lastUpdate,
            uint256 apy,
            uint256 balance,
            uint256 accumulated,
            address ref
        ) = apyExtra.userInfo(user1);

        assertEq(balance, amount);
        assertEq(apy, TEST_EXTRA_APY);
        assertEq(ref, address(0));
        assertEq(accumulated, 0);
        assertEq(lastUpdate, block.timestamp);
    }

    function test_Deposit_WithReferrer() public {
        uint256 amount = _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            block.timestamp + TEST_EXPIRATION,
            referrer
        );

        (, , , uint256 balance, , address actualReferrer) = apyExtra.userInfo(
            user1
        );

        assertEq(balance, amount);
        assertEq(actualReferrer, referrer);

        // Check referrer was recorded
        (uint256 refLastUpdate, ) = apyExtra.referralInfo(referrer);
        assertEq(refLastUpdate, block.timestamp);
    }

    function test_Deposit_ZeroAmount() public {
        vm.prank(rebalancer);
        apyExtra.deposit(user1, TEST_EXPIRATION, TEST_EXTRA_APY, 0);

        (, , , uint256 balance, , ) = apyExtra.userInfo(user1);
        assertEq(balance, 0);
    }

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

    function test_Deposit_UpdateAPY_OnlyIfHigher() public {
        // First deposit with lower APY
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            50,
            TEST_EXPIRATION,
            address(0)
        );

        // Second deposit with higher APY
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            150,
            TEST_EXPIRATION,
            address(0)
        );

        (, , uint256 actualAPY, , , ) = apyExtra.userInfo(user1);
        assertEq(actualAPY, 150); // Should update to higher APY

        // Third deposit with lower APY
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            100,
            TEST_EXPIRATION,
            address(0)
        );

        (, , actualAPY, , , ) = apyExtra.userInfo(user1);
        assertEq(actualAPY, 150); // Should keep the higher APY
    }

    // ============ WITHDRAW TESTS ============

    function test_Withdraw_NormalFlow() public {
        uint256 depositAmount = _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            block.timestamp + TEST_EXPIRATION,
            address(0)
        );

        vm.prank(user1);
        uint256 convertedAmount = apyExtra.withdraw(depositAmount);

        (, , , uint256 balanceAfter, , ) = apyExtra.userInfo(user1);
        assertEq(balanceAfter, 0);
        assertEq(convertedAmount, depositAmount);
    }

    function test_Withdraw_ZeroAmount() public {
        vm.prank(user1);
        uint256 result = apyExtra.withdraw(0);
        assertEq(result, 0);
    }

    function test_Withdraw_InsufficientBalance() public {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            address(0)
        );

        vm.prank(user1);
        vm.expectRevert(APYExtra.InsufficientBalance.selector);
        apyExtra.withdraw(TEST_DEPOSIT_AMOUNT + 1);
    }

    function test_Withdraw_WithoutConverter() public {
        vm.prank(admin);
        vm.expectRevert(APYExtra.InvalidConverter.selector);
        apyExtra.setTokenConverter(address(0));
    }

    function test_Withdraw_ConversionFailed() public {
        // Setup - Depositar fondos
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            address(0)
        );

        // Crear un converter que falle
        MockTokenConverter failingConverter = new MockTokenConverter(
            address(0),
            address(0)
        );
        vm.prank(admin);
        apyExtra.setTokenConverter(address(failingConverter));

        // Intentar withdraw debería fallar
        vm.prank(user1);
        vm.expectRevert(APYExtra.ConversionFailed.selector);
        apyExtra.withdraw(TEST_DEPOSIT_AMOUNT);

        // Balance debería mantenerse intacto
        (, , , uint256 balance, , ) = apyExtra.userInfo(user1);
        assertEq(balance, TEST_DEPOSIT_AMOUNT);
    }

    function test_Withdraw_AccumulatesEarnings() public {
        uint256 depositAmount = _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            block.timestamp + TEST_EXPIRATION,
            address(0)
        );

        // Warp 30 days to accumulate earnings
        _warpAndAccumulate(user1, 30 days);

        uint256 expectedEarnings = apyExtra.getLastEarnings(user1);

        vm.prank(user1);
        apyExtra.withdraw(depositAmount);

        (, , , , uint256 accumulated, ) = apyExtra.userInfo(user1);
        assertEq(accumulated, expectedEarnings);
    }

    // ============ EARNINGS CALCULATION TESTS ============

    function test_GetLastEarnings_BasicCalculation() public {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            block.timestamp + 365 days,
            address(0)
        );

        // 30 days at 10% APY on 1000 tokens
        _warpAndAccumulate(user1, 30 days);

        uint256 expected = (TEST_DEPOSIT_AMOUNT * TEST_EXTRA_APY * 30 days) /
            (apyExtra.APY_DENOMINATOR() * 365 days);
        uint256 actual = apyExtra.getLastEarnings(user1);

        assertEq(actual, expected);
    }

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

    function test_GetLastEarnings_Expired() public {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            block.timestamp + 10 days,
            address(0)
        );

        // Warp past expiration
        _warpAndAccumulate(user1, 20 days);

        uint256 earnings = apyExtra.getLastEarnings(user1);
        // Should only earn for 10 days until expiration
        uint256 expected = (TEST_DEPOSIT_AMOUNT * TEST_EXTRA_APY * 10 days) /
            (apyExtra.APY_DENOMINATOR() * 365 days);

        assertEq(earnings, expected);
    }

    function test_GetLastEarnings_ZeroBalance() public view {
        uint256 earnings = apyExtra.getLastEarnings(user1);
        assertEq(earnings, 0);
    }

    // ============ SET TOKEN CONVERTER TESTS ============

    function test_SetTokenConverter_OnlyAdmin() public {
        address newConverter = address(
            new MockTokenConverter(sourceToken, targetToken)
        );

        vm.prank(admin);
        apyExtra.setTokenConverter(newConverter);

        assertEq(address(apyExtra.tokenConverter()), newConverter);
    }

    function test_SetTokenConverter_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(APYExtra.InvalidConverter.selector);
        apyExtra.setTokenConverter(address(0));
    }

    function test_SetTokenConverter_NonAdmin() public {
        address newConverter = address(
            new MockTokenConverter(sourceToken, targetToken)
        );

        vm.prank(attacker);
        vm.expectRevert();
        apyExtra.setTokenConverter(newConverter);
    }

    // ============ REFERRAL SYSTEM TESTS ============

    function test_ReferralEarnings_Basic() public {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            referrer
        );

        _warpAndAccumulate(referrer, 30 days);

        uint256 expected = (TEST_DEPOSIT_AMOUNT *
            INITIAL_REFERRAL_APY *
            30 days) / (apyExtra.APY_DENOMINATOR() * 365 days);
        uint256 actual = apyExtra.getReferralsEarnings(referrer);

        assertEq(actual, expected);
    }

    function test_ReferralEarnings_MultipleReferrals() public {
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            referrer
        );
        _depositForUser(
            user2,
            TEST_DEPOSIT_AMOUNT * 2,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            referrer
        );

        _warpAndAccumulate(referrer, 30 days);

        uint256 totalRefBalance = TEST_DEPOSIT_AMOUNT +
            (TEST_DEPOSIT_AMOUNT * 2);
        uint256 expected = (totalRefBalance * INITIAL_REFERRAL_APY * 30 days) /
            (apyExtra.APY_DENOMINATOR() * 365 days);
        uint256 actual = apyExtra.getReferralsEarnings(referrer);

        assertEq(actual, expected);
    }

    function test_Referral_OnlySetOnFirstDeposit() public {
        // First deposit sets referrer
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            referrer
        );

        // Second deposit with different referrer should not change
        _depositForUser(
            user1,
            TEST_DEPOSIT_AMOUNT,
            TEST_EXTRA_APY,
            TEST_EXPIRATION,
            user2
        );

        (, , , , , address actualReferrer) = apyExtra.userInfo(user1);
        assertEq(actualReferrer, referrer); // Should remain first referrer
    }
}
