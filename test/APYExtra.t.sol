// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/APYExtra.sol";
import "../src/mocks/MockTokenConverter.sol";

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
        // Setup roles
        vm.startPrank(admin);

        // Deploy converter
        converter = new MockTokenConverter(sourceToken, targetToken);

        // Deploy main contract
        apyExtra = new APYExtra(
            admin,
            INITIAL_REFERRAL_APY,
            address(converter)
        );

        // Setup roles
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
}
