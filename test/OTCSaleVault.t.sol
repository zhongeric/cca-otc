// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from 'forge-std/Test.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {OTCSaleVault} from '../src/OTCSaleVault.sol';
import {IOTCSaleVault, Milestone, OTCSaleParams} from '../src/interfaces/IOTCSaleVault.sol';

contract MockERC20 is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _decimals = dec_;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract OTCSaleVaultTest is Test {
    MockERC20 underlying;
    MockERC20 bondTokenERC20;
    OTCSaleVault vault;

    address seller = makeAddr('seller');
    address buyer1 = makeAddr('buyer1');
    address buyer2 = makeAddr('buyer2');
    address anyone = makeAddr('anyone');

    uint128 constant TOTAL_SHARES = 1_000_000e18;
    uint128 constant BOND_AMOUNT = 100_000e6;
    uint64 constant BOND_DEADLINE = 1_000_000;
    uint128 constant MILESTONE_1_AMOUNT = 250_000e18;
    uint64 constant MILESTONE_1_DEADLINE = 2_000_000;
    uint128 constant MILESTONE_2_AMOUNT = 500_000e18;
    uint64 constant MILESTONE_2_DEADLINE = 3_000_000;
    uint128 constant MILESTONE_3_AMOUNT = 1_000_000e18;
    uint64 constant MILESTONE_3_DEADLINE = 4_000_000;

    function setUp() public {
        underlying = new MockERC20('Vesting Token', 'VEST', 18);
        bondTokenERC20 = new MockERC20('Bond Token', 'BOND', 6);

        Milestone[] memory milestones = new Milestone[](3);
        milestones[0] = Milestone({deadline: MILESTONE_1_DEADLINE, cumulativeAmount: MILESTONE_1_AMOUNT});
        milestones[1] = Milestone({deadline: MILESTONE_2_DEADLINE, cumulativeAmount: MILESTONE_2_AMOUNT});
        milestones[2] = Milestone({deadline: MILESTONE_3_DEADLINE, cumulativeAmount: MILESTONE_3_AMOUNT});

        OTCSaleParams memory params = OTCSaleParams({
            underlyingToken: address(underlying),
            seller: seller,
            totalShares: TOTAL_SHARES,
            bondToken: address(bondTokenERC20),
            bondAmount: BOND_AMOUNT,
            bondDeadline: BOND_DEADLINE,
            milestones: milestones
        });

        vault = new OTCSaleVault(params);

        vault.transfer(buyer1, 600_000e18);
        vault.transfer(buyer2, 400_000e18);

        underlying.mint(seller, 2_000_000e18);
        bondTokenERC20.mint(seller, 200_000e6);

        vm.prank(seller);
        underlying.approve(address(vault), type(uint256).max);
        vm.prank(seller);
        bondTokenERC20.approve(address(vault), type(uint256).max);
    }

    // Construction

    function test_constructor_mintsSharesAndSetsState() public view {
        assertEq(vault.totalSupply(), TOTAL_SHARES);
        assertEq(vault.SELLER(), seller);
        assertEq(vault.BOND_TOKEN(), address(bondTokenERC20));
        assertEq(vault.BOND_AMOUNT(), BOND_AMOUNT);
        assertEq(vault.BOND_DEADLINE(), BOND_DEADLINE);
        assertEq(vault.milestoneCount(), 3);
        assertEq(vault.$lastUnlockedMilestone(), type(uint256).max);
        assertEq(vault.$bondPosted(), false);
        assertEq(vault.$defaulted(), false);
    }

    function test_constructor_milestonesStored() public view {
        Milestone memory m0 = vault.getMilestone(0);
        assertEq(m0.deadline, MILESTONE_1_DEADLINE);
        assertEq(m0.cumulativeAmount, MILESTONE_1_AMOUNT);

        Milestone memory m2 = vault.getMilestone(2);
        assertEq(m2.deadline, MILESTONE_3_DEADLINE);
        assertEq(m2.cumulativeAmount, MILESTONE_3_AMOUNT);
    }

    function test_constructor_revertsZeroShares() public {
        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({deadline: 100, cumulativeAmount: 100});

        OTCSaleParams memory params = OTCSaleParams({
            underlyingToken: address(underlying),
            seller: seller,
            totalShares: 0,
            bondToken: address(bondTokenERC20),
            bondAmount: BOND_AMOUNT,
            bondDeadline: BOND_DEADLINE,
            milestones: milestones
        });

        vm.expectRevert(IOTCSaleVault.ZeroShares.selector);
        new OTCSaleVault(params);
    }

    function test_constructor_revertsNoMilestones() public {
        Milestone[] memory milestones = new Milestone[](0);

        OTCSaleParams memory params = OTCSaleParams({
            underlyingToken: address(underlying),
            seller: seller,
            totalShares: TOTAL_SHARES,
            bondToken: address(bondTokenERC20),
            bondAmount: BOND_AMOUNT,
            bondDeadline: BOND_DEADLINE,
            milestones: milestones
        });

        vm.expectRevert(IOTCSaleVault.NoMilestones.selector);
        new OTCSaleVault(params);
    }

    // Bond posting

    function test_postBond_succeeds() public {
        vm.warp(BOND_DEADLINE - 1);
        vm.prank(seller);
        vault.postBond();

        assertTrue(vault.$bondPosted());
        assertEq(bondTokenERC20.balanceOf(address(vault)), BOND_AMOUNT);
    }

    function test_postBond_revertsIfNotSeller() public {
        vm.warp(BOND_DEADLINE - 1);
        vm.prank(anyone);
        vm.expectRevert(IOTCSaleVault.NotSeller.selector);
        vault.postBond();
    }

    function test_postBond_revertsAfterDeadline() public {
        vm.warp(BOND_DEADLINE + 1);
        vm.prank(seller);
        vm.expectRevert(IOTCSaleVault.BondDeadlinePassed.selector);
        vault.postBond();
    }

    function test_postBond_revertsIfAlreadyPosted() public {
        vm.warp(BOND_DEADLINE - 1);
        vm.prank(seller);
        vault.postBond();

        vm.prank(seller);
        vm.expectRevert(IOTCSaleVault.BondAlreadyPosted.selector);
        vault.postBond();
    }

    // Vesting deposits

    function test_depositVesting_succeeds() public {
        _postBond();

        vm.prank(seller);
        vault.depositVesting(100_000e18);

        assertEq(vault.$totalVestingDeposited(), 100_000e18);
        assertEq(underlying.balanceOf(address(vault)), 100_000e18);
    }

    function test_depositVesting_revertsWithoutBond() public {
        vm.prank(seller);
        vm.expectRevert(IOTCSaleVault.BondNotPosted.selector);
        vault.depositVesting(100_000e18);
    }

    function test_depositVesting_revertsIfNotSeller() public {
        _postBond();

        vm.prank(anyone);
        vm.expectRevert(IOTCSaleVault.NotSeller.selector);
        vault.depositVesting(100_000e18);
    }

    // Milestone unlocking

    function test_unlockMilestone_succeeds() public {
        _postBond();
        _depositAndAdvance(MILESTONE_1_AMOUNT, MILESTONE_1_DEADLINE);

        vault.unlockMilestone(0);
        assertEq(vault.$lastUnlockedMilestone(), 0);
    }

    function test_unlockMilestone_revertsBeforeDeadline() public {
        _postBond();

        vm.prank(seller);
        vault.depositVesting(MILESTONE_1_AMOUNT);

        vm.warp(MILESTONE_1_DEADLINE - 1);
        vm.expectRevert(IOTCSaleVault.MilestoneNotReached.selector);
        vault.unlockMilestone(0);
    }

    function test_unlockMilestone_revertsWithInsufficientDeposit() public {
        _postBond();

        vm.prank(seller);
        vault.depositVesting(MILESTONE_1_AMOUNT - 1);

        vm.warp(MILESTONE_1_DEADLINE);
        vm.expectRevert(IOTCSaleVault.MilestoneNotReached.selector);
        vault.unlockMilestone(0);
    }

    function test_unlockMilestone_revertsIfAlreadyUnlocked() public {
        _postBond();
        _depositAndAdvance(MILESTONE_1_AMOUNT, MILESTONE_1_DEADLINE);
        vault.unlockMilestone(0);

        vm.expectRevert(IOTCSaleVault.MilestoneAlreadyUnlocked.selector);
        vault.unlockMilestone(0);
    }

    function test_unlockMultipleMilestones() public {
        _postBond();
        _depositAndAdvance(MILESTONE_2_AMOUNT, MILESTONE_2_DEADLINE);

        vault.unlockMilestone(0);
        vault.unlockMilestone(1);
        assertEq(vault.$lastUnlockedMilestone(), 1);
    }

    // Redemption with explicit accounting

    function test_redeem_afterMilestone1() public {
        _postBond();
        _depositAndAdvance(MILESTONE_1_AMOUNT, MILESTONE_1_DEADLINE);
        vault.unlockMilestone(0);

        uint256 shares = 100_000e18;
        uint256 expectedAssets = vault.convertToAssets(shares);

        vm.prank(buyer1);
        uint256 assets = vault.redeem(shares, buyer1, buyer1);

        assertGt(assets, 0);
        assertEq(assets, expectedAssets);
        assertEq(underlying.balanceOf(buyer1), assets);
        assertEq(vault.$totalAssetsWithdrawn(), assets);
    }

    function test_redeem_noAssetsBeforeMilestone() public view {
        assertEq(vault.totalAssets(), 0);
    }

    function test_redeem_proportionalBetweenBuyers() public {
        _postBond();
        _depositAndAdvance(MILESTONE_1_AMOUNT, MILESTONE_1_DEADLINE);
        vault.unlockMilestone(0);

        uint256 buyer1Shares = 100_000e18;
        uint256 buyer2Shares = 100_000e18;

        vm.prank(buyer1);
        uint256 assets1 = vault.redeem(buyer1Shares, buyer1, buyer1);

        vm.prank(buyer2);
        uint256 assets2 = vault.redeem(buyer2Shares, buyer2, buyer2);

        assertEq(assets1, assets2);
    }

    function test_redeem_totalAssetsDecreasesCorrectly() public {
        _postBond();
        _depositAndAdvance(MILESTONE_1_AMOUNT, MILESTONE_1_DEADLINE);
        vault.unlockMilestone(0);

        uint256 totalBefore = vault.totalAssets();

        vm.prank(buyer1);
        uint256 assets = vault.redeem(100_000e18, buyer1, buyer1);

        uint256 totalAfter = vault.totalAssets();
        assertEq(totalBefore - totalAfter, assets);
    }

    function test_redeem_immuneToDonationAttack() public {
        _postBond();
        _depositAndAdvance(MILESTONE_1_AMOUNT, MILESTONE_1_DEADLINE);
        vault.unlockMilestone(0);

        uint256 totalAssetsBefore = vault.totalAssets();

        // Attacker donates tokens directly to vault
        underlying.mint(anyone, 1_000_000e18);
        vm.prank(anyone);
        underlying.transfer(address(vault), 1_000_000e18);

        // totalAssets should NOT change (uses explicit counter, not balance)
        assertEq(vault.totalAssets(), totalAssetsBefore);
    }

    // Default mechanism

    function test_triggerDefault_bondNotPosted() public {
        vm.warp(BOND_DEADLINE + 1);

        vm.prank(anyone);
        vault.triggerDefault(0);

        assertTrue(vault.$defaulted());
    }

    function test_triggerDefault_missedMilestone() public {
        _postBond();

        vm.warp(MILESTONE_1_DEADLINE + 1);

        vm.prank(anyone);
        vault.triggerDefault(0);

        assertTrue(vault.$defaulted());
    }

    function test_triggerDefault_revertsIfMilestoneNotPassed() public {
        _postBond();

        vm.warp(MILESTONE_1_DEADLINE - 1);
        vm.prank(anyone);
        vm.expectRevert(IOTCSaleVault.BondDeadlineNotPassed.selector);
        vault.triggerDefault(0);
    }

    function test_triggerDefault_revertsIfMilestoneFulfilled() public {
        _postBond();

        vm.prank(seller);
        vault.depositVesting(MILESTONE_1_AMOUNT);

        vm.warp(MILESTONE_1_DEADLINE + 1);
        vm.prank(anyone);
        vm.expectRevert(IOTCSaleVault.MilestoneNotReached.selector);
        vault.triggerDefault(0);
    }

    // Bond claiming — uses circulating supply as denominator

    function test_claimBond_afterDefault() public {
        _postBond();
        vm.warp(MILESTONE_1_DEADLINE + 1);

        vm.prank(anyone);
        vault.triggerDefault(0);

        uint256 buyer1Shares = vault.balanceOf(buyer1);

        vm.prank(buyer1);
        vault.claimBond(buyer1Shares);

        // buyer1 has 600k of 1M circulating → 60% of bond
        uint256 expectedPayout = uint256(BOND_AMOUNT) * 600_000e18 / TOTAL_SHARES;
        assertEq(bondTokenERC20.balanceOf(buyer1), expectedPayout);
    }

    function test_claimBond_revertsIfNotDefaulted() public {
        _postBond();

        vm.prank(buyer1);
        vm.expectRevert(IOTCSaleVault.SellerNotDefaulted.selector);
        vault.claimBond(100e18);
    }

    function test_claimBond_multipleClaimers() public {
        _postBond();
        vm.warp(MILESTONE_1_DEADLINE + 1);

        vm.prank(anyone);
        vault.triggerDefault(0);

        uint256 buyer1Shares = vault.balanceOf(buyer1);
        uint256 buyer2Shares = vault.balanceOf(buyer2);

        vm.prank(buyer1);
        vault.claimBond(buyer1Shares);

        vm.prank(buyer2);
        vault.claimBond(buyer2Shares);

        uint256 totalPaid = bondTokenERC20.balanceOf(buyer1) + bondTokenERC20.balanceOf(buyer2);
        assertApproxEqAbs(totalPaid, BOND_AMOUNT, 2);
    }

    function test_claimBond_afterPartialRedemption_noStrandedBond() public {
        _postBond();
        _depositAndAdvance(MILESTONE_1_AMOUNT, MILESTONE_1_DEADLINE);
        vault.unlockMilestone(0);

        // Buyer1 redeems 200k of their 600k shares for underlying tokens
        vm.prank(buyer1);
        vault.redeem(200_000e18, buyer1, buyer1);

        // Seller fails milestone 2 → default
        vm.warp(MILESTONE_2_DEADLINE + 1);
        vm.prank(anyone);
        vault.triggerDefault(1);

        // Now buyer1 has 400k shares, buyer2 has 400k, totalSupply = 800k
        uint256 b1Shares = vault.balanceOf(buyer1);
        uint256 b2Shares = vault.balanceOf(buyer2);
        assertEq(b1Shares, 400_000e18);
        assertEq(b2Shares, 400_000e18);

        vm.prank(buyer1);
        vault.claimBond(b1Shares);

        vm.prank(buyer2);
        vault.claimBond(b2Shares);

        // FULL bond should be distributed (no stranded funds)
        uint256 totalPaid = bondTokenERC20.balanceOf(buyer1) + bondTokenERC20.balanceOf(buyer2);
        assertApproxEqAbs(totalPaid, BOND_AMOUNT, 2);
    }

    // Withdraw on default — recover underlying from fulfilled milestones

    function test_withdrawOnDefault_recoversUnderlyingTokens() public {
        _postBond();
        _depositAndAdvance(MILESTONE_1_AMOUNT, MILESTONE_1_DEADLINE);
        vault.unlockMilestone(0);

        // Seller defaults on milestone 2
        vm.warp(MILESTONE_2_DEADLINE + 1);
        vm.prank(anyone);
        vault.triggerDefault(1);

        // Buyer2 should be able to withdraw their share of the milestone 1 deposit
        uint256 b2Shares = vault.balanceOf(buyer2);

        vm.prank(buyer2);
        vault.withdrawOnDefault(b2Shares, buyer2);

        // 400k/1M shares * 250k underlying = 100k
        assertApproxEqAbs(underlying.balanceOf(buyer2), 100_000e18, 1e18);
    }

    function test_withdrawOnDefault_afterPartialRedemption() public {
        _postBond();
        _depositAndAdvance(MILESTONE_1_AMOUNT, MILESTONE_1_DEADLINE);
        vault.unlockMilestone(0);

        // Buyer1 redeems 200k shares for underlying BEFORE default
        vm.prank(buyer1);
        uint256 alreadyGot = vault.redeem(200_000e18, buyer1, buyer1);
        assertGt(alreadyGot, 0);

        // Seller defaults on milestone 2
        vm.warp(MILESTONE_2_DEADLINE + 1);
        vm.prank(anyone);
        vault.triggerDefault(1);

        // Buyer1 still has 400k shares, buyer2 has 400k, total = 800k
        // Remaining underlying = 250k - alreadyGot
        uint256 remaining = MILESTONE_1_AMOUNT - alreadyGot;

        // Buyer2 withdraws
        uint256 b2Shares = vault.balanceOf(buyer2);
        vm.prank(buyer2);
        vault.withdrawOnDefault(b2Shares, buyer2);

        // Buyer2 gets 400k/800k * remaining
        uint256 expected = remaining * 400_000e18 / 800_000e18;
        assertApproxEqAbs(underlying.balanceOf(buyer2), expected, 1e18);
    }

    function test_withdrawOnDefault_andClaimBond_bothWork() public {
        _postBond();
        _depositAndAdvance(MILESTONE_1_AMOUNT, MILESTONE_1_DEADLINE);
        vault.unlockMilestone(0);

        vm.warp(MILESTONE_2_DEADLINE + 1);
        vm.prank(anyone);
        vault.triggerDefault(1);

        uint256 b1Shares = vault.balanceOf(buyer1);
        uint256 halfShares = b1Shares / 2;

        // Buyer1 uses half shares to withdraw underlying
        vm.prank(buyer1);
        vault.withdrawOnDefault(halfShares, buyer1);

        // Buyer1 uses other half to claim bond
        vm.prank(buyer1);
        vault.claimBond(halfShares);

        assertGt(underlying.balanceOf(buyer1), 0);
        assertGt(bondTokenERC20.balanceOf(buyer1), 0);
    }

    function test_withdrawOnDefault_revertsIfNotDefaulted() public {
        vm.prank(buyer1);
        vm.expectRevert(IOTCSaleVault.SellerNotDefaulted.selector);
        vault.withdrawOnDefault(100e18, buyer1);
    }

    // Transfer restrictions

    function test_transfer_blockedAfterDefault() public {
        _postBond();
        vm.warp(MILESTONE_1_DEADLINE + 1);
        vm.prank(anyone);
        vault.triggerDefault(0);

        vm.prank(buyer1);
        vm.expectRevert(IOTCSaleVault.TransferWhileDefaulted.selector);
        vault.transfer(buyer2, 100e18);
    }

    function test_transfer_worksBeforeDefault() public {
        vm.prank(buyer1);
        vault.transfer(buyer2, 100e18);

        assertEq(vault.balanceOf(buyer2), 400_000e18 + 100e18);
    }

    // ERC4626 disabled functions

    function test_deposit_disabled() public {
        vm.expectRevert(IOTCSaleVault.DepositDisabled.selector);
        vault.deposit(100, buyer1);
    }

    function test_mint_disabled() public {
        vm.expectRevert(IOTCSaleVault.DepositDisabled.selector);
        vault.mint(100, buyer1);
    }

    // Bond reclaim

    function test_reclaimBond_afterAllMilestones() public {
        _postBond();
        _depositAndAdvance(MILESTONE_3_AMOUNT, MILESTONE_3_DEADLINE);

        vault.unlockMilestone(0);
        vault.unlockMilestone(1);
        vault.unlockMilestone(2);

        uint256 sellerBondBefore = bondTokenERC20.balanceOf(seller);

        vm.prank(seller);
        vault.reclaimBond();

        assertEq(bondTokenERC20.balanceOf(seller) - sellerBondBefore, BOND_AMOUNT);
    }

    function test_reclaimBond_revertsBeforeAllMilestones() public {
        _postBond();
        _depositAndAdvance(MILESTONE_1_AMOUNT, MILESTONE_1_DEADLINE);
        vault.unlockMilestone(0);

        vm.prank(seller);
        vm.expectRevert(IOTCSaleVault.MilestoneNotReached.selector);
        vault.reclaimBond();
    }

    // Settlement

    function test_settle_burnsUnsoldShares() public {
        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({deadline: MILESTONE_1_DEADLINE, cumulativeAmount: MILESTONE_1_AMOUNT});

        OTCSaleParams memory params = OTCSaleParams({
            underlyingToken: address(underlying),
            seller: seller,
            totalShares: 1_000_000e18,
            bondToken: address(bondTokenERC20),
            bondAmount: BOND_AMOUNT,
            bondDeadline: BOND_DEADLINE,
            milestones: milestones
        });

        OTCSaleVault v2 = new OTCSaleVault(params);
        v2.transfer(buyer1, 700_000e18);
        v2.transfer(address(v2), 300_000e18);

        v2.settle();

        assertTrue(v2.$settled());
        assertEq(v2.$effectiveTotalShares(), 700_000e18);
        assertEq(v2.balanceOf(address(v2)), 0);
    }

    function test_settle_scalesMilestoneObligations() public {
        Milestone[] memory milestones = new Milestone[](1);
        milestones[0] = Milestone({deadline: MILESTONE_1_DEADLINE, cumulativeAmount: 1_000_000e18});

        OTCSaleParams memory params = OTCSaleParams({
            underlyingToken: address(underlying),
            seller: seller,
            totalShares: 1_000_000e18,
            bondToken: address(bondTokenERC20),
            bondAmount: BOND_AMOUNT,
            bondDeadline: BOND_DEADLINE,
            milestones: milestones
        });

        OTCSaleVault v2 = new OTCSaleVault(params);
        v2.transfer(buyer1, 500_000e18);
        v2.transfer(address(v2), 500_000e18);

        v2.settle();

        assertEq(v2.effectiveMilestoneAmount(0), 500_000e18);
    }

    function test_settle_revertsIfAlreadySettled() public {
        vault.settle();

        vm.expectRevert(IOTCSaleVault.AlreadySettled.selector);
        vault.settle();
    }

    function test_settle_noUnsoldShares() public {
        vault.settle();

        assertTrue(vault.$settled());
        assertEq(vault.$effectiveTotalShares(), TOTAL_SHARES);
    }

    // Full lifecycle

    function test_fullLifecycle() public {
        _postBond();
        vault.settle();

        _depositAndAdvance(MILESTONE_1_AMOUNT, MILESTONE_1_DEADLINE);
        vault.unlockMilestone(0);

        vm.prank(buyer1);
        uint256 redeemed1 = vault.redeem(100_000e18, buyer1, buyer1);
        assertGt(redeemed1, 0);
        assertEq(vault.$totalAssetsWithdrawn(), redeemed1);

        vm.prank(seller);
        vault.depositVesting(MILESTONE_2_AMOUNT - MILESTONE_1_AMOUNT);
        vm.warp(MILESTONE_2_DEADLINE);
        vault.unlockMilestone(1);

        vm.prank(buyer2);
        uint256 redeemed2 = vault.redeem(100_000e18, buyer2, buyer2);
        assertGt(redeemed2, 0);

        vm.prank(seller);
        vault.depositVesting(MILESTONE_3_AMOUNT - MILESTONE_2_AMOUNT);
        vm.warp(MILESTONE_3_DEADLINE);
        vault.unlockMilestone(2);

        vm.prank(seller);
        vault.reclaimBond();
    }

    // Helpers

    function _postBond() internal {
        vm.warp(BOND_DEADLINE - 1);
        vm.prank(seller);
        vault.postBond();
    }

    function _depositAndAdvance(uint128 _amount, uint64 _deadline) internal {
        vm.prank(seller);
        vault.depositVesting(_amount);
        vm.warp(_deadline);
    }
}
