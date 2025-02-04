// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title ProfitPool
 * @notice Manages profit distribution and claiming for AIVault users
 * @dev Implements profit tracking, claiming, and optional lockup periods
 */
contract ProfitPoolSimple is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // State variables
    IERC20 public immutable asset;
    uint256 public lockupPeriod;
    uint256 public earlyWithdrawalFee; // In basis points
    address public revenuePool;

    struct UserInfo {
        uint256 claimableAmount;
        uint256 lastProfitTimestamp;
    }

    mapping(address => UserInfo) public userInfo;

    // Events
    event ProfitDistributed(address indexed user, uint256 amount);
    event ProfitClaimed(address indexed user, uint256 amount, uint256 fee);
    event ProfitReinvested(address indexed user, uint256 amount);
    event LockupPeriodUpdated(uint256 newPeriod);
    event EarlyWithdrawalFeeUpdated(uint256 newFee);

    /**
     * @dev Constructor
     * @param _asset The ERC20 token used for profits
     * @param _revenuePool Address where early withdrawal fees are sent
     * @param _lockupPeriod Initial lockup period in seconds
     * @param _earlyWithdrawalFee Fee in basis points (e.g., 500 = 5%)
     */
    constructor(
        IERC20 _asset,
        address _revenuePool,
        uint256 _lockupPeriod,
        uint256 _earlyWithdrawalFee
    ) {
        require(address(_asset) != address(0), "Invalid asset address");
        require(_revenuePool != address(0), "Invalid revenue pool address");
        require(_earlyWithdrawalFee <= 1000, "Fee too high"); // Max 10%

        asset = _asset;
        revenuePool = _revenuePool;
        lockupPeriod = _lockupPeriod;
        earlyWithdrawalFee = _earlyWithdrawalFee;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Distributes profits to a user
     * @param user Address of the user
     * @param amount Amount of profits to distribute
     */
    function distributeProfits(address user, uint256 amount) 
        external 
        onlyRole(VAULT_ROLE) 
    {
        require(user != address(0), "Invalid user address");
        require(amount > 0, "Cannot distribute 0");

        UserInfo storage info = userInfo[user];
        info.claimableAmount += amount;
        info.lastProfitTimestamp = block.timestamp;

        emit ProfitDistributed(user, amount);
    }

    /**
     * @notice Claims accumulated profits
     * @param amount Amount to claim
     */
    function claim(uint256 amount) external nonReentrant {
        UserInfo storage info = userInfo[msg.sender];
        require(amount <= info.claimableAmount, "Insufficient claimable amount");

        uint256 fee = 0;
        if (block.timestamp < info.lastProfitTimestamp + lockupPeriod) {
            fee = (amount * earlyWithdrawalFee) / 10000;
        }

        uint256 netAmount = amount - fee;
        info.claimableAmount -= amount;

        if (fee > 0) {
            asset.safeTransfer(revenuePool, fee);
        }
        asset.safeTransfer(msg.sender, netAmount);

        emit ProfitClaimed(msg.sender, netAmount, fee);
    }

    /**
     * @notice Reinvests profits back into the vault
     * @param amount Amount to reinvest
     */
    function reinvest(uint256 amount) external nonReentrant {
        UserInfo storage info = userInfo[msg.sender];
        require(amount <= info.claimableAmount, "Insufficient claimable amount");

        info.claimableAmount -= amount;
        
        // Approve AIVault to spend tokens
        asset.approve(msg.sender, amount);
        
        emit ProfitReinvested(msg.sender, amount);
    }

    /**
     * @notice Updates the lockup period
     * @param newPeriod New lockup period in seconds
     */
    function setLockupPeriod(uint256 newPeriod) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        lockupPeriod = newPeriod;
        emit LockupPeriodUpdated(newPeriod);
    }

    /**
     * @notice Updates the early withdrawal fee
     * @param newFee New fee in basis points
     */
    function setEarlyWithdrawalFee(uint256 newFee) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        require(newFee <= 1000, "Fee too high"); // Max 10%
        earlyWithdrawalFee = newFee;
        emit EarlyWithdrawalFeeUpdated(newFee);
    }

    /**
     * @notice Returns the claimable amount for a user
     * @param user Address of the user
     */
    function getClaimableAmount(address user) external view returns (uint256) {
        return userInfo[user].claimableAmount;
    }

    /**
     * @notice Checks if a user's profits are still in the lockup period
     * @param user Address of the user
     */
    function isInLockupPeriod(address user) external view returns (bool) {
        return block.timestamp < userInfo[user].lastProfitTimestamp + lockupPeriod;
    }
}
