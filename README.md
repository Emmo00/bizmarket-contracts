# BizMarket Loan Vault Contracts

A Solidity contract system implementing a time-locked, yield-bearing loan vault with round-based funding and installment payouts.

## Overview

The `LoanVault` contract enables users to deposit stablecoins, receive a percentage fee deduction, and earn yield distributed over a fixed 12-week period (1 week per installment). Payouts are unlocked based on both block-time and funded funding rounds, whichever is more restrictive.

**Key mechanics:**
- Users buy in by depositing stablecoins; a configurable fee is deducted and the net principal earns yield.
- Yield is distributed as 12 equal weekly installments over 3 months.
- Funding rounds must be manually triggered by a loan manager at least 1 week apart.
- Users can only claim available payouts if both conditions are met:
  - At least 1 week has passed since their position opened (by block time).
  - At least 1 funded round has passed since their position started (by round index).
- Positions are automatically deleted once all 12 installments have been claimed.

## Contract Architecture

### LoanVault.sol

Main vault contract. Manages user positions, yield distribution, and claims.

**Key State:**
- `STABLECOIN`: immutable ERC20 token for all transfers.
- `currentRound`: active funding round (starts at 0).
- `scheduledRoundPayout`: map of round → total installment amount owed for that round.
- `positions`: map of user → array of Position structs.
- `buyInFeePercentage`: configurable buy-in fee in basis points (default 100 = 1%).
- `yieldPercentage`: configurable annual yield in basis points (default 500 = 5%).

**Core Functions:**

| Function | Role | Access | Effect |
|----------|------|--------|--------|
| `buyIn(amount)` | Deposit stablecoin | Public | Deduct fee, create position, schedule payouts for 12 future rounds. |
| `claimPayout(receiver)` | Claim unlocked payouts | Public | Calculate unlocked installments (min of time/round unlock), transfer to receiver, delete fully matured positions. |
| `depositYield(amount)` | Fund vault liability | Loan Manager | Pull up to the provided amount from manager, capped at the vault shortfall. |
| `setLockPeriod(lockPeriod)` | Update lock period | Loan Manager | Sets `LOCK_PERIOD` used to determine maturity for all positions. |
| `setBuyInFeePercentage(%)` | Update fee | Loan Manager | Bounded to ≤ 10000 (100%). |
| `setYieldPercentage(%)` | Update yield | Loan Manager | Bounded to ≤ 10000 (100%). |

### ToronetStandard.sol

Base contract providing ownership and administrative controls. ⚠️ **Warning**: Contains a deprecated `destroy()` function (selfdestruct) callable by initial deployer. This is not recommended for production vaults on Cancun+ networks.

### LoanVaultEvents.sol

Event declarations for logging vault state changes.

### lib/Percentage.sol

Utility library for percentage calculations in basis points (100 = 1%, 10000 = 100%).

## Key Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| `PAYOUT_INTERVAL` | 1 week | Minimum block time between installments. |
| `NB_OF_PAYOUT_INSTALLATIONS` | 12 | Total installments per position (3 months). |
| `buyInFeePercentage` | 100 bps (1%) | Configurable; capped at 10000. |
| `yieldPercentage` | 500 bps (5%) | Configurable; capped at 10000. |

## Usage

### User Flow

1. **Approve token**: User approves LoanVault to spend stablecoin.
   ```solidity
   IERC20(stablecoin).approve(vault, amount);
   ```

2. **Buy in**: Deposit principal + fee. Fee goes to treasury; principal is scheduled for yield payouts.
   ```solidity
   vault.buyIn(1_000_000); // e.g., 1M units (6 decimals = $1M)
   ```

3. **Wait for funding**: Loan manager must call `depositYield(amount)` weekly to fund the vault for payouts. Use `vault.nextYieldDepositAmount()` to compute the required amount.

4. **Claim after unlock**: Once both conditions are met (1 week passed + 1 funded round), claim payouts.
   ```solidity
   uint256 claimed = vault.claimPayout(receiver);
   ```

