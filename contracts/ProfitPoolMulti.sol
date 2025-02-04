// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./AIVaultFactory.sol";

/**
 * @title ProfitPoolMulti
 * @notice Manages profit distribution and claiming for multiple AI vaults
 * @dev Implements profit tracking per vault, claiming, and optional lockup periods
 */
contract ProfitPoolMulti is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    // State variables
    IERC20 public immutable asset;
    uint256 public lockupPeriod;
    uint256 public earlyWithdrawalFee; // In basis points
    address public revenuePool;
    AIVaultFactory public vaultFactory;

    struct UserVaultInfo {
        uint256 claimableAmount;
        uint256 lastProfitTimestamp;
    }

    // User => Vault => Info
    mapping(address => mapping(address => UserVaultInfo)) public userVaultInfo;
    // User => Total claimable across all vaults
    mapping(address => uint256) public totalUserClaimable;

    // Events
    event ProfitDistributed(address indexed vault, address indexed user, uint256 amount);
    event ProfitClaimed(address indexed user, uint256 amount, uint256 fee);
    event ProfitReinvested(address indexed vault, address indexed user, uint256 amount);
    event LockupPeriodUpdated(uint256 newPeriod);
    event EarlyWithdrawalFeeUpdated(uint256 newFee);

    /**
     * @dev Constructor
     * @param _asset The ERC20 token used for profits
     * @param _revenuePool Address where early withdrawal fees are sent
     * @param _lockupPeriod Initial lockup period in seconds
     * @param _earlyWithdrawalFee Fee in basis points (e.g., 500 = 5%)
     * @param _vaultFactory Address of the AIVaultFactory contract
     */
    constructor(
        IERC20 _asset,
        address _revenuePool,
        uint256 _lockupPeriod,
        uint256 _earlyWithdrawalFee,
        address _vaultFactory
    ) {
        require(address(_asset) != address(0), "Invalid asset address");
        require(_revenuePool != address(0), "Invalid revenue pool address");
        require(_vaultFactory != address(0), "Invalid vault factory address");
        require(_earlyWithdrawalFee <= 1000, "Fee too high"); // Max 10%

        asset = _asset;
        revenuePool = _revenuePool;
        lockupPeriod = _lockupPeriod;
        earlyWithdrawalFee = _earlyWithdrawalFee;
        vaultFactory = AIVaultFactory(_vaultFactory);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Distributes profits to a user from a specific vault
     * @param user Address of the user
     * @param amount Amount of profits to distribute
     */
    function distributeProfits(address user, uint256 amount) 
        external 
        onlyRole(VAULT_ROLE) 
    {
        require(user != address(0), "Invalid user address");
        require(amount > 0, "Cannot distribute 0");

        UserVaultInfo storage info = userVaultInfo[user][msg.sender];
        info.claimableAmount += amount;
        info.lastProfitTimestamp = block.timestamp;
        totalUserClaimable[user] += amount;

        emit ProfitDistributed(msg.sender, user, amount);
    }

    /**
     * @notice Claims accumulated profits from all vaults
     * @param amount Amount to claim
     */
    function claim(uint256 amount) external nonReentrant {
        require(amount <= totalUserClaimable[msg.sender], "Insufficient claimable amount");

        uint256 remainingToClaim = amount;
        uint256 totalFee = 0;

        // Claim from each vault proportionally
        address[] memory activeVaults = getActiveVaults();
        for (uint i = 0; i < activeVaults.length && remainingToClaim > 0; i++) {
            address vault = activeVaults[i];
            UserVaultInfo storage info = userVaultInfo[msg.sender][vault];
            
            if (info.claimableAmount > 0) {
                uint256 vaultClaimAmount = Math.min(
                    remainingToClaim,
                    info.claimableAmount
                );

                uint256 fee = 0;
                if (block.timestamp < info.lastProfitTimestamp + lockupPeriod) {
                    fee = (vaultClaimAmount * earlyWithdrawalFee) / 10000;
                }

                info.claimableAmount -= vaultClaimAmount;
                totalUserClaimable[msg.sender] -= vaultClaimAmount;
                remainingToClaim -= vaultClaimAmount;
                totalFee += fee;
            }
        }

        uint256 netAmount = amount - totalFee;

        if (totalFee > 0) {
            asset.safeTransfer(revenuePool, totalFee);
        }
        asset.safeTransfer(msg.sender, netAmount);

        emit ProfitClaimed(msg.sender, netAmount, totalFee);
    }

    /**
     * @notice Reinvests profits back into a specific vault
     * @param vault Address of the vault to reinvest in
     * @param amount Amount to reinvest
     */
    function reinvest(address vault, uint256 amount) external nonReentrant {
        UserVaultInfo storage info = userVaultInfo[msg.sender][vault];
        require(amount <= info.claimableAmount, "Insufficient claimable amount");

        info.claimableAmount -= amount;
        totalUserClaimable[msg.sender] -= amount;
        
        // Approve vault to spend tokens
        asset.approve(vault, amount);
        
        emit ProfitReinvested(vault, msg.sender, amount);
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
     * @notice Returns the claimable amount for a user from a specific vault
     * @param user Address of the user
     * @param vault Address of the vault
     */
    function getVaultClaimableAmount(address user, address vault) external view returns (uint256) {
        return userVaultInfo[user][vault].claimableAmount;
    }

    /**
     * @notice Returns all active vaults that the user has profits in
     */
    function getActiveVaults() public view returns (address[] memory) {
        AIVaultFactory.VaultInfo[] memory allVaults = vaultFactory.getActiveVaults();
        
        // First, count vaults where user has profits
        uint256 count = 0;
        for (uint i = 0; i < allVaults.length; i++) {
            if (userVaultInfo[msg.sender][allVaults[i].vaultAddress].claimableAmount > 0) {
                count++;
            }
        }

        // Create array of vault addresses where user has profits
        address[] memory activeVaults = new address[](count);
        uint256 currentIndex = 0;
        for (uint i = 0; i < allVaults.length; i++) {
            if (userVaultInfo[msg.sender][allVaults[i].vaultAddress].claimableAmount > 0) {
                activeVaults[currentIndex] = allVaults[i].vaultAddress;
                currentIndex++;
            }
        }

        return activeVaults;
    }

    /**
     * @notice Checks if a user's profits are still in the lockup period for a specific vault
     * @param user Address of the user
     * @param vault Address of the vault
     */
    function isInLockupPeriod(address user, address vault) external view returns (bool) {
        return block.timestamp < userVaultInfo[user][vault].lastProfitTimestamp + lockupPeriod;
    }
}
