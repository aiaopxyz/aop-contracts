// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AIVaultSimple.sol";
import "./ProfitPoolMulti.sol";

/**
 * @title AIVaultFactory
 * @notice Factory contract for creating and managing multiple AI vaults with different risk tiers
 */
contract AIVaultFactory is AccessControl {
    enum RiskTier { LOW, MEDIUM, HIGH }

    struct VaultInfo {
        address vaultAddress;
        RiskTier riskTier;
        string name;
        bool isActive;
    }

    struct TierStrategy {
        uint256 maxDrawdown;        // Conservative: 5%, Moderate: 15%, Aggressive: 30%
        uint256 targetReturn;       // Conservative: 8%, Moderate: 15%, Aggressive: 25%
        uint256 rebalanceInterval;  // Conservative: 1 week, Moderate: 3 days, Aggressive: 1 day
        address[] allowedProtocols;
    }

    // State variables
    mapping(RiskTier => address) public vaultsByTier;
    mapping(address => VaultInfo) public vaultInfo;
    mapping(RiskTier => TierStrategy) public tierStrategies;
    address[] public allVaults;
    
    address public immutable revenuePool;
    address public immutable profitPool;
    IERC20 public immutable asset;

    // Events
    event VaultCreated(address indexed vaultAddress, RiskTier riskTier, string name);
    event VaultStatusUpdated(address indexed vaultAddress, bool isActive);
    event TierStrategyUpdated(RiskTier indexed tier, uint256 maxDrawdown, uint256 targetReturn, uint256 rebalanceInterval);
    event ProtocolsUpdated(RiskTier indexed tier, address[] protocols);

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

        // Initialize default strategies for each tier
        _initializeDefaultStrategies();
    }

    /**
     * @notice Creates a new vault with specified risk tier
     * @param riskTier Risk tier of the vault
     * @param name Name of the vault
     */
    function createVault(
        RiskTier riskTier,
        string memory name
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(vaultsByTier[riskTier] == address(0), "Vault already exists for this tier");

        // Deploy new vault
        AIVaultSimple newVault = new AIVaultSimple(
            asset,
            revenuePool,
            profitPool
        );

        // Apply tier strategy
        TierStrategy storage strategy = tierStrategies[riskTier];
        newVault.updateStrategy(
            strategy.maxDrawdown,
            strategy.targetReturn,
            strategy.rebalanceInterval,
            strategy.allowedProtocols
        );

        // Store vault information
        vaultsByTier[riskTier] = address(newVault);
        vaultInfo[address(newVault)] = VaultInfo({
            vaultAddress: address(newVault),
            riskTier: riskTier,
            name: name,
            isActive: true
        });
        allVaults.push(address(newVault));

        // Grant AI_AGENT_ROLE to the admin
        newVault.grantRole(newVault.AI_AGENT_ROLE(), msg.sender);
        newVault.grantRole(newVault.EMERGENCY_ROLE(), msg.sender);

        emit VaultCreated(address(newVault), riskTier, name);
    }

    /**
     * @notice Updates the strategy for a specific risk tier
     */
    function updateTierStrategy(
        RiskTier tier,
        uint256 maxDrawdown,
        uint256 targetReturn,
        uint256 rebalanceInterval,
        address[] calldata allowedProtocols
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tierStrategies[tier].maxDrawdown = maxDrawdown;
        tierStrategies[tier].targetReturn = targetReturn;
        tierStrategies[tier].rebalanceInterval = rebalanceInterval;
        tierStrategies[tier].allowedProtocols = allowedProtocols;

        // Update strategy for existing vault if it exists
        address vaultAddress = vaultsByTier[tier];
        if (vaultAddress != address(0)) {
            AIVaultSimple(vaultAddress).updateStrategy(
                maxDrawdown,
                targetReturn,
                rebalanceInterval,
                allowedProtocols
            );
        }

        emit TierStrategyUpdated(tier, maxDrawdown, targetReturn, rebalanceInterval);
        emit ProtocolsUpdated(tier, allowedProtocols);
    }

    /**
     * @notice Updates the active status of a vault
     */
    function setVaultStatus(
        address vaultAddress,
        bool isActive
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(vaultInfo[vaultAddress].vaultAddress != address(0), "Vault does not exist");
        vaultInfo[vaultAddress].isActive = isActive;
        emit VaultStatusUpdated(vaultAddress, isActive);
    }

    /**
     * @notice Returns all active vaults
     */
    function getActiveVaults() external view returns (VaultInfo[] memory) {
        uint256 activeCount = 0;
        for (uint i = 0; i < allVaults.length; i++) {
            if (vaultInfo[allVaults[i]].isActive) {
                activeCount++;
            }
        }

        VaultInfo[] memory activeVaults = new VaultInfo[](activeCount);
        uint256 currentIndex = 0;
        for (uint i = 0; i < allVaults.length; i++) {
            if (vaultInfo[allVaults[i]].isActive) {
                activeVaults[currentIndex] = vaultInfo[allVaults[i]];
                currentIndex++;
            }
        }

        return activeVaults;
    }

    /**
     * @notice Returns vault metrics for a specific tier
     */
    function getVaultMetrics(RiskTier tier) external view returns (AIVaultSimple.VaultMetrics memory) {
        address vaultAddress = vaultsByTier[tier];
        require(vaultAddress != address(0), "No vault for this tier");
        return AIVaultSimple(vaultAddress).metrics();
    }

    /**
     * @notice Returns vault by risk tier
     */
    function getVaultByTier(RiskTier tier) external view returns (VaultInfo memory) {
        address vaultAddress = vaultsByTier[tier];
        require(vaultAddress != address(0), "No vault for this tier");
        return vaultInfo[vaultAddress];
    }

    /**
     * @notice Initialize default strategies for each risk tier
     */
    function _initializeDefaultStrategies() internal {
        // Conservative strategy (LOW risk)
        address[] memory lowRiskProtocols = new address[](0);
        tierStrategies[RiskTier.LOW] = TierStrategy({
            maxDrawdown: 500,      // 5%
            targetReturn: 800,     // 8%
            rebalanceInterval: 7 days,
            allowedProtocols: lowRiskProtocols
        });

        // Moderate strategy (MEDIUM risk)
        address[] memory mediumRiskProtocols = new address[](0);
        tierStrategies[RiskTier.MEDIUM] = TierStrategy({
            maxDrawdown: 1500,     // 15%
            targetReturn: 1500,    // 15%
            rebalanceInterval: 3 days,
            allowedProtocols: mediumRiskProtocols
        });

        // Aggressive strategy (HIGH risk)
        address[] memory highRiskProtocols = new address[](0);
        tierStrategies[RiskTier.HIGH] = TierStrategy({
            maxDrawdown: 3000,     // 30%
            targetReturn: 2500,    // 25%
            rebalanceInterval: 1 days,
            allowedProtocols: highRiskProtocols
        });
    }
}
