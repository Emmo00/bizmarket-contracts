// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LoanVault} from "../src/LoanVault.sol";

contract MockStablecoin is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract LoanVaultTest is Test {
    uint256 internal constant WEEK = 1 weeks;
    uint256 internal constant INSTALLMENTS = 12;

    MockStablecoin internal stablecoin;
    LoanVault internal vault;

    address internal treasury = address(0xBEEF);
    address internal loanManager = address(0xCAFE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() external {
        stablecoin = new MockStablecoin();
        vault = new LoanVault(address(stablecoin), treasury, loanManager);

        stablecoin.mint(alice, 1_000_000_000);
        stablecoin.mint(loanManager, 1_000_000_000);

        vm.prank(alice);
        stablecoin.approve(address(vault), type(uint256).max);

        vm.prank(loanManager);
        stablecoin.approve(address(vault), type(uint256).max);
    }

    function testBuyInCreatesPositionAndSchedulesRoundPayout() external {
        uint256 amount = 100_000_000; // 100.000000

        vm.prank(alice);
        vault.buyIn(amount);

        assertEq(stablecoin.balanceOf(treasury), amount, "treasury should receive full gross amount");

        (uint256 principal, uint256 startTime, uint256 startRound, uint256 nbClaims, uint256 payoutAmount) =
            vault.positions(alice, 0);

        assertEq(principal, 99_000_000, "principal should be net of 1% fee");
        assertEq(startTime, block.timestamp, "startTime should be current block timestamp");
        assertEq(startRound, 0, "position should start at current round");
        assertEq(nbClaims, 0, "position claims should start at zero");
        assertEq(payoutAmount, 8_662_500, "weekly installment should include 5% yield over 12 installments");

        assertEq(vault.scheduledRoundPayout(1), payoutAmount, "round 1 payout should be scheduled");
        assertEq(vault.scheduledRoundPayout(12), payoutAmount, "round 12 payout should be scheduled");
    }

    function testClaimPayoutAfterOneFundedRound() external {
        uint256 amount = 100_000_000;

        vm.prank(alice);
        vault.buyIn(amount);

        vm.prank(loanManager);
        vault.depositYield();

        vm.warp(block.timestamp + WEEK);

        uint256 bobBalanceBefore = stablecoin.balanceOf(bob);

        vm.prank(alice);
        uint256 claimed = vault.claimPayout(bob);

        assertEq(claimed, 8_662_500, "should claim exactly one installment");
        assertEq(stablecoin.balanceOf(bob), bobBalanceBefore + claimed, "receiver should get claimed funds");
    }

    function testPayoutCalculationMatchesFormulaForDefaultParams() external {
        uint256 amount = 123_456_789;

        vm.prank(alice);
        vault.buyIn(amount);

        (,,,, uint256 payoutAmount) = vault.positions(alice, 0);

        uint256 expectedFee = (amount * 100) / 10_000;
        uint256 expectedNet = amount - expectedFee;
        uint256 expectedPayout = (expectedNet + ((expectedNet * 500) / 10_000)) / INSTALLMENTS;

        assertEq(payoutAmount, expectedPayout, "payout should match formula with default fee/yield");
    }

    function testPayoutCalculationUsesUpdatedAdminParameters() external {
        uint256 amount = 200_000_000;

        vm.prank(loanManager);
        vault.setBuyInFeePercentage(250); // 2.5%

        vm.prank(loanManager);
        vault.setYieldPercentage(800); // 8%

        vm.prank(alice);
        vault.buyIn(amount);

        (, uint256 startTime,,, uint256 payoutAmount) = vault.positions(alice, 0);

        uint256 expectedFee = (amount * 250) / 10_000;
        uint256 expectedNet = amount - expectedFee;
        uint256 expectedPayout = (expectedNet + ((expectedNet * 800) / 10_000)) / INSTALLMENTS;

        assertEq(startTime, block.timestamp, "position should be created for updated params");
        assertEq(payoutAmount, expectedPayout, "updated fee/yield should be used in payout computation");
    }

    function testOnlyLoanManagerCanCallAdminFunctions() external {
        vm.expectRevert("Only loan manager can call this function");
        vm.prank(alice);
        vault.depositYield();

        vm.expectRevert("Only loan manager can call this function");
        vm.prank(alice);
        vault.setBuyInFeePercentage(200);

        vm.expectRevert("Only loan manager can call this function");
        vm.prank(alice);
        vault.setYieldPercentage(800);
    }

    function testDepositYieldTooEarlyReverts() external {
        vm.prank(loanManager);
        vault.depositYield();

        vm.expectRevert("Funding round too early");
        vm.prank(loanManager);
        vault.depositYield();
    }

    function testDepositYieldPullsExactlyScheduledAmount() external {
        uint256 amount = 100_000_000;

        vm.prank(alice);
        vault.buyIn(amount);

        uint256 expectedRoundAmount = vault.totalNextPayoutAmount();
        uint256 managerBalanceBefore = stablecoin.balanceOf(loanManager);
        uint256 vaultBalanceBefore = stablecoin.balanceOf(address(vault));

        vm.prank(loanManager);
        vault.depositYield();

        assertEq(
            stablecoin.balanceOf(loanManager),
            managerBalanceBefore - expectedRoundAmount,
            "manager should fund exact scheduled amount"
        );
        assertEq(
            stablecoin.balanceOf(address(vault)),
            vaultBalanceBefore + expectedRoundAmount,
            "vault should receive exact scheduled amount"
        );
        assertEq(vault.currentRound(), 1, "funding should advance round by one");
    }

    function testDepositYieldRevertsWhenLoanManagerHasInsufficientBalance() external {
        uint256 amount = 100_000_000;

        vm.prank(alice);
        vault.buyIn(amount);

        uint256 managerBalance = stablecoin.balanceOf(loanManager);
        vm.prank(loanManager);
        stablecoin.transfer(address(0xDEAD), managerBalance);

        vm.expectRevert();
        vm.prank(loanManager);
        vault.depositYield();
    }

    function testUserCannotBuyInAndClaimImmediatelyAfterRoundUpdate() external {
        vm.prank(loanManager);
        vault.depositYield();

        vm.prank(alice);
        vault.buyIn(100_000_000);

        vm.expectRevert("No payouts available to claim");
        vm.prank(alice);
        vault.claimPayout(alice);
    }

    function testUserCannotClaimImmediatelyAfterRoundUpdateWithoutWaitingInterval() external {
        vm.prank(alice);
        vault.buyIn(100_000_000);

        vm.prank(loanManager);
        vault.depositYield();

        vm.expectRevert("No payouts available to claim");
        vm.prank(alice);
        vault.claimPayout(alice);
    }

    function testZeroInstallmentPositionCannotBeClaimedAfterMaturity() external {
        vm.prank(alice);
        vault.buyIn(1); // Produces payoutAmount == 0 due to integer division by 12

        for (uint256 i = 0; i < 12; i++) {
            if (i > 0) {
                vm.warp(block.timestamp + WEEK);
            }
            vm.prank(loanManager);
            vault.depositYield();
        }

        vm.warp(block.timestamp + WEEK);

        vm.expectRevert("No payouts available to claim");
        vm.prank(alice);
        vault.claimPayout(alice);

        // Position remains stuck because claim reverts and state updates roll back.
        (,,, uint256 nbClaims,) = vault.positions(alice, 0);
        assertEq(nbClaims, 0, "position should still be unclaimed after reverted claim");
    }
}
