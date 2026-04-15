// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OTCSaleVault} from '../src/OTCSaleVault.sol';
import {ICCA} from '../src/interfaces/ICCA.sol';
import {IOTCSaleVault, Milestone, OTCSaleParams} from '../src/interfaces/IOTCSaleVault.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Test} from 'forge-std/Test.sol';

contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockCCA {
    IERC20 public token;
    IERC20 public currencyToken;
    bool public graduated;
    uint256 public unsoldTokenAmount;
    uint256 public currencyAmount;
    bool public currencySwept;
    bool public tokensSwept;

    constructor(address _token, address _currency) {
        token = IERC20(_token);
        currencyToken = IERC20(_currency);
    }

    function configure(bool _graduated, uint256 _unsoldTokens, uint256 _currencyAmount) external {
        graduated = _graduated;
        unsoldTokenAmount = _unsoldTokens;
        currencyAmount = _currencyAmount;
    }

    function isGraduated() external view returns (bool) {
        return graduated;
    }

    function sweepUnsoldTokens() external {
        require(!tokensSwept, 'already swept');
        tokensSwept = true;
        if (unsoldTokenAmount > 0) {
            token.transfer(msg.sender, unsoldTokenAmount);
        }
    }

    function sweepCurrency() external {
        require(graduated, 'not graduated');
        require(!currencySwept, 'already swept');
        currencySwept = true;
        if (currencyAmount > 0) {
            currencyToken.transfer(msg.sender, currencyAmount);
        }
    }
}

