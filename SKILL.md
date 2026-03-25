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
The protocol is a time-locked, round-funded payout vault:
- Users buy in with a stablecoin amount.
- A buy-in fee is taken (in basis points), and net principal is recorded as a position.
- The position total value is increased by a yield percentage (basis points), then split into 12 equal installments.
- Installments unlock only when both constraints are satisfied:
  - enough wall-clock time has passed (1 week per installment), and
  - enough funding rounds have been advanced by the loan manager.
- The loan manager must fund each round by calling depositYield() at least 1 week apart.

## Core Concepts
- Stablecoin source of truth: STABLECOIN (IERC20).
- Installment cadence: PAYOUT_INTERVAL = 1 week.
- Installment count: NB_OF_PAYOUT_INSTALLATIONS = 12.
- Rounds: currentRound starts at 0 and increments on each successful depositYield().
- Scheduled liabilities: scheduledRoundPayout[round] stores aggregate installment obligations due for that round.
- Position fields:
  - principal: net principal after fee
  - startTime: timestamp at buy-in
  - startRound: round index at buy-in
  - nbClaims: installments already claimed
  - payoutAmount: fixed amount claimable per installment

## Access Model
There are two control domains:
- Loan manager domain (custom role in LoanVault): can fund rounds and update fee/yield parameters.
- Ownable domain (inherited from ToronetOwnable): owner/initialOwner controls ownership management and destroy().

Important: LoanVault admin functions are restricted by onlyLoanManager, not by onlyOwner.

## User-Facing Flow
1. User approves LoanVault to spend stablecoin.
2. User calls buyIn(amount).
3. Loan manager periodically calls depositYield() (weekly).
4. User calls claimPayout(receiver) when installments have unlocked.
5. After 12 claimed installments for a position, it is removed automatically.

## Admin/Manager Flow
1. Loan manager keeps allowance and stablecoin balance ready.
2. Calls depositYield() no more than once per week.
3. Optionally calls setBuyInFeePercentage(...) and setYieldPercentage(...).
4. Monitors totalNextPayoutAmount() to estimate next funding amount.

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
  - payoutAmount = (netAmount + netAmount * yieldPercentage / 10000) / 12
  - creates new position for msg.sender
  - adds payoutAmount to scheduledRoundPayout for next 12 rounds
- Emits: PositionBoughtIn

2. claimPayout(address receiver) returns (uint256)
- Access: anyone for their own positions
- Preconditions:
  - receiver != address(0)
  - user has at least one active position
  - at least one installment is unlocked across positions
  - vault has enough STABLECOIN balance for total claim
- Unlock logic per position:
  - unlockedByRounds = max(currentRound - startRound, 0)
  - unlockedByTime = (block.timestamp - startTime) / 1 week
  - unlockedInstallments = min(unlockedByRounds, unlockedByTime, 12)
- Effects:
  - claims all newly unlocked installments across all caller positions
  - updates nbClaims
  - removes fully claimed positions (12/12)
  - transfers total payout to receiver
- Emits: PayoutClaimed

### Loan Manager Admin Methods (onlyLoanManager)
1. depositYield()
- Access: loanManager only
- Preconditions:
  - first call always allowed
  - subsequent calls require block.timestamp >= lastClaimEpoch + 1 week
  - loanManager approved vault for STABLECOIN transferFrom
  - loanManager has enough STABLECOIN to fund scheduled amount
- Effects:
  - roundToFund = currentRound + 1
  - amountToDeposit = scheduledRoundPayout[roundToFund]
  - transferFrom(loanManager -> vault, amountToDeposit)
  - currentRound = roundToFund
  - lastClaimEpoch = block.timestamp
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

### Public Read Methods / Getters (anyone)
1. totalNextPayoutAmount() returns (uint256)
- Returns scheduledRoundPayout[currentRound + 1]

2. STABLECOIN() returns (address)
3. PAYOUT_INTERVAL() returns (uint256)
4. NB_OF_PAYOUT_INSTALLATIONS() returns (uint256)
5. buyInFeePercentage() returns (uint256)
6. yieldPercentage() returns (uint256)
7. lastClaimEpoch() returns (uint256)
8. currentRound() returns (uint256)
9. scheduledRoundPayout(uint256 round) returns (uint256)
10. treasury() returns (address)
11. loanManager() returns (address)
12. positions(address user, uint256 index) returns (uint256 principal, uint256 startTime, uint256 startRound, uint256 nbClaims, uint256 payoutAmount)

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
- PositionBoughtIn(account, grossAmount, feeAmount, netPrincipal, payoutPerInstallment)
- PayoutClaimed(account, receiver, amountClaimed)
- YieldDeposited(loanManager, amount, claimEpoch)
- BuyInFeePercentageUpdated(previousValue, newValue)
- YieldPercentageUpdated(previousValue, newValue)
- OwnershipTransferred(previousOwner, newOwner) (inherited)

## Math Rules (Basis Points)
Use basis points convention:
- 100 = 1%
- 500 = 5%
- 10000 = 100%

Key formulas:
- fee = amount * buyInFeePercentage / 10000
- net = amount - fee
- grossWithYield = net + (net * yieldPercentage / 10000)
- payoutPerInstallment = grossWithYield / 12

Integer division truncates toward zero.

## Important Caveats and Risks
When explaining the protocol, always mention these:
1. Zero-installment trap:
- Very small buy-ins can produce payoutAmount == 0 due to integer division by 12.
- Such positions can become effectively unclaimable (claim reverts with no payout).

2. Funding dependency:
- Time passage alone is not enough. Claims also require funded rounds.
- If loan manager stops calling depositYield(), claims stall.

3. Linear claim complexity:
- claimPayout iterates all user positions; many positions can increase gas costs.

4. Token assumptions:
- Logic assumes standard ERC20 transfer behavior.

5. Inherited destroy() backdoor:
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
- Do not state that payouts unlock by time only.
