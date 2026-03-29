---
name: bizmarket-loanvault-protocol-explainer
description: Use this skill to explain the BizMarket LoanVault protocol, including architecture, lifecycle, payout mechanics, risks, and all externally exposed methods for regular users and admins.
---

# BizMarket LoanVault Protocol Explainer Skill

## Purpose
Use this skill whenever a user asks how the BizMarket LoanVault protocol works, what methods are available, or how to interact as a regular user or as an admin/manager.

This skill is specific to the contracts in this repository:
- src/LoanVault.sol
- src/ToronetStandard.sol
- src/LoanVaultEvents.sol
- src/lib/Percentage.sol

Do not invent behavior not present in those contracts.

## Protocol Summary
The protocol is a time-locked, maturity-claim vault:
- Users buy in with a stablecoin amount.
- A buy-in fee is taken (in basis points), and net principal is recorded as a position.
- The net principal is increased by a yield percentage to produce one total payout amount.
- Funds are locked for a fixed 3-month period (LOCK_PERIOD = 12 weeks).
- Users can claim only after lock maturity, and they receive matured position payouts in a single claim transaction.
- The loan manager funds the vault by topping up the current shortfall between vault balance and total outstanding liability.
- Position ownership can be migrated only by a dedicated transfer-admin wallet.

## Core Concepts
- Stablecoin source of truth: STABLECOIN (IERC20).
- Lock period: LOCK_PERIOD = 12 weeks.
- Liability accounting: totalLiability stores aggregate payout obligations across all active positions.
- Position fields:
  - principal: net principal after fee
  - startTime: timestamp at buy-in
  - payoutAmount: full amount claimable after maturity

## Access Model
There are three control domains:
- Loan manager domain (custom role in LoanVault): can fund rounds and update fee/yield parameters.
- Position transfer admin domain (custom role in LoanVault): can transfer positions between wallets.
- Ownable domain (inherited from ToronetOwnable): owner/initialOwner controls ownership management and destroy().

Important:
- Funding/fee/yield admin functions are restricted by onlyLoanManager.
- Position transfer function is restricted by onlyPositionTransferAdmin.
- setPositionTransferAdmin(...) is restricted by onlyOwner.

## User-Facing Flow
1. User approves LoanVault to spend stablecoin.
2. User calls buyIn(amount).
3. Loan manager funds vault shortfall by calling depositYield() as needed.
4. User waits until at least 3 months have elapsed for each position.
5. User calls claimPayout(receiver) to claim all matured positions.
6. Claimed matured positions are removed automatically.

## Admin/Manager Flow
1. Loan manager keeps allowance and stablecoin balance ready.
2. Calls depositYield() when vault balance is below totalLiability.
3. Optionally calls setBuyInFeePercentage(...) and setYieldPercentage(...).
4. Monitors nextYieldDepositAmount() as current funding shortfall.
5. Owner can rotate transfer admin with setPositionTransferAdmin(...).
6. Transfer admin can call transferPosition(from, to, index) for admin-gated migrations.

## Externally Exposed Methods
List all externally callable methods and public getters below when explaining API surface.

### Regular User Methods
1. buyIn(uint256 amount)
- Access: anyone
- Preconditions:
  - amount > 0
  - user approved STABLECOIN transferFrom to vault
- Effects:
  - transfers gross amount from user to treasury
  - computes fee = amount * buyInFeePercentage / 10000
  - netAmount = amount - fee
  - payoutAmount = netAmount + netAmount * yieldPercentage / 10000
  - creates new position for msg.sender
  - increases totalLiability by payoutAmount
- Emits: PositionBoughtIn

2. claimPayout(address receiver) returns (uint256)
- Access: anyone for their own positions
- Preconditions:
  - receiver != address(0)
  - user has at least one active position
  - at least one position has matured: block.timestamp >= position.startTime + LOCK_PERIOD
  - vault has enough STABLECOIN balance for total claim
- Effects:
  - sums payoutAmount for all matured positions owned by caller
  - decreases totalLiability by claimed matured amounts
  - removes matured positions from caller position array
  - transfers total payout to receiver
- Emits: PayoutClaimed

### Loan Manager Admin Methods (onlyLoanManager)
1. depositYield()
- Access: loanManager only
- Preconditions:
  - vault must not already be fully funded (balance < totalLiability)
  - loanManager approved vault for STABLECOIN transferFrom
  - loanManager has enough STABLECOIN to fund shortfall
- Effects:
  - amountToDeposit = totalLiability - STABLECOIN.balanceOf(vault)
  - transferFrom(loanManager -> vault, amountToDeposit)
- Emits: YieldDeposited

2. setBuyInFeePercentage(uint256 _buyInFeePercentage)
- Access: loanManager only
- Preconditions:
  - _buyInFeePercentage <= 10000
- Effects:
  - updates buyInFeePercentage for future buy-ins
- Emits: BuyInFeePercentageUpdated

3. setYieldPercentage(uint256 _yieldPercentage)
- Access: loanManager only
- Preconditions:
  - _yieldPercentage <= 10000
