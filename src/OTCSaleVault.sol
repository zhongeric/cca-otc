// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ICCA} from './interfaces/ICCA.sol';
import {IOTCSaleVault, Milestone, OTCSaleParams} from './interfaces/IOTCSaleVault.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @title OTCSaleVault
/// @custom:security-contact security@uniswap.org
/// @notice ERC4626 vault representing claims on vested tokens, sold via CCA auction.
///         Shares are pre-minted at construction and transferred to the CCA auction contract.
///         The vault holds a unified currency pool (bond + auction proceeds) that is released
///         to the seller proportionally as milestones are completed.
///         On seller default, the remaining locked currency is claimable by share holders.
/// @dev The bond must be sent to the vault address before deployment (e.g. via CREATE2).
///      After the CCA auction ends, `settleAuction()` must be called to sweep funds,
///      burn unsold shares, and record auction proceeds.
///      Accounting uses explicit counters to prevent donation/griefing attacks.
contract OTCSaleVault is ERC4626, IOTCSaleVault {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Immutables

    /// @notice The seller responsible for depositing vesting tokens
    address public immutable SELLER;
    /// @notice The currency token used for the bond and auction proceeds
    address public immutable CURRENCY;
    /// @notice The required bond amount (part of the unified currency pool)
    uint128 public immutable BOND_AMOUNT;
    /// @notice Total shares minted at construction (before settlement)
    uint128 public immutable TOTAL_SHARES;

    // Storage

    /// @notice The vesting milestones
    Milestone[] private $_milestones;

    /// @notice Whether the seller has defaulted
    bool public $defaulted;
    /// @notice Whether settlement has occurred
    bool public $settled;
    /// @notice Total vesting tokens deposited by the seller so far
    uint256 public $totalVestingDeposited;
    /// @notice Index of the latest unlocked milestone (type(uint256).max if none)
    uint256 public $lastUnlockedMilestone;
    /// @notice Total shares burned across all operations (redemptions, default claims, settlement)
    uint256 public $totalSharesBurned;
    /// @notice Effective total shares after settlement (equals TOTAL_SHARES until settle() is called)
    uint256 public $effectiveTotalShares;
    /// @notice Cumulative underlying tokens withdrawn via redeem/withdraw (explicit counter, not balance-based)
    uint256 public $totalAssetsWithdrawn;
    /// @notice Circulating supply snapshot taken at time of default (used as claim denominator)
    uint256 public $defaultCirculatingSupply;
    /// @notice Total auction proceeds received from the CCA (set once at settlement)
    uint256 public $totalAuctionProceeds;
    /// @notice Cumulative currency released to the seller via claimReleasedCurrency
    uint256 public $currencyReleasedToSeller;

    constructor(OTCSaleParams memory _params)
        ERC4626(IERC20(_params.underlyingToken))
        ERC20(
            string.concat('OTC Vault: ', IERC20Metadata(_params.underlyingToken).name()),
            string.concat('otc', IERC20Metadata(_params.underlyingToken).symbol())
        )
    {
        if (_params.seller == address(0)) revert ZeroAddress();
        if (_params.underlyingToken == address(0)) revert ZeroAddress();
        if (_params.currency == address(0)) revert ZeroAddress();
        if (_params.currency == _params.underlyingToken) revert InvalidCurrency();
        if (_params.totalShares == 0) revert ZeroShares();
        if (_params.milestones.length == 0) revert NoMilestones();

        SELLER = _params.seller;
        CURRENCY = _params.currency;
        BOND_AMOUNT = _params.bondAmount;
        TOTAL_SHARES = _params.totalShares;
        $lastUnlockedMilestone = type(uint256).max;
        $effectiveTotalShares = _params.totalShares;

        uint64 prevDeadline;
        uint128 prevAmount;
        for (uint256 i = 0; i < _params.milestones.length; i++) {
            if (_params.milestones[i].deadline <= prevDeadline && i > 0) revert MilestonesNotChronological();
            if (_params.milestones[i].cumulativeAmount <= prevAmount && i > 0) revert InvalidMilestoneAmounts();
            prevDeadline = _params.milestones[i].deadline;
            prevAmount = _params.milestones[i].cumulativeAmount;
            $_milestones.push(_params.milestones[i]);
        }

        if (IERC20(_params.currency).balanceOf(address(this)) < _params.bondAmount) revert InsufficientBond();

        _mint(msg.sender, _params.totalShares);
    }

    // Modifiers

    modifier onlySeller() {
        _checkSeller();
        _;
    }

    modifier notDefaulted() {
        _checkNotDefaulted();
        _;
    }

    // Interface view functions

    /// @inheritdoc IOTCSaleVault
    function seller() external view override returns (address) {
        return SELLER;
    }

    /// @inheritdoc IOTCSaleVault
    function currency() external view override returns (address) {
        return CURRENCY;
    }

    /// @inheritdoc IOTCSaleVault
    function bondAmount() external view override returns (uint128) {
        return BOND_AMOUNT;
    }

    /// @inheritdoc IOTCSaleVault
    function settled() external view override returns (bool) {
        return $settled;
    }

    /// @inheritdoc IOTCSaleVault
    function defaulted() external view override returns (bool) {
        return $defaulted;
    }

    /// @inheritdoc IOTCSaleVault
    function totalAuctionProceeds() external view override returns (uint256) {
        return $totalAuctionProceeds;
    }

    /// @inheritdoc IOTCSaleVault
    function currencyReleasedToSeller() external view override returns (uint256) {
        return $currencyReleasedToSeller;
    }

    /// @inheritdoc IOTCSaleVault
    function totalVestingDeposited() external view override returns (uint256) {
        return $totalVestingDeposited;
    }

    /// @inheritdoc IOTCSaleVault
    function milestoneCount() external view override returns (uint256) {
        return $_milestones.length;
    }

    /// @inheritdoc IOTCSaleVault
    function getMilestone(uint256 _index) external view override returns (Milestone memory) {
        return $_milestones[_index];
    }

    /// @inheritdoc IOTCSaleVault
    function lastUnlockedMilestone() external view override returns (uint256) {
        return $lastUnlockedMilestone;
    }

    /// @inheritdoc IOTCSaleVault
    function effectiveTotalShares() external view override returns (uint256) {
        return $effectiveTotalShares;
    }

    /// @inheritdoc IOTCSaleVault
    function effectiveMilestoneAmount(uint256 _milestoneIndex) public view override returns (uint256) {
        uint256 originalAmount = $_milestones[_milestoneIndex].cumulativeAmount;
        if (!$settled) return originalAmount;
        return originalAmount.mulDiv($effectiveTotalShares, TOTAL_SHARES);
    }

    /// @inheritdoc ERC4626
    /// @dev Returns the underlying tokens currently available for redemption.
    ///      Computed as min(deposited, unlocked milestone amount) minus tokens already withdrawn.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        if ($lastUnlockedMilestone == type(uint256).max) return 0;

        uint256 unlockedAmount = effectiveMilestoneAmount($lastUnlockedMilestone);
        uint256 deposited = $totalVestingDeposited;
        uint256 effectiveAssets = deposited < unlockedAmount ? deposited : unlockedAmount;

        return effectiveAssets > $totalAssetsWithdrawn ? effectiveAssets - $totalAssetsWithdrawn : 0;
    }

    // Settlement

    /// @inheritdoc IOTCSaleVault
    function settleAuction(address auction) external override {
        if ($settled) revert AlreadySettled();
        ICCA cca = ICCA(auction);

        cca.sweepUnsoldTokens();

        if (cca.isGraduated()) {
            uint256 balBefore = IERC20(CURRENCY).balanceOf(address(this));
            cca.sweepCurrency();
            $totalAuctionProceeds = IERC20(CURRENCY).balanceOf(address(this)) - balBefore;
        }

        uint256 unsoldShares = balanceOf(address(this));
        if (unsoldShares > 0) {
            $totalSharesBurned += unsoldShares;
            _burn(address(this), unsoldShares);
        }

        $effectiveTotalShares = TOTAL_SHARES - unsoldShares;
        $settled = true;
        emit AuctionSettled(unsoldShares, $effectiveTotalShares, $totalAuctionProceeds);
    }

    // Seller functions

    /// @inheritdoc IOTCSaleVault
    function depositVesting(uint256 _amount) external override onlySeller notDefaulted {
        if (!$settled) revert NotSettled();

        $totalVestingDeposited += _amount;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), _amount);
        emit VestingDeposit(msg.sender, _amount, $totalVestingDeposited);
    }

    /// @inheritdoc IOTCSaleVault
    function claimReleasedCurrency() external override onlySeller notDefaulted {
        if ($lastUnlockedMilestone == type(uint256).max) revert MilestoneNotReached();

        uint256 totalPool = uint256(BOND_AMOUNT) + $totalAuctionProceeds;
        uint256 lastCumulative = $_milestones[$_milestones.length - 1].cumulativeAmount;
        uint256 currentCumulative = $_milestones[$lastUnlockedMilestone].cumulativeAmount;

        uint256 totalReleasable = totalPool.mulDiv(currentCumulative, lastCumulative);
        uint256 toRelease = totalReleasable - $currencyReleasedToSeller;
        if (toRelease == 0) revert NothingToClaim();

        $currencyReleasedToSeller += toRelease;
        IERC20(CURRENCY).safeTransfer(SELLER, toRelease);
        emit CurrencyReleased(SELLER, toRelease);
    }

    // Milestone management

    /// @inheritdoc IOTCSaleVault
    function unlockMilestone(uint256 _milestoneIndex) external override notDefaulted {
        if (!$settled) revert NotSettled();

        Milestone memory m = $_milestones[_milestoneIndex];
        uint256 requiredAmount = effectiveMilestoneAmount(_milestoneIndex);

        if (block.timestamp < m.deadline) revert MilestoneNotReached();
        if ($totalVestingDeposited < requiredAmount) revert MilestoneNotReached();

        if ($lastUnlockedMilestone == type(uint256).max) {
            $lastUnlockedMilestone = _milestoneIndex;
        } else {
            if (_milestoneIndex <= $lastUnlockedMilestone) revert MilestoneAlreadyUnlocked();
            $lastUnlockedMilestone = _milestoneIndex;
        }

        emit MilestoneUnlocked(_milestoneIndex, requiredAmount);
    }

    // Default mechanism

    /// @inheritdoc IOTCSaleVault
    function triggerDefault(uint256 _milestoneIndex) external override {
        if ($defaulted) revert SellerDefaulted();
        if (!$settled) revert NotSettled();

        Milestone memory m = $_milestones[_milestoneIndex];
        if (block.timestamp <= m.deadline) revert MilestoneDeadlineNotPassed();
        if ($totalVestingDeposited >= effectiveMilestoneAmount(_milestoneIndex)) revert MilestoneFulfilled();

        $defaulted = true;
        $defaultCirculatingSupply = totalSupply();
        emit DefaultTriggered(msg.sender, _milestoneIndex);
    }

    /// @inheritdoc IOTCSaleVault
    function claimOnDefault(uint256 _shares, address _receiver) external override {
        if (!$defaulted) revert SellerNotDefaulted();
        if (_shares == 0) revert ZeroShares();
        if (balanceOf(msg.sender) < _shares) revert InsufficientShares();

        uint256 lockedCurrency = uint256(BOND_AMOUNT) + $totalAuctionProceeds - $currencyReleasedToSeller;
        uint256 payout = lockedCurrency.mulDiv(_shares, $defaultCirculatingSupply);

        $totalSharesBurned += _shares;
        _burn(msg.sender, _shares);

        if (payout > 0) IERC20(CURRENCY).safeTransfer(_receiver, payout);
        emit DefaultClaimed(msg.sender, _shares, payout);
    }

    // ERC4626 overrides

    /// @inheritdoc ERC4626
    function deposit(uint256, address) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert DepositDisabled();
    }

    /// @inheritdoc ERC4626
    function mint(uint256, address) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert DepositDisabled();
    }

    /// @inheritdoc ERC4626
    function redeem(uint256 _shares, address _receiver, address _owner)
        public
        override(ERC4626, IERC4626)
        notDefaulted
        returns (uint256 assets)
    {
        if (_shares == 0) revert ZeroShares();

        uint256 maxRedeemable = maxRedeem(_owner);
        if (_shares > maxRedeemable) {
            _shares = maxRedeemable;
        }

        assets = convertToAssets(_shares);
        if (assets == 0) return 0;

        if (msg.sender != _owner) {
            _spendAllowance(_owner, msg.sender, _shares);
        }

        $totalSharesBurned += _shares;
        $totalAssetsWithdrawn += assets;
        _burn(_owner, _shares);
        IERC20(asset()).safeTransfer(_receiver, assets);

        emit SharesRedeemed(_owner, _shares, assets);
    }

    /// @inheritdoc ERC4626
    function withdraw(uint256 _assets, address _receiver, address _owner)
        public
        override(ERC4626, IERC4626)
        notDefaulted
        returns (uint256 shares)
    {
        shares = convertToShares(_assets);
        if (shares == 0) revert ZeroShares();

        if (msg.sender != _owner) {
            _spendAllowance(_owner, msg.sender, shares);
        }

        $totalSharesBurned += shares;
        $totalAssetsWithdrawn += _assets;
        _burn(_owner, shares);
        IERC20(asset()).safeTransfer(_receiver, _assets);

        emit SharesRedeemed(_owner, shares, _assets);
    }

    // Internal functions

    /// @dev Override to prevent transfers while defaulted. Burns (to == address(0)) are still allowed.
    function _update(address _from, address _to, uint256 _value) internal override {
        if ($defaulted && _from != address(0) && _to != address(0)) {
            revert TransferWhileDefaulted();
        }
        super._update(_from, _to, _value);
    }

    /// @dev Returns the underlying tokens from fulfilled milestones that haven't been withdrawn yet.
    function _unlockedAssetsRemaining() internal view returns (uint256) {
        if ($lastUnlockedMilestone == type(uint256).max) return 0;

        uint256 unlockedAmount = effectiveMilestoneAmount($lastUnlockedMilestone);
        uint256 deposited = $totalVestingDeposited;
        uint256 effectiveAssets = deposited < unlockedAmount ? deposited : unlockedAmount;

        return effectiveAssets > $totalAssetsWithdrawn ? effectiveAssets - $totalAssetsWithdrawn : 0;
    }

    function _checkSeller() internal view {
        if (msg.sender != SELLER) revert NotSeller();
    }

    function _checkNotDefaulted() internal view {
        if ($defaulted) revert SellerDefaulted();
    }
}
