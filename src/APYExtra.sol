// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title APYExtra
 * @notice Yield contract with extra APY and referral system
 * @dev Manages user deposits, withdrawals, and earnings calculation with referral rewards
 */
contract APYExtra is AccessControl {
    uint256 public constant PRECISION = 1000 ether;
    uint256 public constant YEAR = 365 days;
    uint256 public constant APY_DENOMINATOR = 1000;

    // Custom errors for gas efficiency
    error ZeroAmount();
    error InsufficientBalance();
    error InvalidAdmin();
    error CallerNotRebalancer();

    // Role definitions
    bytes32 public constant REBALANCER_ROLE = keccak256("REBALANCER_ROLE");
    bytes32 public constant APY_MANAGER_ROLE = keccak256("APY_MANAGER_ROLE");

    /**
     * @dev User information structure
     * @param expirationTime APY extra expiration timestamp
     * @param lastUpdateTime Last earnings calculation timestamp
     * @param extraAPY Additional APY rate for the user
     * @param balance Current user balance
     * @param accumulatedEarnings Total earnings accumulated
     * @param referrer Address that referred this user
     */
    struct UserInfo {
        uint256 expirationTime;
        uint256 lastUpdateTime;
        uint256 extraAPY;
        uint256 balance;
        uint256 accumulatedEarnings;
        address referrer;
    }

    /**
     * @dev Referral information structure
     * @param lastUpdateTime Last referral earnings calculation
     * @param accumulatedEarnings Total referral earnings accumulated
     * @param referrals List of referred addresses
     */
    struct ReferralInfo {
        uint256 lastUpdateTime;
        uint256 accumulatedEarnings;
        address[] referrals;
    }

    // Storage mappings
    mapping(address => UserInfo) public userInfo;
    mapping(address => ReferralInfo) public referralInfo;
    mapping(address => uint256) public referralTotalBalance;

    // Global state variables
    uint256 public referralAPY;
    bool public apyEnabled;

    // Events
    event Deposited(
        address indexed user,
        uint256 amount,
        uint256 extraAPY,
        address indexed referrer
    );
    event Withdrawn(address indexed user, uint256 amount);
    event ReferrerAssigned(address indexed user, address indexed referrer);

    /**
     * @dev Modifier to restrict access to rebalancer role
     */
    modifier onlyRebalancer() {
        if (!hasRole(REBALANCER_ROLE, msg.sender)) revert CallerNotRebalancer();
        _;
    }

    /**
     * @notice Initialize contract with admin and referral APY
     * @param admin Admin address with all roles
     * @param initialReferralAPY Global referral APY rate (e.g., 50 = 5%)
     */
    constructor(address admin, uint256 initialReferralAPY) {
        if (admin == address(0)) revert InvalidAdmin();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REBALANCER_ROLE, admin);
        _grantRole(APY_MANAGER_ROLE, admin);

        referralAPY = initialReferralAPY;
        apyEnabled = true;
    }

    /**
     * @notice Deposit funds without referrer
     * @dev Only callable by rebalancer role
     * @param user Address of the user depositing
     * @param expirationTime APY extra expiration time
     * @param extraAPY Additional APY for the user
     * @param amount Amount to deposit
     */
    function deposit(
        address user,
        uint256 expirationTime,
        uint256 extraAPY,
        uint256 amount
    ) external onlyRebalancer {
        _executeDeposit(user, expirationTime, extraAPY, amount, address(0));
    }

    /**
     * @notice Deposit funds with optional referrer
     * @dev Only callable by rebalancer role. Referrer can only be set on first deposit.
     * @param user Address of the user depositing
     * @param expirationTime APY extra expiration time
     * @param extraAPY Additional APY for the user
     * @param amount Amount to deposit
     * @param referrer Address of the referrer (optional)
     */
    function deposit(
        address user,
        uint256 expirationTime,
        uint256 extraAPY,
        uint256 amount,
        address referrer
    ) external onlyRebalancer {
        _executeDeposit(user, expirationTime, extraAPY, amount, referrer);
    }

    /**
     * @notice Withdraw funds after accumulating earnings
     * @dev Accumulates user earnings and referrer's earnings before withdrawal
     * @param amount Amount to withdraw
     * @return amount Returns the withdrawn amount for external handling
     */
    function withdraw(uint256 amount) external returns (uint256) {
        if (amount == 0) revert ZeroAmount();

        address user = msg.sender;
        UserInfo storage userData = userInfo[user];

        if (userData.balance < amount) revert InsufficientBalance();

        // Accumulate all pending earnings before balance changes
        _accumulateUserAndReferrerEarnings(user);

        userData.balance -= amount;
        userData.lastUpdateTime = block.timestamp;

        // Update referrer's total balance if applicable
        if (userData.referrer != address(0)) {
            referralTotalBalance[userData.referrer] -= amount;
        }

        emit Withdrawn(user, amount);
        return amount;
    }

    /**
     * @notice Toggle APY system globally
     * @dev Only callable by APY manager role
     */
    function toggleAPY() external onlyRole(APY_MANAGER_ROLE) {
        apyEnabled = !apyEnabled;
    }

    /**
     * @notice Update global referral APY rate
     * @dev Only callable by APY manager role
     * @param newReferralAPY New referral APY rate
     */
    function updateReferralAPY(
        uint256 newReferralAPY
    ) external onlyRole(APY_MANAGER_ROLE) {
        referralAPY = newReferralAPY;
    }

    /**
     * @notice Calculate unclaimed earnings since last update
     * @dev Uses simplified APY formula: earnings = balance * APY * timeDelta / (APY_DENOMINATOR * YEAR)
     * @param user Address to calculate earnings for
     * @return Pending earnings since last update
     */
    function getLastEarnings(address user) public view returns (uint256) {
        UserInfo memory userData = userInfo[user];

        // Early return if conditions not met
        if (
            !apyEnabled ||
            userData.extraAPY == 0 ||
            userData.balance == 0 ||
            userData.lastUpdateTime == 0
        ) {
            return 0;
        }

        // Determine calculation time (current time or expiration if expired)
        uint256 calculationTime = (userData.expirationTime != 0 &&
            block.timestamp > userData.expirationTime)
            ? userData.expirationTime
            : block.timestamp;

        // Return 0 if no time has passed since last update
        if (calculationTime <= userData.lastUpdateTime) {
            return 0;
        }

        // Calculate earnings using simplified formula
        uint256 timeDelta = calculationTime - userData.lastUpdateTime;
        return
            (userData.balance * userData.extraAPY * timeDelta) /
            (APY_DENOMINATOR * YEAR);
    }

    /**
     * @notice Calculate total earnings (accumulated + pending)
     * @param user Address to calculate total earnings for
     * @return Total earnings including both accumulated and pending
     */
    function getTotalEarnings(address user) public view returns (uint256) {
        return userInfo[user].accumulatedEarnings + getLastEarnings(user);
    }

    /**
     * @notice Calculate referrer's pending earnings from referrals
     * @dev Uses global referral APY and total referral balance
     * @param referrer Address of the referrer
     * @return Pending referral earnings
     */
    function getReferralsEarnings(
        address referrer
    ) public view returns (uint256) {
        if (!apyEnabled || referralAPY == 0) return 0;

        ReferralInfo memory refData = referralInfo[referrer];
        uint256 totalRefBalance = referralTotalBalance[referrer];

        if (
            totalRefBalance == 0 ||
            refData.lastUpdateTime == 0 ||
            block.timestamp <= refData.lastUpdateTime
        ) {
            return 0;
        }

        uint256 timeDelta = block.timestamp - refData.lastUpdateTime;
        return
            (totalRefBalance * referralAPY * timeDelta) /
            (APY_DENOMINATOR * YEAR);
    }

    /**
     * @dev Internal function to accumulate earnings for user and their referrer
     * @param user Address to accumulate earnings for
     */
    function _accumulateUserAndReferrerEarnings(address user) internal {
        UserInfo storage userData = userInfo[user];

        // Accumulate user's personal earnings
        uint256 pendingUser = getLastEarnings(user);
        if (pendingUser > 0) {
            userData.accumulatedEarnings += pendingUser;
        }
        userData.lastUpdateTime = block.timestamp;

        // Accumulate referrer's earnings if user has a referrer
        address referrer = userData.referrer;
        if (referrer != address(0)) {
            ReferralInfo storage refData = referralInfo[referrer];
            uint256 pendingRef = getReferralsEarnings(referrer);
            if (pendingRef > 0) {
                refData.accumulatedEarnings += pendingRef;
            }
            refData.lastUpdateTime = block.timestamp;
        }
    }

    /**
     * @dev Internal function to execute deposit with proper state management
     * @param user User address making deposit
     * @param expirationTime APY extra expiration time
     * @param extraAPY Additional APY rate
     * @param amount Deposit amount
     * @param referrer Optional referrer address
     */
    function _executeDeposit(
        address user,
        uint256 expirationTime,
        uint256 extraAPY,
        uint256 amount,
        address referrer
    ) internal {
        if (amount == 0) revert ZeroAmount();

        // Accumulate existing earnings before state modifications
        _accumulateUserAndReferrerEarnings(user);

        UserInfo storage userData = userInfo[user];

        // Update APY and expiration only if new APY is higher
        if (extraAPY > userData.extraAPY) {
            userData.extraAPY = extraAPY;
            userData.expirationTime = expirationTime;
        }

        // Update user balance (removed unchecked for safety)
        userData.balance += amount;
        userData.lastUpdateTime = block.timestamp;

        // Assign referrer if provided and this is first deposit with referral
        if (
            referrer != address(0) &&
            userData.referrer == address(0) &&
            referrer != user
        ) {
            userData.referrer = referrer;
            referralInfo[referrer].referrals.push(user);

            // Initialize referrer's lastUpdateTime if first referral
            if (referralInfo[referrer].lastUpdateTime == 0) {
                referralInfo[referrer].lastUpdateTime = block.timestamp;
            }

            emit ReferrerAssigned(user, referrer);
        }

        // Update referrer's total balance if user has a referrer
        if (userData.referrer != address(0)) {
            referralTotalBalance[userData.referrer] += amount;
        }

        emit Deposited(user, amount, extraAPY, userData.referrer);
    }
}
