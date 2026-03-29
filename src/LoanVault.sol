// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Percentage} from "./lib/Percentage.sol";
import {ToronetOwnable} from "./ToronetStandard.sol";
import {LoanVaultEvents} from "./LoanVaultEvents.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LoanVault is ToronetOwnable, LoanVaultEvents {
    IERC20 public immutable STABLECOIN;

    uint256 public constant LOCK_PERIOD = 12 weeks; // 3 months

    uint256 public buyInFeePercentage = 100; // 1% fee
    uint256 public yieldPercentage = 500; // 5% yield
    uint256 public totalLiability; // Total payout amount that the vault is liable for across all active positions

    address public treasury;
    address public loanManager;
    address public positionTransferAdmin;

    struct Position {
        uint256 principal; // Amount of stablecoin deposited
        uint256 startTime; // Timestamp when the position was opened
        uint256 payoutAmount; // Total payout amount claimable after lock period
    }

    mapping(address => Position[]) public positions;

    modifier onlyLoanManager() {
        _onlyLoanManager();
        _;
    }

    modifier onlyPositionTransferAdmin() {
        _onlyPositionTransferAdmin();
        _;
    }

    constructor(address _stablecoin, address _treasury, address _loanManager, address _positionTransferAdmin) {
        require(_stablecoin != address(0), "Stablecoin cannot be zero address");
        require(_treasury != address(0), "Treasury cannot be zero address");
        require(_loanManager != address(0), "Loan manager cannot be zero address");
        require(_positionTransferAdmin != address(0), "Position transfer admin cannot be zero address");

        STABLECOIN = IERC20(_stablecoin);
        treasury = _treasury;
        loanManager = _loanManager;
        positionTransferAdmin = _positionTransferAdmin;

        emit LoanVaultInitialized(_stablecoin, _treasury, _loanManager);
        emit PositionTransferAdminUpdated(address(0), _positionTransferAdmin);
    }

    function buyIn(uint256 amount) external {
        require(amount > 0, "Amount must be greater than 0");

        // Calculate the fee and the net amount to be deposited
        uint256 fee = Percentage.calculate(amount, buyInFeePercentage);
        uint256 netAmount = amount - fee;

        // Transfer the total amount from the depositor to the treasury vault
        require(STABLECOIN.transferFrom(msg.sender, treasury, amount), "Transfer failed");

        // Calculate total payout amount that becomes claimable after lock period.
        uint256 totalPayoutAmount = Percentage.increaseByPercentage(netAmount, yieldPercentage);

        // Create a new position for the depositor
        positions[msg.sender].push(
            Position({principal: netAmount, startTime: block.timestamp, payoutAmount: totalPayoutAmount})
        );

        totalLiability += totalPayoutAmount;

        emit PositionBoughtIn(msg.sender, amount, fee, netAmount, totalPayoutAmount);
    }

    function claimPayout(address receiver) external returns (uint256) {
        require(receiver != address(0), "Receiver cannot be zero address");

        Position[] storage userPositions = positions[msg.sender];
        require(userPositions.length > 0, "No active positions");

        uint256 totalPayoutToClaim = 0;

        for (uint256 i = userPositions.length; i > 0;) {
            uint256 index = i - 1;
            Position storage position = userPositions[index];

            if (block.timestamp >= position.startTime + LOCK_PERIOD) {
                totalPayoutToClaim += position.payoutAmount;
                totalLiability -= position.payoutAmount;

                // Delete matured position from user list.
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

    function availablePayout(address account) external view returns (uint256) {
        if (account == address(0)) {
            return 0;
        }

        Position[] storage userPositions = positions[account];
        uint256 maturedPayout = 0;

        for (uint256 i = 0; i < userPositions.length;) {
            Position storage position = userPositions[i];

            if (block.timestamp >= position.startTime + LOCK_PERIOD) {
                maturedPayout += position.payoutAmount;
            }

            unchecked {
                i++;
            }
        }

        // claimPayout requires full funding for the matured amount; partial claims are not supported.
        if (STABLECOIN.balanceOf(address(this)) < maturedPayout) {
            return 0;
        }

        return maturedPayout;
    }

    // ========= admin functions =========
    function depositYield() external onlyLoanManager {
        uint256 currentBalance = STABLECOIN.balanceOf(address(this));
        require(currentBalance < totalLiability, "Vault already fully funded");

        uint256 amountToDeposit = totalLiability - currentBalance;

        // Deposit required stablecoin to fully collateralize all active positions.
        require(STABLECOIN.transferFrom(msg.sender, address(this), amountToDeposit), "Transfer failed");

        emit YieldDeposited(msg.sender, amountToDeposit, block.timestamp);
    }

    function setPositionTransferAdmin(address _positionTransferAdmin) external onlyOwner {
        require(_positionTransferAdmin != address(0), "Position transfer admin cannot be zero address");

        address previousAdmin = positionTransferAdmin;
        positionTransferAdmin = _positionTransferAdmin;

        emit PositionTransferAdminUpdated(previousAdmin, _positionTransferAdmin);
    }

    function transferPosition(address from, address to, uint256 positionIndex) external onlyPositionTransferAdmin {
        require(from != address(0), "From cannot be zero address");
        require(to != address(0), "To cannot be zero address");

        Position[] storage fromPositions = positions[from];
        require(positionIndex < fromPositions.length, "Invalid position index");

        Position memory positionToTransfer = fromPositions[positionIndex];

        fromPositions[positionIndex] = fromPositions[fromPositions.length - 1];
        fromPositions.pop();
        positions[to].push(positionToTransfer);

        emit PositionTransferred(
            msg.sender,
            from,
            to,
            positionIndex,
            positionToTransfer.principal,
            positionToTransfer.payoutAmount,
            positionToTransfer.startTime
        );
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

    function nextYieldDepositAmount() external view returns (uint256) {
        uint256 currentBalance = STABLECOIN.balanceOf(address(this));
        if (currentBalance >= totalLiability) {
            return 0;
        }

        return totalLiability - currentBalance;
    }

    function _onlyLoanManager() internal view {
        require(msg.sender == loanManager, "Only loan manager can call this function");
    }

    function _onlyPositionTransferAdmin() internal view {
        require(msg.sender == positionTransferAdmin, "Only position transfer admin can call this function");
    }
}
