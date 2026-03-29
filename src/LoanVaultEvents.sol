// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

abstract contract LoanVaultEvents {
    event LoanVaultInitialized(address indexed stablecoin, address indexed treasury, address indexed loanManager);

    event PositionBoughtIn(
        address indexed account, uint256 grossAmount, uint256 feeAmount, uint256 netPrincipal, uint256 payoutAmount
    );

    event PayoutClaimed(address indexed account, address indexed receiver, uint256 amountClaimed);

    event YieldDeposited(address indexed loanManager, uint256 amount, uint256 claimEpoch);

    event BuyInFeePercentageUpdated(uint256 previousValue, uint256 newValue);

    event YieldPercentageUpdated(uint256 previousValue, uint256 newValue);

    event PositionTransferAdminUpdated(address indexed previousAdmin, address indexed newAdmin);

    event PositionTransferred(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 positionIndex,
        uint256 principal,
        uint256 payoutAmount,
        uint256 startTime
    );
}
