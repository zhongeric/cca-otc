// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC4626} from '@openzeppelin/contracts/interfaces/IERC4626.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IOTCSaleVault, Milestone, OTCSaleParams} from './interfaces/IOTCSaleVault.sol';

/// @title OTCSaleVault
/// @custom:security-contact security@uniswap.org
/// @notice ERC4626 vault representing claims on vested tokens, sold via CCA auction.
///         Shares are pre-minted at construction and transferred to the CCA auction contract.
///         The vault starts empty; the seller deposits vesting tokens over time per milestones.
///         A configurable bond protects buyers against seller default.
/// @dev After the CCA auction ends, `settle()` must be called to burn any unsold shares
///      and scale down the seller's milestone obligations proportionally.
///      Accounting uses explicit counters ($totalAssetsWithdrawn) rather than balance checks
///      to prevent donation/griefing attacks on the redemption math.
contract OTCSaleVault is ERC4626, IOTCSaleVault {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Immutables

    /// @notice The seller responsible for depositing vesting tokens
    address public immutable SELLER;
    /// @notice The token used for the seller's bond
    address public immutable BOND_TOKEN;
    /// @notice The required bond amount
    uint128 public immutable BOND_AMOUNT;
    /// @notice Deadline by which bond must be posted
    uint64 public immutable BOND_DEADLINE;
    /// @notice Total shares minted at construction (before settlement)
    uint128 public immutable TOTAL_SHARES;

    // Storage

    /// @notice The vesting milestones
    Milestone[] private $_milestones;

    /// @notice Whether the seller has posted the bond
    bool public $bondPosted;
    /// @notice Whether the seller has defaulted
    bool public $defaulted;
    /// @notice Whether settlement has occurred
    bool public $settled;
    /// @notice Whether the bond has been reclaimed by the seller
    bool private $bondReclaimed;
    /// @notice Total vesting tokens deposited by the seller so far
    uint256 public $totalVestingDeposited;
    /// @notice Index of the latest unlocked milestone (type(uint256).max if none)
    uint256 public $lastUnlockedMilestone;
    /// @notice Total shares burned across all operations (redemptions, bond claims, settlement)
    uint256 public $totalSharesBurned;
    /// @notice Effective total shares after settlement (equals TOTAL_SHARES until settle() is called)
    uint256 public $effectiveTotalShares;
    /// @notice Cumulative underlying tokens withdrawn via redeem/withdraw (explicit counter, not balance-based)
    uint256 public $totalAssetsWithdrawn;
    /// @notice Circulating supply snapshot taken at time of default (used as bond payout denominator)
    uint256 public $defaultCirculatingSupply;

    constructor(OTCSaleParams memory _params)
        ERC4626(IERC20(_params.underlyingToken))
        ERC20(
            string.concat('OTC Vault: ', IERC20Metadata(_params.underlyingToken).name()),
            string.concat('otc', IERC20Metadata(_params.underlyingToken).symbol())
        )
    {
        if (_params.seller == address(0)) revert ZeroAddress();
        if (_params.underlyingToken == address(0)) revert ZeroAddress();
        if (_params.totalShares == 0) revert ZeroShares();
        if (_params.milestones.length == 0) revert NoMilestones();

        SELLER = _params.seller;
        BOND_TOKEN = _params.bondToken == address(0) ? _params.underlyingToken : _params.bondToken;
        BOND_AMOUNT = _params.bondAmount;
        BOND_DEADLINE = _params.bondDeadline;
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

    // Interface-required view functions

    /// @inheritdoc IOTCSaleVault
    function seller() external view override returns (address) {
        return SELLER;
    }

    /// @inheritdoc IOTCSaleVault
    function bondToken() external view override returns (address) {
        return BOND_TOKEN;
    }

    /// @inheritdoc IOTCSaleVault
    function bondAmount() external view override returns (uint128) {
        return BOND_AMOUNT;
    }

    /// @inheritdoc IOTCSaleVault
    function bondDeadline() external view override returns (uint64) {
        return BOND_DEADLINE;
    }

    /// @inheritdoc IOTCSaleVault
    function bondPosted() external view override returns (bool) {
        return $bondPosted;
    }

    /// @inheritdoc IOTCSaleVault
    function defaulted() external view override returns (bool) {
        return $defaulted;
    }

    /// @inheritdoc IOTCSaleVault
    function settled() external view override returns (bool) {
        return $settled;
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
    ///      Uses explicit $totalAssetsWithdrawn counter rather than balance checks.
    function totalAssets() public view override(ERC4626, IERC4626) returns (uint256) {
        if ($lastUnlockedMilestone == type(uint256).max) return 0;

        uint256 unlockedAmount = effectiveMilestoneAmount($lastUnlockedMilestone);
        uint256 deposited = $totalVestingDeposited;
        uint256 effectiveAssets = deposited < unlockedAmount ? deposited : unlockedAmount;

        return effectiveAssets > $totalAssetsWithdrawn ? effectiveAssets - $totalAssetsWithdrawn : 0;
    }

    // Seller functions

    /// @inheritdoc IOTCSaleVault
    function postBond() external override onlySeller notDefaulted {
        if ($bondPosted) revert BondAlreadyPosted();
        if (block.timestamp > BOND_DEADLINE) revert BondDeadlinePassed();

        $bondPosted = true;
        IERC20(BOND_TOKEN).safeTransferFrom(msg.sender, address(this), BOND_AMOUNT);
        emit BondPosted(msg.sender, BOND_TOKEN, BOND_AMOUNT);
    }

    /// @inheritdoc IOTCSaleVault
    function depositVesting(uint256 _amount) external override onlySeller notDefaulted {
        if (!$bondPosted) revert BondNotPosted();

        $totalVestingDeposited += _amount;
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), _amount);
        emit VestingDeposit(msg.sender, _amount, $totalVestingDeposited);
    }

    /// @inheritdoc IOTCSaleVault
    function reclaimBond() external override onlySeller notDefaulted {
        if (!$bondPosted) revert BondNotPosted();
        if ($bondReclaimed) revert BondAlreadyReclaimed();

        uint256 lastIdx = $_milestones.length - 1;
        if ($lastUnlockedMilestone != lastIdx) revert MilestoneNotReached();
        if ($totalVestingDeposited < effectiveMilestoneAmount(lastIdx)) revert MilestoneNotReached();

        $bondReclaimed = true;
        IERC20(BOND_TOKEN).safeTransfer(SELLER, BOND_AMOUNT);
    }

    // Settlement

    /// @inheritdoc IOTCSaleVault
    /// @dev Anyone can call this. Burns any shares held by this contract address (unsold shares
    ///      returned from the CCA via sweepUnsoldTokens). Scales milestone obligations down
    ///      proportionally so the seller only owes tokens for shares that were actually sold.
    function settle() external override {
        if ($settled) revert AlreadySettled();

        uint256 unsoldShares = balanceOf(address(this));
        $settled = true;

        if (unsoldShares > 0) {
            $totalSharesBurned += unsoldShares;
            _burn(address(this), unsoldShares);
        }

        $effectiveTotalShares = TOTAL_SHARES - unsoldShares;
        emit Settled(unsoldShares, $effectiveTotalShares);
    }

    // Milestone management

    /// @inheritdoc IOTCSaleVault
    function unlockMilestone(uint256 _milestoneIndex) external override notDefaulted {
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

        if (!$bondPosted && block.timestamp > BOND_DEADLINE) {
            $defaulted = true;
            $defaultCirculatingSupply = totalSupply();
            emit DefaultTriggered(msg.sender, type(uint256).max);
            return;
        }

        if (!$bondPosted) revert BondNotPosted();

        Milestone memory m = $_milestones[_milestoneIndex];
        uint256 requiredAmount = effectiveMilestoneAmount(_milestoneIndex);
        if (block.timestamp <= m.deadline) revert BondDeadlineNotPassed();
        if ($totalVestingDeposited >= requiredAmount) revert MilestoneNotReached();

        $defaulted = true;
        $defaultCirculatingSupply = totalSupply();
        emit DefaultTriggered(msg.sender, _milestoneIndex);
    }

    /// @inheritdoc IOTCSaleVault
    /// @dev Bond payout is proportional to the share holder's claim on the REMAINING (circulating) supply.
    ///      Uses totalSupply() (shares still in circulation) as the denominator so that shares already
    ///      burned via redemption don't leave bond funds stranded. A holder who already redeemed some
    ///      shares got their underlying tokens for those — they only claim bond for shares they still hold.
    function claimBond(uint256 _shares) external override {
        if (!$defaulted) revert SellerNotDefaulted();
        if (_shares == 0) revert ZeroShares();
        if (balanceOf(msg.sender) < _shares) revert InsufficientShares();
        if (!$bondPosted || BOND_AMOUNT == 0) revert BondNotPosted();

        uint256 payout = uint256(BOND_AMOUNT).mulDiv(_shares, $defaultCirculatingSupply);

        $totalSharesBurned += _shares;
        _burn(msg.sender, _shares);
        IERC20(BOND_TOKEN).safeTransfer(msg.sender, payout);

        emit BondSlashed(msg.sender, _shares, payout);
    }

    /// @inheritdoc IOTCSaleVault
    /// @dev After default, share holders can still withdraw their pro-rata share of underlying
    ///      tokens that were already deposited and unlocked before the default occurred.
    ///      This is separate from claimBond — a holder can do both (withdraw underlying + claim bond).
    function withdrawOnDefault(uint256 _shares, address _receiver) external override {
        if (!$defaulted) revert SellerNotDefaulted();
        if (_shares == 0) revert ZeroShares();
        if (balanceOf(msg.sender) < _shares) revert InsufficientShares();

        uint256 availableUnderlying = _unlockedAssetsRemaining();
        if (availableUnderlying == 0) return;

        uint256 assets = availableUnderlying.mulDiv(_shares, $defaultCirculatingSupply);
        if (assets == 0) return;

        $totalSharesBurned += _shares;
        $totalAssetsWithdrawn += assets;
        _burn(msg.sender, _shares);
        IERC20(asset()).safeTransfer(_receiver, assets);

        emit SharesRedeemed(msg.sender, _shares, assets);
    }

    // ERC4626 overrides

    /// @inheritdoc ERC4626
    /// @dev Disabled. Shares are pre-minted at construction.
    function deposit(uint256, address) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert DepositDisabled();
    }

    /// @inheritdoc ERC4626
    /// @dev Disabled. Shares are pre-minted at construction.
    function mint(uint256, address) public pure override(ERC4626, IERC4626) returns (uint256) {
        revert DepositDisabled();
    }

    /// @inheritdoc ERC4626
    /// @dev Milestone-gated redemption. Burns shares proportionally and transfers underlying tokens.
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
    /// @dev Milestone-gated withdrawal. Converts asset amount to shares and burns them.
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
    ///      Used by withdrawOnDefault so holders can reclaim underlying even after default.
    function _unlockedAssetsRemaining() internal view returns (uint256) {
        if ($lastUnlockedMilestone == type(uint256).max) return 0;

        uint256 unlockedAmount = effectiveMilestoneAmount($lastUnlockedMilestone);
        uint256 deposited = $totalVestingDeposited;
        uint256 effectiveAssets = deposited < unlockedAmount ? deposited : unlockedAmount;

        return effectiveAssets > $totalAssetsWithdrawn ? effectiveAssets - $totalAssetsWithdrawn : 0;
    }

    /// @dev Check that the caller is the seller
    function _checkSeller() internal view {
        if (msg.sender != SELLER) revert NotSeller();
    }

    /// @dev Check that the vault has not defaulted
    function _checkNotDefaulted() internal view {
        if ($defaulted) revert SellerDefaulted();
    }
}
