# OTC Sale Vault

ERC4626 vault for trustless OTC token sales via [Uniswap CCA](https://github.com/Uniswap/twap-auction). Replaces intermediary escrow with a smart contract that enforces vesting schedules, milestone-gated redemption, and a seller bond backed by escrowed auction proceeds.

## How It Works

The vault is deployed as an ERC20 that serves as the `auctionToken` in a CCA auction. Shares are pre-minted to the deployer, who transfers them into the CCA. Buyers receive shares through the auction. The vault starts empty — the seller deposits underlying tokens over time per a predefined milestone schedule. Buyers redeem shares for underlying tokens as milestones unlock.

The vault holds a **unified currency pool** (seller bond + auction proceeds) in a single ERC20 token (e.g. USDC). As the seller completes milestones, a proportional share of the entire pool is released to them. If the seller misses a milestone deadline, anyone can trigger default, and share holders claim the remaining locked currency pro-rata.

## Architecture

```
src/
├── OTCSaleVault.sol              # Core vault (ERC4626 + currency escrow + milestones)
└── interfaces/
    ├── IOTCSaleVault.sol         # Interface, structs, errors, events
    └── ICCA.sol                  # Minimal CCA interface for sweep calls
```

## Vault + CCA Lifecycle

```mermaid
sequenceDiagram
    participant Seller
    participant Deployer
    participant Vault as OTCSaleVault
    participant CCA as CCA Auction
    participant Buyers

    Note over Seller,CCA: Setup Phase
    Seller->>Vault: send bond to predicted address (CREATE2)
    Deployer->>Vault: deploy(params) — checks bond, mints shares
    Deployer->>CCA: create auction (token=shares, fundsRecipient=vault, tokensRecipient=vault)
    Deployer->>CCA: transfer shares into auction

    Note over Seller,Buyers: Auction Phase
    Buyers->>CCA: bid (deposit currency)
    CCA-->>Buyers: distribute vault shares on claim

    Note over Vault: Settlement
    Deployer->>Vault: settleAuction(cca)
    Vault->>CCA: sweepUnsoldTokens() + sweepCurrency()
    Vault->>Vault: burn unsold shares, scale milestones, record proceeds

    Note over Seller,Buyers: Vesting Phase
    loop Each Milestone
        Seller->>Vault: depositVesting(amount)
        Vault->>Vault: unlockMilestone(i)
        Buyers->>Vault: redeem(shares) → underlying tokens
        Seller->>Vault: claimReleasedCurrency()
    end

    Note over Vault: All milestones met — 100% of pool released to seller
```

## Default + Recovery Flow

```mermaid
stateDiagram-v2
    [*] --> Active: deploy + settle

    Active --> MilestoneUnlocked: deadline passed, deposits sufficient
    MilestoneUnlocked --> Active: buyers redeem, seller claims currency

    Active --> Defaulted: missed milestone deadline
    MilestoneUnlocked --> Defaulted: missed next milestone

    Defaulted --> CurrencyClaim: claimOnDefault(shares)

    Active --> FullyReleased: all milestones fulfilled
    FullyReleased --> [*]
    CurrencyClaim --> [*]
```

## Key Accounting Details

| Concern | Mechanism |
|---|---|
| Unified currency pool | `BOND_AMOUNT + $totalAuctionProceeds` — bond and proceeds treated as one pool |
| Proportional release | After milestone *i*: `pool × milestone[i].cumAmount / milestone[last].cumAmount` released to seller |
| Bond at construction | Constructor checks `balanceOf(address(this)) >= bondAmount` — no separate `postBond()` |
| Redemption tracking | Explicit `$totalAssetsWithdrawn` counter (immune to donation attacks) |
| Default claim denominator | `$defaultCirculatingSupply` snapshot at time of default (no stranded funds) |
| Unsold shares | `settleAuction()` burns them, scales milestone obligations proportionally |
| Currency-only default | `claimOnDefault()` distributes locked currency; deposited underlying stays in vault |
| Donation resistance | Accounting uses explicit counters, not balance checks — extra tokens sent to vault have no effect |

## Deploy

The bond must be at the vault address before deployment. Use CREATE2 to predict the address.

```bash
# Set environment variables
export UNDERLYING_TOKEN=0x...
export SELLER=0x...
export TOTAL_SHARES=1000000000000000000000000
export CURRENCY=0x...
export BOND_AMOUNT=100000000000
export MILESTONE_DEADLINES=1700100000,1700200000,1700300000
export MILESTONE_AMOUNTS=250000000000000000000000,500000000000000000000000,1000000000000000000000000

forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
```

Shares are minted to the deployer. Next steps after deploy:
1. Transfer vault shares to the CCA auction contract (vault must be set as both `fundsRecipient` and `tokensRecipient`)
2. After auction ends, call `settleAuction(ccaAddress)` on the vault

## Build & Test

```bash
forge build
forge test
```