- Effects:
  - updates yieldPercentage for future buy-ins
- Emits: YieldPercentageUpdated

### Position Transfer Admin Methods
1. transferPosition(address from, address to, uint256 positionIndex)
- Access: positionTransferAdmin only
- Preconditions:
  - from != address(0)
  - to != address(0)
  - positionIndex is valid for positions[from]
- Effects:
  - removes selected position from from
  - appends same position to to
  - does not change totalLiability
- Emits: PositionTransferred

### Owner Methods Specific To Transfer Admin
1. setPositionTransferAdmin(address _positionTransferAdmin)
- Access: onlyOwner
- Preconditions:
  - _positionTransferAdmin != address(0)
- Effects:
  - updates positionTransferAdmin role wallet
- Emits: PositionTransferAdminUpdated

### Public Read Methods / Getters (anyone)
1. nextYieldDepositAmount() returns (uint256)
- Returns max(totalLiability - STABLECOIN.balanceOf(vault), 0)

2. STABLECOIN() returns (address)
3. LOCK_PERIOD() returns (uint256)
4. buyInFeePercentage() returns (uint256)
5. yieldPercentage() returns (uint256)
6. totalLiability() returns (uint256)
7. treasury() returns (address)
8. loanManager() returns (address)
9. positionTransferAdmin() returns (address)
10. availablePayout(address account) returns (uint256)
- Returns currently claimable matured payout for the input account.
- Returns 0 if no position is matured yet.
- Returns 0 if vault balance cannot fully fund the matured amount (claimPayout is all-or-nothing).
11. getPositions(address account) returns (Position[])
- Returns the full in-memory list of positions for the input account.
- Each position entry contains principal, startTime, and payoutAmount.
12. positions(address user, uint256 index) returns (uint256 principal, uint256 startTime, uint256 payoutAmount)

### Inherited Ownable Methods (ToronetOwnable)
These are also externally exposed by LoanVault inheritance:
1. owner() returns (address)
- Access: anyone

2. transferOwnership(address newOwner)
- Access: onlyOwner
- Note: changes ownable owner, not loanManager.

3. renounceOwnership()
- Access: onlyOwner

4. destroy()
- Access: onlyInitialOwner (deployer of ToronetOwnable lineage)
- Behavior: selfdestruct(payable(initialOwner))
- Security note: dangerous/deprecated pattern; treat as critical risk in production analysis.

## Event Surface
- LoanVaultInitialized(stablecoin, treasury, loanManager)
- PositionBoughtIn(account, grossAmount, feeAmount, netPrincipal, payoutAmount)
- PayoutClaimed(account, receiver, amountClaimed)
- YieldDeposited(loanManager, amount, claimEpoch)
- BuyInFeePercentageUpdated(previousValue, newValue)
- YieldPercentageUpdated(previousValue, newValue)
- PositionTransferAdminUpdated(previousAdmin, newAdmin)
- PositionTransferred(operator, from, to, positionIndex, principal, payoutAmount, startTime)
- OwnershipTransferred(previousOwner, newOwner) (inherited)

## Math Rules (Basis Points)
Use basis points convention:
- 100 = 1%
- 500 = 5%
- 10000 = 100%

Key formulas:
- fee = amount * buyInFeePercentage / 10000
- net = amount - fee
- payoutAmount = net + (net * yieldPercentage / 10000)
- fundingShortfall = max(totalLiability - vaultBalance, 0)

Integer division truncates toward zero.

## Important Caveats and Risks
When explaining the protocol, always mention these:
1. Full lock behavior:
- Users cannot claim anything before lock maturity; no weekly or partial installment claims exist.

2. Funding dependency:
- Time maturity alone is not enough. Vault still needs enough funded balance for payout transfer.
- If loan manager does not top up shortfall, matured claims can still fail.

3. Linear claim complexity:
- claimPayout iterates all user positions; many positions can increase gas costs.

4. Token assumptions:
- Logic assumes standard ERC20 transfer behavior.

5. Configuration edge case:
- If buyInFeePercentage is set to 10000 (100%), net principal and payout can become 0.
- Zero-payout matured positions can make claimPayout revert with "No payouts available to claim" for affected users.

6. Inherited destroy() backdoor:
- initialOwner can call destroy(); this can be catastrophic depending on chain semantics.

## Response Behavior For The Agent
When this skill is used, answer with this structure:
1. One-paragraph high-level explanation.
2. Split methods into:
- Regular user methods
- Loan manager admin methods
- Public read/getter methods
- Inherited ownable methods
3. For each method include:
- who can call
- required conditions
- state changes
- token movements
- emitted events
4. Include at least one end-to-end example flow for user and one for manager.
5. Include caveats section.
6. If asked for exactness, map statements to concrete function names and formulas.

## Out-of-Scope Guardrails
- Do not claim support for partial claims by position id (not implemented).
- Do not claim manager can directly withdraw vault funds (no such method in LoanVault).
- Do not conflate owner and loanManager roles.
- Do not state that payouts unlock weekly or by rounds.
- Do not omit the separate positionTransferAdmin role.
