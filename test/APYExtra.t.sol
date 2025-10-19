// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/APYExtra.sol";

contract APYExtraTest is Test {
    APYExtra apyExtra;
    address admin;
    address user;
    address referrer;
    address other;

    uint256 constant INITIAL_REFERRAL_APY = 50;
    uint256 constant ONE_YEAR = 365 days;

    // Expose same constants locally for expected computations
    uint256 constant PRECISION = 1000 ether;
    uint256 constant APY_DENOMINATOR = 1000;

    function setUp() public {
        admin = address(this);
        user = address(0x1);
        referrer = address(0x2);
        other = address(0x3);

        apyExtra = new APYExtra(admin, INITIAL_REFERRAL_APY);
    }

    /* ---------------------------
       Helpers
       --------------------------- */

    // Mirror the contract's getLastEarnings formula to compute expected values
    function expectedLastEarnings(
        uint256 principal,
        uint256 extraAPY,
        uint256 timeDelta
    ) internal pure returns (uint256) {
        if (principal == 0 || extraAPY == 0 || timeDelta == 0) return 0;
        uint256 numeratorAddition = (extraAPY * 1 ether * timeDelta) /
            (APY_DENOMINATOR * ONE_YEAR);
        return
            (principal * (PRECISION + numeratorAddition)) / 1 ether - principal;
    }
}