5. **Repeat weekly**: Call `claimPayout()` weekly to collect each installment until all 12 are withdrawn.

### Admin Flow (Loan Manager)

1. **Fund round weekly**: At most once per week, pull the total scheduled payout amount and advance the round. Use `nextYieldDepositAmount()` to determine the required amount.
   ```solidity
   uint256 amount = vault.nextYieldDepositAmount();
   vault.depositYield(amount);
   ```

2. **Update parameters** (optional): Adjust fee and yield percentages between buy-ins (only affects new positions).
   ```solidity
   vault.setBuyInFeePercentage(150);   // 1.5%
   vault.setYieldPercentage(800);      // 8%
   ```

3. **Adjust lock duration** (optional): Update maturity horizon for newly maturing claims.
   ```solidity
   vault.setLockPeriod(8 weeks);
   ```

## Testing

Run the full test suite:

```shell
forge test
```

Run only LoanVault tests:

```shell
forge test --match-path test/LoanVault.t.sol -vv
```

**Test Coverage:**
- Buy-in accounting and position creation.
- Payout calculation with default and custom parameters.
- Claim unlock logic (time + round constraints).
- Deposit yield funding and insufficient balance.
- Access control on admin functions.
- Zero-installment edge case (documented as known limitation).

## Build & Format

```shell
# Compile
forge build

# Format code
forge fmt
```

## Security Considerations

⚠️ **Known Issues (from audit):**

1. **Inherited selfdestruct backdoor**: `ToronetOwnable.destroy()` is callable by the initial deployer forever. On chains without EIP-6780 (legacy selfdestruct), this can permanently remove vault code and freeze all funds. 
   - **Mitigation**: Override `destroy()` to revert or remove this contract from the inheritance chain for production.

2. **Zero-installment trap**: Buy-ins smaller than 12 units produce `payoutAmount = 0` due to integer division. Claims revert with "No payouts available" and positions never complete.
   - **Mitigation**: Enforce minimum buy-in amount or track and skip zero-payout positions during claim.

3. **Non-standard token assumptions**: The contract assumes exact ERC20 transfer semantics. Fee-on-transfer or rebasing tokens will cause accounting mismatches.
   - **Mitigation**: Restrict to known standard stablecoins (USDC, USDT, etc.).

4. **Unbounded admin parameters**: No hard caps on `buyInFeePercentage` and `yieldPercentage` until runtime checks were added.
   - **Status**: Fixed in v1.0 with 10000 bps caps.

5. **Linear-time claims**: Each `claimPayout()` iterates all user positions. Users with many positions may hit gas limits.
   - **Mitigation**: Implement batched claiming or position consolidation.

## Deployment

### Prerequisites
- Foundry installed ([forge](https://book.getfoundry.sh/))
- RPC URL and private key for target network

### Example Deployment Script

```solidity
// script/DeployLoanVault.s.sol
import {Script} from "forge-std/Script.sol";
import {LoanVault} from "../src/LoanVault.sol";

contract DeployLoanVault is Script {
    function run() external {
        address stablecoin = 0x...; // e.g., USDC on Mainnet
        address treasury = 0x...;   // Fee collection address
      address loanManager = 0x...; // Funding manager address
      address positionTransferAdmin = 0x...; // Wallet allowed to transfer positions

      vm.startBroadcast();
      LoanVault vault = new LoanVault(stablecoin, treasury, loanManager, positionTransferAdmin);
        vm.stopBroadcast();
    }
}
```

Deploy:
```shell
forge script script/DeployLoanVault.s.sol:DeployLoanVault \
  --rpc-url https://mainnet.infura.io/v3/<KEY> \
  --private-key <YOUR_KEY> \
  --broadcast
```

## Dependencies

- **OpenZeppelin Contracts** (`@openzeppelin/contracts`): ERC20 interface and utilities.
- **Forge Std** (`forge-std`): Testing framework.

## License

MIT
