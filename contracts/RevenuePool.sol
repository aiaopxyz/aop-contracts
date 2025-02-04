// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title RevenuePool
 * @notice Manages protocol revenue from performance fees and penalty fees
 * @dev Implements revenue distribution to various stakeholders
 */
contract RevenuePool is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    // State variables
    IERC20 public immutable asset;
    
    struct Stakeholder {
        address payoutAddress;
        uint256 sharesBasisPoints;  // Share in basis points (100 = 1%)
        bool isActive;
    }

    // Revenue distribution configuration
    uint256 public constant TOTAL_BASIS_POINTS = 10000;
    uint256 public totalAllocatedShares;
    mapping(bytes32 => Stakeholder) public stakeholders;
    bytes32[] public stakeholderIds;

    // Tracking
    uint256 public totalRevenue;
    uint256 public totalDistributed;
    mapping(bytes32 => uint256) public stakeholderClaimed;

    // Events
    event RevenueReceived(uint256 amount, string source);
    event RevenueDistributed(bytes32 indexed stakeholderId, uint256 amount);
    event StakeholderAdded(bytes32 indexed id, address payoutAddress, uint256 sharesBasisPoints);
    event StakeholderUpdated(bytes32 indexed id, address payoutAddress, uint256 sharesBasisPoints);
    event StakeholderStatusChanged(bytes32 indexed id, bool isActive);

    /**
     * @dev Constructor
     * @param _asset The ERC20 token used for revenue
     */
    constructor(IERC20 _asset) {
        require(address(_asset) != address(0), "Invalid asset address");

        asset = _asset;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        
        // Initialize default stakeholders
        _addStakeholder("DEVELOPMENT", address(0), 5000);    // 50% for development
        _addStakeholder("OPERATIONS", address(0), 3000);     // 30% for operations
        _addStakeholder("GOVERNANCE", address(0), 2000);     // 20% for governance rewards
    }

    /**
     * @notice Receives revenue from vaults or other sources
     * @param amount Amount of revenue
     * @param source Source of the revenue (e.g., "PERFORMANCE_FEE", "WITHDRAWAL_FEE")
     */
    function receiveRevenue(uint256 amount, string calldata source) external {
        require(amount > 0, "Cannot receive 0");
        
        asset.safeTransferFrom(msg.sender, address(this), amount);
        totalRevenue += amount;
        
        emit RevenueReceived(amount, source);
    }

    /**
     * @notice Distributes available revenue to a stakeholder
     * @param stakeholderId ID of the stakeholder
     */
    function distribute(bytes32 stakeholderId) external nonReentrant {
        Stakeholder storage stakeholder = stakeholders[stakeholderId];
        require(stakeholder.isActive, "Stakeholder not active");
        require(stakeholder.payoutAddress != address(0), "Payout address not set");

        uint256 totalAvailable = totalRevenue;
        uint256 stakeholderShare = (totalAvailable * stakeholder.sharesBasisPoints) / TOTAL_BASIS_POINTS;
        uint256 alreadyClaimed = stakeholderClaimed[stakeholderId];
        uint256 claimable = stakeholderShare - alreadyClaimed;
        
        require(claimable > 0, "Nothing to claim");

        stakeholderClaimed[stakeholderId] += claimable;
        totalDistributed += claimable;

        asset.safeTransfer(stakeholder.payoutAddress, claimable);
        
        emit RevenueDistributed(stakeholderId, claimable);
    }

    /**
     * @notice Adds a new stakeholder
     * @param id Unique identifier for the stakeholder
     * @param payoutAddress Address to receive distributions
     * @param sharesBasisPoints Share in basis points
     */
    function addStakeholder(
        bytes32 id,
        address payoutAddress,
        uint256 sharesBasisPoints
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _addStakeholder(id, payoutAddress, sharesBasisPoints);
    }

    /**
     * @notice Updates a stakeholder's configuration
     * @param id Stakeholder ID to update
     * @param payoutAddress New payout address
     * @param sharesBasisPoints New share in basis points
     */
    function updateStakeholder(
        bytes32 id,
        address payoutAddress,
        uint256 sharesBasisPoints
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(stakeholders[id].sharesBasisPoints > 0, "Stakeholder does not exist");
        
        totalAllocatedShares = totalAllocatedShares - stakeholders[id].sharesBasisPoints + sharesBasisPoints;
        require(totalAllocatedShares <= TOTAL_BASIS_POINTS, "Total shares exceed 100%");

        stakeholders[id].payoutAddress = payoutAddress;
        stakeholders[id].sharesBasisPoints = sharesBasisPoints;

        emit StakeholderUpdated(id, payoutAddress, sharesBasisPoints);
    }

    /**
     * @notice Sets a stakeholder's active status
     * @param id Stakeholder ID to update
     * @param isActive New active status
     */
    function setStakeholderStatus(
        bytes32 id,
        bool isActive
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(stakeholders[id].sharesBasisPoints > 0, "Stakeholder does not exist");
        stakeholders[id].isActive = isActive;
        emit StakeholderStatusChanged(id, isActive);
    }

    /**
     * @notice Internal function to add a stakeholder
     */
    function _addStakeholder(
        bytes32 id,
        address payoutAddress,
        uint256 sharesBasisPoints
    ) internal {
        require(stakeholders[id].sharesBasisPoints == 0, "Stakeholder already exists");
        require(sharesBasisPoints > 0, "Shares must be greater than 0");
        
        totalAllocatedShares += sharesBasisPoints;
        require(totalAllocatedShares <= TOTAL_BASIS_POINTS, "Total shares exceed 100%");

        stakeholders[id] = Stakeholder({
            payoutAddress: payoutAddress,
            sharesBasisPoints: sharesBasisPoints,
            isActive: true
        });
        stakeholderIds.push(id);

        emit StakeholderAdded(id, payoutAddress, sharesBasisPoints);
    }

    /**
     * @notice Returns all stakeholder IDs
     */
    function getStakeholderIds() external view returns (bytes32[] memory) {
        return stakeholderIds;
    }

    /**
     * @notice Returns claimable amount for a stakeholder
     * @param stakeholderId ID of the stakeholder
     */
    function getClaimableAmount(bytes32 stakeholderId) external view returns (uint256) {
        Stakeholder storage stakeholder = stakeholders[stakeholderId];
        if (!stakeholder.isActive || stakeholder.sharesBasisPoints == 0) {
            return 0;
        }

        uint256 totalShare = (totalRevenue * stakeholder.sharesBasisPoints) / TOTAL_BASIS_POINTS;
        return totalShare - stakeholderClaimed[stakeholderId];
    }

    /**
     * @notice Returns stakeholder details
     * @param stakeholderId ID of the stakeholder
     */
    function getStakeholder(bytes32 stakeholderId) external view returns (
        address payoutAddress,
        uint256 sharesBasisPoints,
        bool isActive,
        uint256 claimed
    ) {
        Stakeholder storage s = stakeholders[stakeholderId];
        return (
            s.payoutAddress,
            s.sharesBasisPoints,
            s.isActive,
            stakeholderClaimed[stakeholderId]
        );
    }
}
