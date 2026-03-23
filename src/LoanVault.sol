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
    uint256 public lastClaimEpoch;
    uint256 public currentRound; // starts at 0, increments by 1 at each funding round

    mapping(uint256 => uint256) public scheduledRoundPayout; // round index => total payout amount scheduled for this round (sum of all positions installments that should be paid at this round)

    address public treasury;
    address public loanManager;

    struct Position {
        uint256 principal; // Amount of stablecoin deposited
        uint256 startTime; // Timestamp when the position was opened
        uint256 startRound; // Funding round index when position was opened
        uint256 nbClaims; // total number of times the owner of this position has claimed payout
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
                startRound: currentRound,
                nbClaims: 0,
                payoutAmount: nextPayoutAmount
            })
        );

        // Schedule one installment per future funded round.
        for (uint256 installment = 1; installment <= NB_OF_PAYOUT_INSTALLATIONS;) {
            scheduledRoundPayout[currentRound + installment] += nextPayoutAmount;
            unchecked {
                installment++;
            }
        }

        emit PositionBoughtIn(msg.sender, amount, fee, netAmount, nextPayoutAmount);
    }

    function claimPayout(address receiver) external returns (uint256) {
        require(receiver != address(0), "Receiver cannot be zero address");

        Position[] storage userPositions = positions[msg.sender];
        require(userPositions.length > 0, "No active positions");

        uint256 totalPayoutToClaim = 0;

        for (uint256 i = userPositions.length; i > 0;) {
            uint256 index = i - 1;
            Position storage position = userPositions[index];

            uint256 unlockedByRounds = 0;
            if (currentRound > position.startRound) {
                unlockedByRounds = currentRound - position.startRound;
            }

            uint256 unlockedByTime = (block.timestamp - position.startTime) / PAYOUT_INTERVAL;

            uint256 unlockedInstallments = unlockedByRounds; // min(unlockedByRounds, unlockedByTime, NB_OF_PAYOUT_INSTALLATIONS)
            if (unlockedByTime < unlockedInstallments) {
                unlockedInstallments = unlockedByTime;
            }

            if (unlockedInstallments > NB_OF_PAYOUT_INSTALLATIONS) {
                unlockedInstallments = NB_OF_PAYOUT_INSTALLATIONS;
            }

            if (position.nbClaims < unlockedInstallments) {
                uint256 nbPendingClaims = unlockedInstallments - position.nbClaims;
                totalPayoutToClaim += nbPendingClaims * position.payoutAmount;
                position.nbClaims = unlockedInstallments;
            }

            if (position.nbClaims == NB_OF_PAYOUT_INSTALLATIONS) {
                // delete position from user list
                userPositions[index] = userPositions[userPositions.length - 1];
                userPositions.pop();
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

        uint256 roundToFund = currentRound + 1;
        uint256 amountToDeposit = scheduledRoundPayout[roundToFund];

        // Deposit the specified amount of stablecoin as yield to be distributed to depositors
        require(STABLECOIN.transferFrom(msg.sender, address(this), amountToDeposit), "Transfer failed");

        // Advance to the newly funded round.
        currentRound = roundToFund;
        lastClaimEpoch = block.timestamp;

        emit YieldDeposited(msg.sender, amountToDeposit, lastClaimEpoch);
    }

    function setBuyInFeePercentage(uint256 _buyInFeePercentage) external onlyLoanManager {
        require(_buyInFeePercentage <= 10000, "Buy-in fee percentage cannot exceed 10000 (100%)");
        uint256 previousValue = buyInFeePercentage;
        buyInFeePercentage = _buyInFeePercentage;

        emit BuyInFeePercentageUpdated(previousValue, _buyInFeePercentage);
    }

    function setYieldPercentage(uint256 _yieldPercentage) external onlyLoanManager {
        require(_yieldPercentage <= 10000, "Yield percentage cannot exceed 10000 (100%)");
        uint256 previousValue = yieldPercentage;
        yieldPercentage = _yieldPercentage;

        emit YieldPercentageUpdated(previousValue, _yieldPercentage);
    }

    function totalNextPayoutAmount() external view returns (uint256) {
        return scheduledRoundPayout[currentRound + 1];
    }

    function _onlyLoanManager() internal view {
        require(msg.sender == loanManager, "Only loan manager can call this function");
    }
}
