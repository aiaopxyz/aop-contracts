// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title AIVaultSimple
 * @notice A vault contract that allows users to deposit assets and have them managed by an AI agent
 * @dev Implements share token system and performance fee calculation
 */
contract AIVaultSimple is ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Roles
    bytes32 public constant AI_AGENT_ROLE = keccak256("AI_AGENT_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // Strategy configuration
    struct Strategy {
        uint256 maxDrawdown;        // Maximum allowed loss in basis points
        uint256 targetReturn;       // Target annual return in basis points
        uint256 rebalanceInterval;  // How often to rebalance in seconds
        address[] allowedProtocols; // Whitelisted protocols to interact with
        bool isActive;              // Whether this strategy is currently active
    }

    // Vault metrics for tracking performance and risk
    struct VaultMetrics {
        uint256 tvl;               // Total value locked
        uint256 apy;               // Annual percentage yield in basis points
        uint256 userCount;         // Number of users
        uint256 totalProfits;      // Total profits generated
        uint256 performanceFees;   // Total performance fees collected
        uint256 highWaterMark;     // Highest value achieved
        uint256 lastRebalance;     // Timestamp of last rebalance
        uint256 maxDrawdown;       // Maximum drawdown experienced
        bool isEmergency;          // Whether vault is in emergency state
    }

    // User metrics for tracking individual performance
    struct UserMetrics {
        uint256 totalDeposited;    // Total amount user has deposited
        uint256 totalWithdrawn;    // Total amount user has withdrawn
        uint256 lastDepositAmount; // Amount of last deposit
        uint256 lastWithdrawAmount;// Amount of last withdrawal
        uint256 depositCount;      // Number of deposits made
        uint256 withdrawCount;     // Number of withdrawals made
        uint256 firstDepositTime;  // Timestamp of first deposit
        uint256 lastDepositTime;   // Timestamp of last deposit
        uint256 lastWithdrawTime;  // Timestamp of last withdrawal
        uint256 highWaterMark;     // User's highest asset value
        uint256 realizedProfits;   // Total profits realized through withdrawals
        bool isActive;             // Whether user has active deposits
    }

    // State variables
    IERC20 public immutable asset;
    address public immutable revenuePool;
    address public immutable profitPool;
    Strategy public currentStrategy;
    VaultMetrics public metrics;

    uint256 public constant PERFORMANCE_FEE_PERCENTAGE = 2000; // 20% in basis points
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant EMERGENCY_WITHDRAWAL_FEE = 100; // 1% in basis points

    uint256 public totalShares;
    uint256 public totalAssets;
    mapping(address => uint256) public shares;
    mapping(address => UserMetrics) public userMetrics;

    // Events
    event Deposit(address indexed user, uint256 assets, uint256 shares);
    event Withdraw(address indexed user, uint256 assets, uint256 shares);
    event ProfitRealized(uint256 profit, uint256 performanceFee);
    event TradeExecuted(address indexed target, bytes data);
    event StrategyUpdated(uint256 maxDrawdown, uint256 targetReturn, uint256 rebalanceInterval);
    event ProtocolWhitelisted(address indexed protocol, bool status);
    event EmergencyStateActivated();
    event EmergencyStateDeactivated();
    event EmergencyWithdrawal(address indexed user, uint256 amount, uint256 fee);
    event MetricsUpdated(uint256 tvl, uint256 apy, uint256 totalProfits);
    event UserMetricsUpdated(
        address indexed user,
        uint256 totalDeposited,
        uint256 totalWithdrawn,
        uint256 realizedProfits
    );

    /**
     * @dev Constructor
     */
    constructor(
        IERC20 _asset,
        address _revenuePool,
        address _profitPool
    ) {
        require(address(_asset) != address(0), "Invalid asset address");
        require(_revenuePool != address(0), "Invalid revenue pool address");
        require(_profitPool != address(0), "Invalid profit pool address");

        asset = _asset;
        revenuePool = _revenuePool;
        profitPool = _profitPool;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        
        // Initialize metrics
        metrics.lastRebalance = block.timestamp;
    }

    /**
     * @notice Deposits assets and mints shares
     * @param amount Amount of assets to deposit
     */
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Cannot deposit 0");
        
        uint256 shares_ = totalShares == 0 
            ? amount 
            : amount * totalShares / totalAssets;
            
        require(shares_ > 0, "Zero shares");

        totalShares += shares_;
        shares[msg.sender] += shares_;
        totalAssets += amount;

        // Update user metrics
        UserMetrics storage userMetric = userMetrics[msg.sender];
        if (!userMetric.isActive) {
            userMetric.firstDepositTime = block.timestamp;
            userMetric.isActive = true;
            metrics.userCount++;
        }
        userMetric.totalDeposited += amount;
        userMetric.lastDepositAmount = amount;
        userMetric.lastDepositTime = block.timestamp;
        userMetric.depositCount++;

        // Update high water mark if necessary
        uint256 userAssetValue = getAssetValueOfShares(shares[msg.sender]);
        if (userAssetValue > userMetric.highWaterMark) {
            userMetric.highWaterMark = userAssetValue;
        }

        // Update metrics
        metrics.tvl = totalAssets;

        asset.safeTransferFrom(msg.sender, address(this), amount);
        
        emit Deposit(msg.sender, amount, shares_);
        emit UserMetricsUpdated(
            msg.sender,
            userMetric.totalDeposited,
            userMetric.totalWithdrawn,
            userMetric.realizedProfits
        );
    }

    /**
     * @notice Withdraws assets by burning shares
     * @param shareAmount Amount of shares to burn
     */
    function withdraw(uint256 shareAmount) external nonReentrant whenNotPaused {
        require(shareAmount > 0, "Cannot withdraw 0");
        require(shareAmount <= shares[msg.sender], "Insufficient shares");

        uint256 assets = shareAmount * totalAssets / totalShares;
        
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        totalAssets -= assets;

        // Update user metrics
        UserMetrics storage userMetric = userMetrics[msg.sender];
        userMetric.totalWithdrawn += assets;
        userMetric.lastWithdrawAmount = assets;
        userMetric.lastWithdrawTime = block.timestamp;
        userMetric.withdrawCount++;

        // Calculate realized profits
        if (assets > userMetric.totalDeposited - userMetric.totalWithdrawn) {
            uint256 profit = assets - (userMetric.totalDeposited - userMetric.totalWithdrawn);
            userMetric.realizedProfits += profit;
        }

        // Update active status
        if (shares[msg.sender] == 0) {
            userMetric.isActive = false;
            metrics.userCount--;
        }

        // Update metrics
        metrics.tvl = totalAssets;

        asset.safeTransfer(msg.sender, assets);
        
        emit Withdraw(msg.sender, assets, shareAmount);
        emit UserMetricsUpdated(
            msg.sender,
            userMetric.totalDeposited,
            userMetric.totalWithdrawn,
            userMetric.realizedProfits
        );
    }

    /**
     * @notice Emergency withdrawal function
     */
    function emergencyWithdraw() external nonReentrant whenPaused {
        require(metrics.isEmergency, "Not in emergency state");
        uint256 shareAmount = shares[msg.sender];
        require(shareAmount > 0, "No shares to withdraw");

        uint256 assets = shareAmount * totalAssets / totalShares;
        uint256 fee = (assets * EMERGENCY_WITHDRAWAL_FEE) / BASIS_POINTS;
        uint256 netAmount = assets - fee;

        shares[msg.sender] = 0;
        totalShares -= shareAmount;
        totalAssets -= assets;

        // Transfer fee to revenue pool
        if (fee > 0) {
            asset.safeTransfer(revenuePool, fee);
        }
        
        // Transfer remaining assets to user
        asset.safeTransfer(msg.sender, netAmount);

        emit EmergencyWithdrawal(msg.sender, netAmount, fee);
    }

    /**
     * @notice Updates the investment strategy
     */
    function updateStrategy(
        uint256 _maxDrawdown,
        uint256 _targetReturn,
        uint256 _rebalanceInterval,
        address[] calldata _allowedProtocols
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_maxDrawdown <= BASIS_POINTS, "Invalid maxDrawdown");
        require(_targetReturn <= BASIS_POINTS * 100, "Invalid targetReturn"); // Max 1000% APY
        require(_rebalanceInterval >= 1 days, "Invalid rebalance interval");

        currentStrategy.maxDrawdown = _maxDrawdown;
        currentStrategy.targetReturn = _targetReturn;
        currentStrategy.rebalanceInterval = _rebalanceInterval;
        currentStrategy.allowedProtocols = _allowedProtocols;
        currentStrategy.isActive = true;

        emit StrategyUpdated(_maxDrawdown, _targetReturn, _rebalanceInterval);
    }

    /**
     * @notice Executes a trade through the AI agent
     */
    function executeTrade(
        address target,
        bytes calldata data
    ) external onlyRole(AI_AGENT_ROLE) whenNotPaused {
        require(target != address(0), "Invalid target");
        require(isProtocolAllowed(target), "Protocol not whitelisted");
        require(
            block.timestamp >= metrics.lastRebalance + currentStrategy.rebalanceInterval,
            "Rebalance too soon"
        );
        
        uint256 balanceBefore = asset.balanceOf(address(this));
        
        // Execute the trade
        (bool success, ) = target.call(data);
        require(success, "Trade execution failed");
        
        uint256 balanceAfter = asset.balanceOf(address(this));
        require(balanceAfter >= balanceBefore, "Trade resulted in loss");
        
        // Check drawdown limit
        if (balanceAfter < metrics.highWaterMark) {
            uint256 drawdown = ((metrics.highWaterMark - balanceAfter) * BASIS_POINTS) / metrics.highWaterMark;
            require(drawdown <= currentStrategy.maxDrawdown, "Exceeds max drawdown");
            metrics.maxDrawdown = Math.max(metrics.maxDrawdown, drawdown);
        } else {
            metrics.highWaterMark = balanceAfter;
        }

        if (balanceAfter > balanceBefore) {
            uint256 profit = balanceAfter - balanceBefore;
            uint256 performanceFee = (profit * PERFORMANCE_FEE_PERCENTAGE) / BASIS_POINTS;
            
            // Update metrics
            metrics.totalProfits += profit;
            metrics.performanceFees += performanceFee;
            metrics.lastRebalance = block.timestamp;
            
            // Calculate APY
            uint256 timeDiff = block.timestamp - metrics.lastRebalance;
            if (timeDiff >= 1 days) {
                metrics.apy = (profit * BASIS_POINTS * 365 days) / (totalAssets * timeDiff);
            }
            
            // Update total assets
            totalAssets = balanceAfter;
            
            // Transfer performance fee to revenue pool
            if (performanceFee > 0) {
                asset.safeTransfer(revenuePool, performanceFee);
                totalAssets -= performanceFee;
            }
            
            // Transfer remaining profit to profit pool
            uint256 remainingProfit = profit - performanceFee;
            if (remainingProfit > 0) {
                asset.safeTransfer(profitPool, remainingProfit);
                totalAssets -= remainingProfit;
            }
            
            emit ProfitRealized(profit, performanceFee);
        }
        
        emit TradeExecuted(target, data);
        emit MetricsUpdated(metrics.tvl, metrics.apy, metrics.totalProfits);
    }

    /**
     * @notice Emergency functions
     */
    function activateEmergencyState() external onlyRole(EMERGENCY_ROLE) {
        metrics.isEmergency = true;
        _pause();
        emit EmergencyStateActivated();
    }

    function deactivateEmergencyState() external onlyRole(EMERGENCY_ROLE) {
        metrics.isEmergency = false;
        _unpause();
        emit EmergencyStateDeactivated();
    }

    /**
     * @notice Checks if a protocol is whitelisted
     */
    function isProtocolAllowed(address protocol) public view returns (bool) {
        if (!currentStrategy.isActive) return false;
        for (uint i = 0; i < currentStrategy.allowedProtocols.length; i++) {
            if (currentStrategy.allowedProtocols[i] == protocol) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Returns the asset value of shares
     */
    function getAssetValueOfShares(uint256 shareAmount) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return shareAmount * totalAssets / totalShares;
    }

    /**
     * @notice Returns the total value of a user's shares
     */
    function getUserAssetValue(address user) external view returns (uint256) {
        return getAssetValueOfShares(shares[user]);
    }
}