contract OTCSaleVaultTest is Test {
    MockERC20 underlying;
    MockERC20 currency;
    MockCCA mockCCA;
    OTCSaleVault vault;

    address seller = address(0x1);
    address buyer1 = address(0x2);
    address buyer2 = address(0x3);
    address anyone = address(0x4);

    uint128 constant TOTAL_SHARES = 1_000_000e18;
    uint128 constant BOND_AMOUNT = 100_000e6;
    uint256 constant AUCTION_PROCEEDS = 500_000e6;

    Milestone[] milestones;

    function setUp() public {
        underlying = new MockERC20('Underlying Token', 'UND', 18);
        currency = new MockERC20('USD Coin', 'USDC', 6);

        milestones.push(Milestone({deadline: uint64(block.timestamp + 30 days), cumulativeAmount: 200_000e18}));
        milestones.push(Milestone({deadline: uint64(block.timestamp + 60 days), cumulativeAmount: 500_000e18}));
        milestones.push(Milestone({deadline: uint64(block.timestamp + 90 days), cumulativeAmount: 1_000_000e18}));

        vault = _deployVaultWithBond();

        mockCCA = new MockCCA(address(vault), address(currency));

        // Distribute shares: 600k to buyer1, 400k to buyer2
        vm.startPrank(address(this));
        vault.transfer(buyer1, 600_000e18);
        vault.transfer(buyer2, 400_000e18);
        vm.stopPrank();

        // Fund seller with underlying for vesting
        underlying.mint(seller, 2_000_000e18);
        vm.prank(seller);
        underlying.approve(address(vault), type(uint256).max);
    }

    // ========================
    // Constructor Tests
    // ========================

    function test_constructor_mintsShares() public view {
        assertEq(vault.totalSupply(), TOTAL_SHARES);
    }

    function test_constructor_setsImmutables() public view {
        assertEq(vault.seller(), seller);
        assertEq(vault.currency(), address(currency));
        assertEq(vault.bondAmount(), BOND_AMOUNT);
        assertEq(vault.asset(), address(underlying));
    }

    function test_constructor_revertsInsufficientBond() public {
        OTCSaleParams memory params = _defaultParams();
        // Don't pre-fund bond
        vm.expectRevert(IOTCSaleVault.InsufficientBond.selector);
        new OTCSaleVault(params);
    }

    function test_constructor_revertsZeroShares() public {
        OTCSaleParams memory params = _defaultParams();
        params.totalShares = 0;
        vm.expectRevert(IOTCSaleVault.ZeroShares.selector);
        new OTCSaleVault(params);
    }

    function test_constructor_revertsNoMilestones() public {
        OTCSaleParams memory params;
        params.underlyingToken = address(underlying);
        params.seller = seller;
        params.totalShares = TOTAL_SHARES;
        params.currency = address(currency);
        params.bondAmount = BOND_AMOUNT;
        // empty milestones

        vm.expectRevert(IOTCSaleVault.NoMilestones.selector);
        new OTCSaleVault(params);
    }

    function test_constructor_revertsInvalidCurrency() public {
        OTCSaleParams memory params = _defaultParams();
        params.currency = address(underlying);
        vm.expectRevert(IOTCSaleVault.InvalidCurrency.selector);
        new OTCSaleVault(params);
    }

    // ========================
    // Settlement Tests
    // ========================

    function test_settleAuction_graduated() public {
        _setupGraduatedCCA(0, AUCTION_PROCEEDS);

        vault.settleAuction(address(mockCCA));

        assertTrue(vault.settled());
        assertEq(vault.$effectiveTotalShares(), TOTAL_SHARES);
        assertEq(vault.$totalAuctionProceeds(), AUCTION_PROCEEDS);
    }

    function test_settleAuction_withUnsoldShares() public {
        uint256 unsold = 100_000e18;
        // Send some shares back to vault (simulating unsold)
        vm.prank(buyer2);
        vault.transfer(address(vault), unsold);

        _setupGraduatedCCA(0, AUCTION_PROCEEDS);

        vault.settleAuction(address(mockCCA));

        assertTrue(vault.settled());
        assertEq(vault.$effectiveTotalShares(), TOTAL_SHARES - unsold);
        assertEq(vault.$totalAuctionProceeds(), AUCTION_PROCEEDS);
    }

    function test_settleAuction_notGraduated() public {
        // CCA sends all tokens back, no currency
        mockCCA.configure(false, TOTAL_SHARES, 0);
        // Need to give CCA the shares
        vm.prank(buyer1);
        vault.transfer(address(mockCCA), 600_000e18);
        vm.prank(buyer2);
        vault.transfer(address(mockCCA), 400_000e18);

        vault.settleAuction(address(mockCCA));

        assertTrue(vault.settled());
        assertEq(vault.$effectiveTotalShares(), 0);
        assertEq(vault.$totalAuctionProceeds(), 0);
    }

    function test_settleAuction_revertsAlreadySettled() public {
        _setupGraduatedCCA(0, AUCTION_PROCEEDS);
        vault.settleAuction(address(mockCCA));

        vm.expectRevert(IOTCSaleVault.AlreadySettled.selector);
        vault.settleAuction(address(mockCCA));
    }

    // ========================
    // Deposit Vesting Tests
    // ========================

    function test_depositVesting() public {
        _settleDefault();

        vm.prank(seller);
        vault.depositVesting(100_000e18);

        assertEq(vault.$totalVestingDeposited(), 100_000e18);
    }

    function test_depositVesting_revertsNotSeller() public {
        _settleDefault();

        vm.prank(anyone);
        vm.expectRevert(IOTCSaleVault.NotSeller.selector);
        vault.depositVesting(100_000e18);
    }

    function test_depositVesting_revertsNotSettled() public {
        vm.prank(seller);
        vm.expectRevert(IOTCSaleVault.NotSettled.selector);
        vault.depositVesting(100_000e18);
    }

    // ========================
    // Milestone Tests
    // ========================

    function test_unlockMilestone() public {
        _settleDefault();
        _depositAndAdvance(200_000e18, milestones[0].deadline);

        vault.unlockMilestone(0);

        assertEq(vault.$lastUnlockedMilestone(), 0);
    }

    function test_unlockMilestone_revertsBeforeDeadline() public {
        _settleDefault();

        vm.prank(seller);
        vault.depositVesting(200_000e18);

        vm.expectRevert(IOTCSaleVault.MilestoneNotReached.selector);
        vault.unlockMilestone(0);
    }

    function test_unlockMilestone_revertsInsufficientDeposit() public {
        _settleDefault();

        vm.warp(milestones[0].deadline);

        vm.expectRevert(IOTCSaleVault.MilestoneNotReached.selector);
        vault.unlockMilestone(0);
    }

    function test_unlockMilestone_revertsDuplicate() public {
        _settleDefault();
        _depositAndAdvance(200_000e18, milestones[0].deadline);
        vault.unlockMilestone(0);

        vm.expectRevert(IOTCSaleVault.MilestoneAlreadyUnlocked.selector);
        vault.unlockMilestone(0);
    }

    function test_unlockMilestone_revertsNotSettled() public {
        vm.expectRevert(IOTCSaleVault.NotSettled.selector);
        vault.unlockMilestone(0);
    }

    function test_unlockMilestone_multipleInOrder() public {
        _settleDefault();

        _depositAndAdvance(200_000e18, milestones[0].deadline);
        vault.unlockMilestone(0);

        _depositAndAdvance(300_000e18, milestones[1].deadline);
        vault.unlockMilestone(1);

        assertEq(vault.$lastUnlockedMilestone(), 1);
    }

    // ========================
    // Redemption Tests
    // ========================

    function test_redeem_afterMilestone() public {
        _settleDefault();
        _depositAndAdvance(200_000e18, milestones[0].deadline);
        vault.unlockMilestone(0);

        uint256 shares = 100_000e18;
        vm.prank(buyer1);
        uint256 assets = vault.redeem(shares, buyer1, buyer1);

        assertGt(assets, 0);
        assertEq(underlying.balanceOf(buyer1), assets);
    }

    function test_totalAssets_zeroBeforeMilestone() public {
        _settleDefault();

        assertEq(vault.totalAssets(), 0);
    }

    function test_totalAssets_afterMilestone() public {
        _settleDefault();
        _depositAndAdvance(200_000e18, milestones[0].deadline);
        vault.unlockMilestone(0);

        assertEq(vault.totalAssets(), 200_000e18);
    }

    function test_totalAssets_donationDoesNotAffect() public {
        _settleDefault();
        _depositAndAdvance(200_000e18, milestones[0].deadline);
        vault.unlockMilestone(0);

        uint256 assetsBefore = vault.totalAssets();
        underlying.mint(address(vault), 1_000_000e18);
        assertEq(vault.totalAssets(), assetsBefore);
    }

    // ========================
    // Currency Release Tests
    // ========================

    function test_claimReleasedCurrency_afterFirstMilestone() public {
        _settleDefault();
        _depositAndAdvance(200_000e18, milestones[0].deadline);
        vault.unlockMilestone(0);

        uint256 totalPool = uint256(BOND_AMOUNT) + AUCTION_PROCEEDS;
        // milestone[0].cumulativeAmount / milestone[2].cumulativeAmount = 200k / 1M = 20%
        uint256 expectedRelease = (totalPool * 200_000e18) / 1_000_000e18;

        vm.prank(seller);
        vault.claimReleasedCurrency();

        assertEq(currency.balanceOf(seller), expectedRelease);
        assertEq(vault.$currencyReleasedToSeller(), expectedRelease);
    }

    function test_claimReleasedCurrency_afterSecondMilestone() public {
        _settleDefault();
        _depositAndAdvance(200_000e18, milestones[0].deadline);
        vault.unlockMilestone(0);

        vm.prank(seller);
        vault.claimReleasedCurrency();
        uint256 firstRelease = currency.balanceOf(seller);

        _depositAndAdvance(300_000e18, milestones[1].deadline);
        vault.unlockMilestone(1);

        vm.prank(seller);
        vault.claimReleasedCurrency();

        uint256 totalPool = uint256(BOND_AMOUNT) + AUCTION_PROCEEDS;
        // 50% released after milestone 1 (500k / 1M)
        uint256 expectedTotal = (totalPool * 500_000e18) / 1_000_000e18;
        assertEq(currency.balanceOf(seller), expectedTotal);
        assertEq(currency.balanceOf(seller) - firstRelease, expectedTotal - firstRelease);
    }

    function test_claimReleasedCurrency_allMilestones_returnsEntirePool() public {
        _settleDefault();

        _depositAndAdvance(200_000e18, milestones[0].deadline);
        vault.unlockMilestone(0);

        _depositAndAdvance(300_000e18, milestones[1].deadline);
        vault.unlockMilestone(1);

        _depositAndAdvance(500_000e18, milestones[2].deadline);
        vault.unlockMilestone(2);

        vm.prank(seller);
        vault.claimReleasedCurrency();

        uint256 totalPool = uint256(BOND_AMOUNT) + AUCTION_PROCEEDS;
        assertEq(currency.balanceOf(seller), totalPool);
    }

    function test_claimReleasedCurrency_batchedClaim() public {
        _settleDefault();

        // Unlock all three milestones without claiming in between
        _depositAndAdvance(200_000e18, milestones[0].deadline);
        vault.unlockMilestone(0);

        _depositAndAdvance(300_000e18, milestones[1].deadline);
        vault.unlockMilestone(1);

        _depositAndAdvance(500_000e18, milestones[2].deadline);
        vault.unlockMilestone(2);

        // Single batched claim
        vm.prank(seller);
        vault.claimReleasedCurrency();

        uint256 totalPool = uint256(BOND_AMOUNT) + AUCTION_PROCEEDS;
        assertEq(currency.balanceOf(seller), totalPool);
    }

    function test_claimReleasedCurrency_revertsNotSeller() public {
        _settleDefault();
        _depositAndAdvance(200_000e18, milestones[0].deadline);
        vault.unlockMilestone(0);

        vm.prank(anyone);
        vm.expectRevert(IOTCSaleVault.NotSeller.selector);
        vault.claimReleasedCurrency();
    }

    function test_claimReleasedCurrency_revertsNoMilestone() public {
        _settleDefault();

        vm.prank(seller);
        vm.expectRevert(IOTCSaleVault.MilestoneNotReached.selector);
        vault.claimReleasedCurrency();
    }

    function test_claimReleasedCurrency_revertsNothingToClaim() public {
        _settleDefault();
        _depositAndAdvance(200_000e18, milestones[0].deadline);
        vault.unlockMilestone(0);

        vm.prank(seller);
        vault.claimReleasedCurrency();

        // Claim again with same milestone
        vm.prank(seller);
        vm.expectRevert(IOTCSaleVault.NothingToClaim.selector);
        vault.claimReleasedCurrency();
    }

    // ========================
    // Default Tests
    // ========================

    function test_triggerDefault_missedMilestone() public {
        _settleDefault();

        vm.warp(milestones[0].deadline + 1);

        vm.prank(anyone);
        vault.triggerDefault(0);

        assertTrue(vault.$defaulted());
    }

    function test_triggerDefault_revertsBeforeDeadline() public {
        _settleDefault();

        vm.expectRevert(IOTCSaleVault.MilestoneDeadlineNotPassed.selector);
        vault.triggerDefault(0);
    }

    function test_triggerDefault_revertsMilestoneFulfilled() public {
        _settleDefault();
        _depositAndAdvance(200_000e18, milestones[0].deadline + 1);

        vm.expectRevert(IOTCSaleVault.MilestoneFulfilled.selector);
        vault.triggerDefault(0);
    }

    function test_triggerDefault_revertsNotSettled() public {
        vm.warp(milestones[0].deadline + 1);

        vm.expectRevert(IOTCSaleVault.NotSettled.selector);
        vault.triggerDefault(0);
    }

    function test_triggerDefault_revertsAlreadyDefaulted() public {
        _settleDefault();
        vm.warp(milestones[0].deadline + 1);
        vault.triggerDefault(0);

        vm.expectRevert(IOTCSaleVault.SellerDefaulted.selector);
        vault.triggerDefault(1);
    }

    // ========================
    // Default Claim Tests
    // ========================

    function test_claimOnDefault_fullPool() public {
        _settleDefault();
        vm.warp(milestones[0].deadline + 1);
        vault.triggerDefault(0);

        uint256 totalPool = uint256(BOND_AMOUNT) + AUCTION_PROCEEDS;

        // buyer1 has 600k shares out of 1M
        vm.prank(buyer1);
        vault.claimOnDefault(600_000e18, buyer1);

        uint256 expected1 = (totalPool * 600_000e18) / TOTAL_SHARES;
        assertEq(currency.balanceOf(buyer1), expected1);

        // buyer2 has 400k shares
        vm.prank(buyer2);
        vault.claimOnDefault(400_000e18, buyer2);

        uint256 expected2 = (totalPool * 400_000e18) / TOTAL_SHARES;
        assertEq(currency.balanceOf(buyer2), expected2);

        // All currency distributed
        assertEq(currency.balanceOf(buyer1) + currency.balanceOf(buyer2), totalPool);
    }

    function test_claimOnDefault_afterPartialRelease() public {
        _settleDefault();

        // Seller completes first milestone and claims
        _depositAndAdvance(200_000e18, milestones[0].deadline);
        vault.unlockMilestone(0);
        vm.prank(seller);
        vault.claimReleasedCurrency();
        uint256 released = vault.$currencyReleasedToSeller();

        // Then default on milestone 1
        vm.warp(milestones[1].deadline + 1);
        vault.triggerDefault(1);

        uint256 lockedPool = uint256(BOND_AMOUNT) + AUCTION_PROCEEDS - released;

        vm.prank(buyer1);
        vault.claimOnDefault(600_000e18, buyer1);

        uint256 expected = (lockedPool * 600_000e18) / TOTAL_SHARES;
        assertEq(currency.balanceOf(buyer1), expected);
    }

    function test_claimOnDefault_afterPartialRedemption() public {
        _settleDefault();
        _depositAndAdvance(200_000e18, milestones[0].deadline);
        vault.unlockMilestone(0);

        // buyer1 redeems some shares for underlying
        vm.prank(buyer1);
        vault.redeem(100_000e18, buyer1, buyer1);

        // Default on milestone 1
        vm.warp(milestones[1].deadline + 1);
        vault.triggerDefault(1);

        uint256 totalPool = uint256(BOND_AMOUNT) + AUCTION_PROCEEDS;
        uint256 circulatingAtDefault = vault.$defaultCirculatingSupply();
        assertEq(circulatingAtDefault, TOTAL_SHARES - 100_000e18);

        // buyer1 claims remaining 500k shares
        vm.prank(buyer1);
        vault.claimOnDefault(500_000e18, buyer1);

        uint256 expected = (totalPool * 500_000e18) / circulatingAtDefault;
        assertEq(currency.balanceOf(buyer1), expected);
    }

    function test_claimOnDefault_revertsNotDefaulted() public {
        _settleDefault();

        vm.prank(buyer1);
        vm.expectRevert(IOTCSaleVault.SellerNotDefaulted.selector);
        vault.claimOnDefault(100_000e18, buyer1);
    }

    function test_claimOnDefault_revertsZeroShares() public {
        _settleDefault();
        vm.warp(milestones[0].deadline + 1);
        vault.triggerDefault(0);

        vm.prank(buyer1);
        vm.expectRevert(IOTCSaleVault.ZeroShares.selector);
        vault.claimOnDefault(0, buyer1);
    }

    function test_claimOnDefault_revertsInsufficientShares() public {
        _settleDefault();
        vm.warp(milestones[0].deadline + 1);
        vault.triggerDefault(0);

        vm.prank(buyer1);
        vm.expectRevert(IOTCSaleVault.InsufficientShares.selector);
        vault.claimOnDefault(700_000e18, buyer1);
    }

    // ========================
    // Transfer Tests
    // ========================

    function test_transfer_blockedAfterDefault() public {
        _settleDefault();
        vm.warp(milestones[0].deadline + 1);
        vault.triggerDefault(0);

        vm.prank(buyer1);
        vm.expectRevert(IOTCSaleVault.TransferWhileDefaulted.selector);
        vault.transfer(buyer2, 1e18);
    }

    function test_transfer_worksBeforeDefault() public {
        vm.prank(buyer1);
        vault.transfer(buyer2, 1e18);

        assertEq(vault.balanceOf(buyer2), 400_000e18 + 1e18);
    }

    // ========================
    // ERC4626 Disabled Tests
    // ========================

    function test_deposit_disabled() public {
        vm.expectRevert(IOTCSaleVault.DepositDisabled.selector);
        vault.deposit(1e18, buyer1);
    }

    function test_mint_disabled() public {
        vm.expectRevert(IOTCSaleVault.DepositDisabled.selector);
        vault.mint(1e18, buyer1);
    }

    // ========================
    // Donation Resistance Tests
    // ========================

    function test_currencyDonation_doesNotAffectPool() public {
        _settleDefault();

        uint256 poolBefore = uint256(BOND_AMOUNT) + vault.$totalAuctionProceeds();

        // Donate extra currency
        currency.mint(address(vault), 999_999e6);

        // Pool accounting unchanged
        uint256 poolAfter = uint256(BOND_AMOUNT) + vault.$totalAuctionProceeds();
        assertEq(poolBefore, poolAfter);
    }

    // ========================
    // Settlement Scaling Tests
    // ========================

    function test_effectiveMilestoneAmount_scalesAfterSettlement() public {
        // Send 200k shares back to vault (unsold)
        vm.prank(buyer2);
        vault.transfer(address(vault), 200_000e18);

        _setupGraduatedCCA(0, AUCTION_PROCEEDS);
        vault.settleAuction(address(mockCCA));

        // effectiveTotalShares = 1M - 200k = 800k
        // milestone[0] original = 200k, scaled = 200k * 800k / 1M = 160k
        uint256 effective = vault.effectiveMilestoneAmount(0);
        assertEq(effective, (200_000e18 * 800_000e18) / TOTAL_SHARES);
    }

    // ========================
    // Helpers
    // ========================

    function _defaultParams() internal view returns (OTCSaleParams memory params) {
        params.underlyingToken = address(underlying);
        params.seller = seller;
        params.totalShares = TOTAL_SHARES;
        params.currency = address(currency);
        params.bondAmount = BOND_AMOUNT;
        params.milestones = milestones;
    }

    function _deployVaultWithBond() internal returns (OTCSaleVault) {
        OTCSaleParams memory params = _defaultParams();

        // Predict vault address and pre-fund bond
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));

        currency.mint(predicted, BOND_AMOUNT);

        return new OTCSaleVault(params);
    }

    function _setupGraduatedCCA(uint256 unsoldTokens, uint256 auctionProceeds) internal {
        mockCCA.configure(true, unsoldTokens, auctionProceeds);
        // Fund CCA with currency for sweep
        currency.mint(address(mockCCA), auctionProceeds);
    }

    function _settleDefault() internal {
        _setupGraduatedCCA(0, AUCTION_PROCEEDS);
        vault.settleAuction(address(mockCCA));
    }

    function _depositAndAdvance(uint256 amount, uint64 timestamp) internal {
        vm.prank(seller);
        vault.depositVesting(amount);
        vm.warp(timestamp);
    }
}
