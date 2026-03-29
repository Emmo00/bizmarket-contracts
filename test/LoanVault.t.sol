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
    uint256 internal constant LOCK_PERIOD = 12 weeks;

    MockStablecoin internal stablecoin;
    LoanVault internal vault;

    address internal treasury = address(0xBEEF);
    address internal loanManager = address(0xCAFE);
    address internal transferAdmin = address(0xD00D);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() external {
        stablecoin = new MockStablecoin();
        vault = new LoanVault(address(stablecoin), treasury, loanManager, transferAdmin);

        stablecoin.mint(alice, 1_000_000_000);
        stablecoin.mint(loanManager, 1_000_000_000);

        vm.prank(alice);
        stablecoin.approve(address(vault), type(uint256).max);

        vm.prank(loanManager);
        stablecoin.approve(address(vault), type(uint256).max);
    }

    function testBuyInCreatesLockedPositionAndLiability() external {
        uint256 amount = 100_000_000; // 100.000000

        vm.prank(alice);
        vault.buyIn(amount);

        assertEq(stablecoin.balanceOf(treasury), amount, "treasury should receive full gross amount");

        (uint256 principal, uint256 startTime, uint256 payoutAmount) = vault.positions(alice, 0);

        uint256 expectedFee = (amount * 100) / 10_000;
        uint256 expectedNet = amount - expectedFee;
        uint256 expectedPayout = expectedNet + ((expectedNet * 500) / 10_000);

        assertEq(principal, expectedNet, "principal should be net of fee");
        assertEq(startTime, block.timestamp, "startTime should be current block timestamp");
        assertEq(payoutAmount, expectedPayout, "total payout should include full yield");
        assertEq(vault.totalLiability(), expectedPayout, "liability should track full payout");
    }

    function testCannotClaimBeforeMaturity() external {
        uint256 amount = 100_000_000;

        vm.prank(alice);
        vault.buyIn(amount);

        vm.expectRevert("No payouts available to claim");
        vm.prank(alice);
        vault.claimPayout(alice);
    }

    function testClaimPayoutAfterMaturityWhenFunded() external {
        uint256 amount = 100_000_000;

        vm.prank(alice);
        vault.buyIn(amount);

        vm.prank(loanManager);
        vault.depositYield();

        vm.warp(block.timestamp + LOCK_PERIOD);

        uint256 bobBalanceBefore = stablecoin.balanceOf(bob);
        uint256 expectedPayout = vault.totalLiability();

        vm.prank(alice);
        uint256 claimed = vault.claimPayout(bob);

        assertEq(claimed, expectedPayout, "should claim full matured payout");
        assertEq(stablecoin.balanceOf(bob), bobBalanceBefore + claimed, "receiver should get claimed funds");
        assertEq(vault.totalLiability(), 0, "liability should be cleared after claim");

        vm.expectRevert();
        vault.positions(alice, 0);
    }

    function testPayoutCalculationMatchesFormulaForDefaultParams() external {
        uint256 amount = 123_456_789;

        vm.prank(alice);
        vault.buyIn(amount);

        (,, uint256 payoutAmount) = vault.positions(alice, 0);
        uint256 expectedFee = (amount * 100) / 10_000;
        uint256 expectedNet = amount - expectedFee;
        uint256 expectedPayout = expectedNet + ((expectedNet * 500) / 10_000);

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

        (, uint256 startTime, uint256 payoutAmount) = vault.positions(alice, 0);

        uint256 expectedFee = (amount * 250) / 10_000;
        uint256 expectedNet = amount - expectedFee;
        uint256 expectedPayout = expectedNet + ((expectedNet * 800) / 10_000);

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

    function testDepositYieldRevertsWhenFullyFunded() external {
        vm.prank(alice);
        vault.buyIn(100_000_000);

        vm.prank(loanManager);
        vault.depositYield();

        vm.expectRevert("Vault already fully funded");
        vm.prank(loanManager);
        vault.depositYield();
    }

    function testDepositYieldPullsExactShortfall() external {
        uint256 amount = 100_000_000;

        vm.prank(alice);
        vault.buyIn(amount);

        uint256 expectedRoundAmount = vault.nextYieldDepositAmount();
        uint256 managerBalanceBefore = stablecoin.balanceOf(loanManager);
        uint256 vaultBalanceBefore = stablecoin.balanceOf(address(vault));

        vm.prank(loanManager);
        vault.depositYield();

        assertEq(
            stablecoin.balanceOf(loanManager),
            managerBalanceBefore - expectedRoundAmount,
            "manager should fund exact shortfall"
        );
        assertEq(
            stablecoin.balanceOf(address(vault)),
            vaultBalanceBefore + expectedRoundAmount,
            "vault should receive exact shortfall"
        );
        assertEq(vault.nextYieldDepositAmount(), 0, "shortfall should be zero after funding");
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

    function testPositionTransferOnlyByTransferAdmin() external {
        vm.prank(alice);
        vault.buyIn(100_000_000);

        vm.prank(alice);
        vm.expectRevert("Only position transfer admin can call this function");
        vault.transferPosition(alice, bob, 0);

        vm.prank(transferAdmin);
        vault.transferPosition(alice, bob, 0);

        vm.expectRevert();
        vault.positions(alice, 0);

        (uint256 principal, uint256 startTime, uint256 payoutAmount) = vault.positions(bob, 0);
        assertGt(principal, 0, "transferred position principal should be preserved");
        assertGt(startTime, 0, "transferred position startTime should be preserved");
        assertGt(payoutAmount, 0, "transferred position payout should be preserved");
    }

    function testTransferredPositionCanBeClaimedByRecipientAtMaturity() external {
        uint256 amount = 100_000_000;

        vm.prank(alice);
        vault.buyIn(amount);

        vm.prank(transferAdmin);
        vault.transferPosition(alice, bob, 0);

        vm.prank(loanManager);
        vault.depositYield();

        vm.warp(block.timestamp + LOCK_PERIOD);

        uint256 bobBalanceBefore = stablecoin.balanceOf(bob);

        vm.prank(bob);
        uint256 claimed = vault.claimPayout(bob);

        assertGt(claimed, 0, "recipient should be able to claim transferred matured position");
        assertEq(stablecoin.balanceOf(bob), bobBalanceBefore + claimed, "recipient should receive payout");
    }

    function testOnlyOwnerCanSetPositionTransferAdmin() external {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(alice);
        vault.setPositionTransferAdmin(bob);

        vault.setPositionTransferAdmin(bob);
        assertEq(vault.positionTransferAdmin(), bob, "owner should be able to update transfer admin");
    }
}
