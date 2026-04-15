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
    address bondToken;
    uint128 bondAmount;
    uint64 bondDeadline;
    Milestone[] milestones;
}

/// @notice Interface for the OTC Sale Vault - an ERC4626 vault used as the auction token in a CCA
interface IOTCSaleVault is IERC4626 {
    // Errors

    /// @notice Error thrown when the caller is not the seller
    error NotSeller();
    /// @notice Error thrown when the bond has already been posted
    error BondAlreadyPosted();
    /// @notice Error thrown when the bond has not been posted
    error BondNotPosted();
    /// @notice Error thrown when the bond deadline has passed
    error BondDeadlinePassed();
    /// @notice Error thrown when the bond deadline has not passed
    error BondDeadlineNotPassed();
    /// @notice Error thrown when the seller has defaulted
    error SellerDefaulted();
    /// @notice Error thrown when the seller has not defaulted
    error SellerNotDefaulted();
    /// @notice Error thrown when the milestone has not been reached
    error MilestoneNotReached();
    /// @notice Error thrown when the milestone has already been unlocked
    error MilestoneAlreadyUnlocked();
    /// @notice Error thrown when no milestones are provided
    error NoMilestones();
    /// @notice Error thrown when milestones are not in chronological order
    error MilestonesNotChronological();
    /// @notice Error thrown when milestone cumulative amounts are not increasing
    error InvalidMilestoneAmounts();
    /// @notice Error thrown when zero shares are provided
    error ZeroShares();
    /// @notice Error thrown when a zero address is provided
    error ZeroAddress();
    /// @notice Error thrown when the caller has insufficient shares
    error InsufficientShares();
    /// @notice Error thrown when the bond has already been claimed
    error BondAlreadyClaimed();
    /// @notice Error thrown when trying to transfer shares while defaulted
    error TransferWhileDefaulted();
    /// @notice Error thrown when settlement has already occurred
    error AlreadySettled();
    /// @notice Error thrown when settlement has not occurred
    error NotSettled();
    /// @notice Error thrown when the vault has not been settled before performing this action
    error SettlementRequired();
    /// @notice Error thrown when the bond has already been reclaimed
    error BondAlreadyReclaimed();
    /// @notice Error thrown when deposit or mint is called (disabled)
    error DepositDisabled();

    // Events

    /// @notice Emitted when the seller posts the bond
    /// @param seller The seller address
    /// @param bondToken The bond token address
    /// @param amount The bond amount
    event BondPosted(address indexed seller, address bondToken, uint256 amount);

    /// @notice Emitted when the seller deposits vesting tokens
    /// @param seller The seller address
    /// @param amount The amount deposited
    /// @param totalDeposited The cumulative amount deposited
    event VestingDeposit(address indexed seller, uint256 amount, uint256 totalDeposited);

    /// @notice Emitted when a vesting milestone is unlocked
    /// @param milestoneIndex The index of the unlocked milestone
    /// @param cumulativeAmount The cumulative token amount at this milestone
    event MilestoneUnlocked(uint256 indexed milestoneIndex, uint256 cumulativeAmount);

    /// @notice Emitted when the seller is declared in default
    /// @param triggeredBy The address that triggered the default
    /// @param milestoneIndex The missed milestone index (type(uint256).max if bond not posted)
    event DefaultTriggered(address indexed triggeredBy, uint256 milestoneIndex);

    /// @notice Emitted when a share holder claims their portion of the bond after default
    /// @param claimer The address claiming the bond
    /// @param shareAmount The number of shares burned
    /// @param bondPayout The bond amount received
    event BondSlashed(address indexed claimer, uint256 shareAmount, uint256 bondPayout);

    /// @notice Emitted when share holder redeems shares for underlying tokens
    /// @param holder The address redeeming
    /// @param shares The number of shares redeemed
    /// @param assets The amount of underlying tokens received
    event SharesRedeemed(address indexed holder, uint256 shares, uint256 assets);

    /// @notice Emitted when unsold shares are settled after the auction ends
    /// @param sharesBurned The number of unsold shares burned
    /// @param adjustedTotalShares The new effective total shares after settlement
    event Settled(uint256 sharesBurned, uint256 adjustedTotalShares);

    // View functions

    /// @notice The seller who must deposit vesting tokens
    function seller() external view returns (address);

    /// @notice The bond token address
    function bondToken() external view returns (address);

    /// @notice The required bond amount
    function bondAmount() external view returns (uint128);

    /// @notice Deadline by which bond must be posted
    function bondDeadline() external view returns (uint64);

    /// @notice Whether the seller has posted the bond
    function bondPosted() external view returns (bool);

    /// @notice Whether the seller has defaulted
    function defaulted() external view returns (bool);

    /// @notice Whether the vault has been settled after the auction
    function settled() external view returns (bool);

    /// @notice Total vesting tokens deposited by the seller so far
    function totalVestingDeposited() external view returns (uint256);

    /// @notice Number of milestones in the vesting schedule
    function milestoneCount() external view returns (uint256);

    /// @notice Get milestone details by index
    /// @param index The milestone index
    /// @return The milestone struct
    function getMilestone(uint256 index) external view returns (Milestone memory);

    /// @notice Index of the latest unlocked milestone (type(uint256).max if none)
    function lastUnlockedMilestone() external view returns (uint256);

    /// @notice The effective total shares after settlement (or TOTAL_SHARES if not settled)
    function effectiveTotalShares() external view returns (uint256);

    /// @notice The scaled cumulative amount for a milestone, adjusted for settlement
    /// @param milestoneIndex The milestone index
    /// @return The adjusted cumulative amount
    function effectiveMilestoneAmount(uint256 milestoneIndex) external view returns (uint256);

    // Seller functions

    /// @notice Seller posts the required bond before the bond deadline
    function postBond() external;

    /// @notice Seller deposits vesting tokens into the vault
    /// @param amount Amount of underlying tokens to deposit
    function depositVesting(uint256 amount) external;

    /// @notice Seller reclaims bond after all milestones are fulfilled
    function reclaimBond() external;

    // Settlement

    /// @notice Settle unsold shares after the CCA auction ends.
    ///         Burns unsold shares held by this address and scales milestone obligations.
    function settle() external;

    // Milestone management

    /// @notice Unlock a milestone once its deadline has passed and cumulative deposits are met
    /// @param milestoneIndex The index of the milestone to unlock
    function unlockMilestone(uint256 milestoneIndex) external;

    // Default mechanism

    /// @notice Trigger seller default if a milestone deadline passed without sufficient deposits
    ///         or if bond wasn't posted by the bond deadline
    /// @param milestoneIndex The milestone that was missed (ignored if bond wasn't posted)
    function triggerDefault(uint256 milestoneIndex) external;

    /// @notice After default, share holders claim their pro-rata portion of the bond
    /// @param shares Amount of shares to burn for bond claim
    function claimBond(uint256 shares) external;

    /// @notice After default, share holders withdraw their pro-rata share of underlying
    ///         tokens that were deposited and unlocked before the default.
    ///         This is separate from claimBond — a holder can do both.
    /// @param shares Amount of shares to burn
    /// @param receiver Address to receive the underlying tokens
    function withdrawOnDefault(uint256 shares, address receiver) external;

    // Note: redeem() and withdraw() are inherited from IERC4626 and overridden
    // in OTCSaleVault with milestone-gated logic.
}
