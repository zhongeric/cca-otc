// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';

/// @notice A vesting milestone defining a deadline and cumulative token amount
struct Milestone {
    uint64 deadline;
    uint128 cumulativeAmount;
}

/// @notice Parameters for creating a new OTC sale vault
struct OTCSaleParams {
    address underlyingToken;
    address seller;
    uint128 totalShares;
    address currency;
    uint128 bondAmount;
    Milestone[] milestones;
}

/// @notice Interface for the OTC Sale Vault - an ERC4626 vault used as the auction token in a CCA
interface IOTCSaleVault is IERC4626 {
    // Errors

    error NotSeller();
    error SellerDefaulted();
    error SellerNotDefaulted();
    error NotSettled();
    error AlreadySettled();
    error MilestoneNotReached();
    error MilestoneAlreadyUnlocked();
    error MilestoneDeadlineNotPassed();
    error MilestoneFulfilled();
    error NoMilestones();
    error MilestonesNotChronological();
    error InvalidMilestoneAmounts();
    error ZeroShares();
    error ZeroAddress();
    error InvalidCurrency();
    error InsufficientBond();
    error InsufficientShares();
    error NothingToClaim();
    error TransferWhileDefaulted();
    error DepositDisabled();

    // Events

    event AuctionSettled(uint256 sharesBurned, uint256 effectiveTotalShares, uint256 auctionProceeds);
    event VestingDeposit(address indexed seller, uint256 amount, uint256 totalDeposited);
    event MilestoneUnlocked(uint256 indexed milestoneIndex, uint256 cumulativeAmount);
    event DefaultTriggered(address indexed triggeredBy, uint256 milestoneIndex);
    event CurrencyReleased(address indexed seller, uint256 amount);
    event DefaultClaimed(address indexed claimer, uint256 shares, uint256 currencyPayout);
    event SharesRedeemed(address indexed holder, uint256 shares, uint256 assets);

    // Actions

    /// @notice Settle the auction: sweep unsold tokens and currency from the CCA,
    ///         burn unsold shares, and record auction proceeds.
    /// @param auction Address of the CCA auction contract
    function settleAuction(address auction) external;

    /// @notice Seller deposits vesting tokens into the vault
    /// @param amount Amount of underlying tokens to deposit
    function depositVesting(uint256 amount) external;

    /// @notice Unlock a milestone once its deadline has passed and cumulative deposits are met
    /// @param milestoneIndex The index of the milestone to unlock
    function unlockMilestone(uint256 milestoneIndex) external;

    /// @notice Trigger seller default if a milestone deadline passed without sufficient deposits
    /// @param milestoneIndex The milestone that was missed
    function triggerDefault(uint256 milestoneIndex) external;

    /// @notice Seller claims currency proportional to completed milestones from the unified pool
    function claimReleasedCurrency() external;

    /// @notice After default, share holders claim their pro-rata portion of the locked currency pool
    /// @param shares Amount of shares to burn for currency claim
    /// @param receiver Address to receive the currency
    function claimOnDefault(uint256 shares, address receiver) external;

    // Views

    function seller() external view returns (address);
    function currency() external view returns (address);
    function bondAmount() external view returns (uint128);
    function settled() external view returns (bool);
    function defaulted() external view returns (bool);
    function totalAuctionProceeds() external view returns (uint256);
    function currencyReleasedToSeller() external view returns (uint256);
    function totalVestingDeposited() external view returns (uint256);
    function milestoneCount() external view returns (uint256);
    function getMilestone(uint256 index) external view returns (Milestone memory);
    function lastUnlockedMilestone() external view returns (uint256);
    function effectiveTotalShares() external view returns (uint256);
    function effectiveMilestoneAmount(uint256 milestoneIndex) external view returns (uint256);
}
