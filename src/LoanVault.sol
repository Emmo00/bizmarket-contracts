// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Percentage} from "./lib/Percentage.sol";
import {ToronetOwnable} from "./ToronetStandard.sol";
import {LoanVaultEvents} from "./LoanVaultEvents.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LoanVault is ToronetOwnable, LoanVaultEvents {
    IERC20 public immutable STABLECOIN;

    uint256 public constant PAYOUT_INTERVAL = 1 weeks; // 1 week
    uint256 public constant NB_OF_PAYOUT_INSTALLATIONS = 12; // 1 per week for 3 months

    uint256 public buyInFeePercentage = 100; // 1% fee
    uint256 public yieldPercentage = 500; // 5% yield
    uint256 public totalNextPayoutAmount;
    uint256 public lastClaimEpoch;
    uint256[] public fundingEpochs;

    address public treasury;
    address public loanManager;

    struct Position {
        uint256 principal; // Amount of stablecoin deposited
        uint256 startTime; // Timestamp when the position was opened
        uint256 nbClaims; // total number of times the owner of this position has claimed payout
        uint256 fundedInstallments; // total number of installments unlocked by funded rounds
        uint256 lastProcessedFundingRound; // number of funding rounds already applied to this position
        uint256 payoutAmount; // Amount of the next payout to be claimed
    }

    mapping(address => Position[]) public positions;

    modifier onlyLoanManager() {
        _onlyLoanManager();
        _;
    }

    constructor(address _stablecoin, address _treasury, address _loanManager) {
        require(_stablecoin != address(0), "Stablecoin cannot be zero address");
        require(_treasury != address(0), "Treasury cannot be zero address");
        require(_loanManager != address(0), "Loan manager cannot be zero address");

        STABLECOIN = IERC20(_stablecoin);
        treasury = _treasury;
        loanManager = _loanManager;

        emit LoanVaultInitialized(_stablecoin, _treasury, _loanManager);
    }

    function buyIn(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");

        // Calculate the fee and the net amount to be deposited
        uint256 fee = Percentage.calculate(amount, buyInFeePercentage);
        uint256 netAmount = amount - fee;

        // Transfer the total amount from the depositor to the treasury vault
        require(STABLECOIN.transferFrom(msg.sender, treasury, amount), "Transfer failed");

        // calculate next payout amount for the position
        uint256 nextPayoutAmount =
            Percentage.increaseByPercentage(netAmount, yieldPercentage) / NB_OF_PAYOUT_INSTALLATIONS;

        // Create a new position for the depositor
        positions[msg.sender].push(
            Position({
                principal: netAmount,
                startTime: block.timestamp,
                nbClaims: 0,
                fundedInstallments: 0,
                lastProcessedFundingRound: fundingEpochs.length,
                payoutAmount: nextPayoutAmount
            })
        );

        // Update the total next payout amount for all positions
        totalNextPayoutAmount += nextPayoutAmount;

        emit PositionBoughtIn(msg.sender, amount, fee, netAmount, nextPayoutAmount);
    }

    function claimPayout(address receiver) external returns (uint256) {
        require(receiver != address(0), "Receiver cannot be zero address");

        Position[] storage userPositions = positions[msg.sender];
        require(userPositions.length > 0, "No active positions");

        uint256 totalPayoutToClaim = 0;
        uint256 totalFundingRounds = fundingEpochs.length;

        for (uint256 i = userPositions.length; i > 0;) {
            uint256 index = i - 1;
            Position storage position = userPositions[index];

            uint256 fundedInstallments = position.fundedInstallments;
            uint256 nextFundingRoundToProcess = position.lastProcessedFundingRound;

            while (nextFundingRoundToProcess < totalFundingRounds && fundedInstallments < NB_OF_PAYOUT_INSTALLATIONS) {
                uint256 fundingEpoch = fundingEpochs[nextFundingRoundToProcess];
                uint256 nextInstallmentUnlockTime =
                    position.startTime + ((fundedInstallments + 1) * PAYOUT_INTERVAL);

                // Each funding round can unlock at most one installment for a position,
                // and only when that installment lock period has elapsed.
                if (fundingEpoch >= nextInstallmentUnlockTime) {
                    fundedInstallments++;
                }

                nextFundingRoundToProcess++;
            }

            position.lastProcessedFundingRound = totalFundingRounds;
            position.fundedInstallments = fundedInstallments;

            if (position.nbClaims < fundedInstallments) {
                uint256 nbPendingClaims = fundedInstallments - position.nbClaims;
                totalPayoutToClaim += nbPendingClaims * position.payoutAmount;
                position.nbClaims = fundedInstallments;
            }

            if (position.nbClaims == NB_OF_PAYOUT_INSTALLATIONS) {
                // delete position from user list
                uint256 payoutAmount = position.payoutAmount;
                userPositions[index] = userPositions[userPositions.length - 1];
                userPositions.pop();

                // update total next payout amount for all positions
                totalNextPayoutAmount -= payoutAmount;
            }

            unchecked {
                i--;
            }
        }

        require(totalPayoutToClaim > 0, "No payouts available to claim");
        require(STABLECOIN.balanceOf(address(this)) >= totalPayoutToClaim, "Protocol not funded for payout");

        // Transfer the total payout amount to the depositor
        require(STABLECOIN.transfer(receiver, totalPayoutToClaim), "Transfer failed");

        emit PayoutClaimed(msg.sender, receiver, totalPayoutToClaim);

        return totalPayoutToClaim;
    }

    // ========= admin functions =========
    function depositYield() external onlyLoanManager {
        require(lastClaimEpoch == 0 || block.timestamp >= lastClaimEpoch + PAYOUT_INTERVAL, "Funding round too early");

        // Deposit the specified amount of stablecoin as yield to be distributed to depositors
        uint256 amountToDeposit = totalNextPayoutAmount;
        require(STABLECOIN.transferFrom(msg.sender, address(this), amountToDeposit), "Transfer failed");

        // New funded round unlock epoch.
        lastClaimEpoch = block.timestamp;
        fundingEpochs.push(lastClaimEpoch);

        emit YieldDeposited(msg.sender, amountToDeposit, lastClaimEpoch);
    }

    function setBuyInFeePercentage(uint256 _buyInFeePercentage) external onlyLoanManager {
        uint256 previousValue = buyInFeePercentage;
        buyInFeePercentage = _buyInFeePercentage;

        emit BuyInFeePercentageUpdated(previousValue, _buyInFeePercentage);
    }

    function setYieldPercentage(uint256 _yieldPercentage) external onlyLoanManager {
        uint256 previousValue = yieldPercentage;
        yieldPercentage = _yieldPercentage;

        emit YieldPercentageUpdated(previousValue, _yieldPercentage);
    }

    function _onlyLoanManager() internal view {
        require(msg.sender == loanManager, "Only loan manager can call this function");
    }
}
