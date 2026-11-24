# lavFACTORY

Permissionless factory and standard for Liquid Account Vaults (lavNFT) on Robinhood Chain.

Any project can create a sovereign vault for its ERC-20 token. Stakers deposit the project token and receive a transferable ERC-721 position NFT. Each position automatically controls its own deterministic ERC-6551 token-bound account (TBA).

> ⚠️ **These contracts have not undergone an independent security audit. Use at your own risk.** See [SECURITY.md](./SECURITY.md) and [docs/RISKS.md](./docs/RISKS.md).

---

## Core Protocol Contracts (Robinhood Chain, chainId 4663)

| Contract | Address | Type |
|---|---|---|
| `LavFactory` | `0x262d4d478eFe72Eb1731310a4f7A252644aA4B5F` | Permissionless Factory |
| Protocol Treasury | `0xeDbc87E40491b9edF65940acF63A5c0E81d8a4f1` | Safe (2/3 Multisig) |
| ERC-6551 Registry | `0x000000006551c19487814612e58FE06813775758` | Canonical Singleton |
| ERC-6551 Account Implementation | `0xC55D74fba44eb126ef5F6FbCcb93e443d4f40902` | Reference Implementation |

---

## How It Works

### 1. Permissionless Vault Creation
- Anyone can deploy a sovereign vault via `LavFactory.createVault(token, name, symbol, descriptor)`.
- Anti-spam creation fee: `CREATION_FEE = 0.002 ETH`, forwarded directly to the protocol treasury Safe.
- The factory is completely autonomous: **no owner, no admin, no pause**. The treasury, registry, and ERC-6551 implementation are `immutable`.
- `isVault(address) == true` on the factory confirms the vault was deployed by `LavFactory`.

### 2. Share Accounting & Virtual Offset
- Each deposit mints a unique position NFT. Token IDs are generated from a monotonic counter (`nextTokenId++`) and are never reused.
- Shares are calculated with a virtual offset (`SHARE_OFFSET = 1e6`) to protect against initial share inflation and donation exploits:
  $$\text{shares} = \frac{\text{received} \times (\text{totalShares} + 10^6)}{\text{totalBody} + 10^6}$$
- A deposit that would compute zero shares reverts (`Zero shares minted`).
- Accounting tracks balance deltas (`balAfter - balBefore`), safely accommodating fee-on-transfer tokens on deposit.

### 3. Dual-Engine Tokenomics

#### Engine 1: Body Growth (Staking Token)
- Staking tokens sent to the vault via transfer taxes or direct contribution increase the underlying principal (`totalBody`).
- While the vault has active positions (`totalShares > 0`), 10% is routed to the protocol treasury Safe and 90% is credited instantly to stakers pro rata.
- **Empty-vault tax sweep:** If staking-token tax arrives while `totalShares == 0` (before the first deposit, or after all positions have exited), there are no stakers to credit. In that case 10% goes to the protocol treasury Safe and 90% is transferred to the current vault owner (`TaxSweptEarly`). If ownership has been renounced (`owner == address(0)`), or if the transfer to the owner fails, the full amount goes to the protocol treasury Safe. This can occur any number of times over the vault's lifetime.

#### Engine 2: Yield Streaming (Reward Token)
- Incoming revenue (e.g. trading fees via ecosystem adapters or direct protocol yield) is streamed to active stakers:
  - 10% protocol fee to the protocol treasury Safe.
  - 90% distributed evenly over a continuous 24-hour stream (`STREAM_DURATION = 86400`).
- Any new yield arrival merges with unstreamed tokens (`remaining`) and initiates a fresh 24-hour linear release window.
- **Empty Vault Protection:** If all positions exit or before the first deposit (`totalShares == 0`), the stream timer pauses automatically (`periodFinish` shifts forward: `periodFinish += block.timestamp - last`). When a new deposit arrives, the stream resumes without any loss of reward funds.
- The vault owner receives no allocation of reward-token yield and cannot withdraw unstreamed staker funds. The only case where the owner receives staking tokens is the empty-vault tax sweep described in Engine 1.

### 4. Claiming & Ragequit Exit
- **Yield Claim (`claimYield`):** Accrued yield can be claimed at any time with 0% penalty and 0% withdrawal fees. The underlying position remains active.
- **Ragequit (`ragequit`):** 
  - Returns at least 95% of the position principal (`grossBody`).
  - Exactly 5% (`RAGEQUIT_BURN_BPS = 500`) is burned to `0x000000000000000000000000000000000000dEaD` (or held in `lockedBurn` if transfer to dead address is restricted), exerting perpetual deflationary pressure.
  - 100% of accrued yield is paid out with zero penalty.
  - The position NFT is permanently burned (`_burn(tokenId)`).

### 5. ERC-6551 Token Bound Accounts (TBA)
- Each minted position NFT automatically owns a deterministic smart contract account on Robinhood Chain.
- Account operations are restricted to `CALL` (`operation == 0`). `DELEGATECALL` and `CREATE` are disabled.
- Transferring the position NFT seamlessly transfers ownership of the account and all underlying assets held within it.
- ⚠️ **Critical Notice:** Always withdraw all assets from the position's token-bound account prior to executing `ragequit`. Burning the position NFT permanently revokes signer authorization for the account; any remaining tokens or airdrops become irrecoverable.

### 6. Vault Ownership & Descriptors
The vault creator is the initial vault owner with strictly scoped configuration capabilities:
- **Metadata & Appearance:** Can update the visual/metadata card descriptor (`setDescriptor`), base URI (`setBaseURI`), contract URI (`setContractURI`, `freezeContractURI`), and card color palette (`setPalette`).
- **Ownership Management:** Can transfer or renounce ownership by calling `transferOwnership(newOwner)` or `transferOwnership(address(0))`.
- **Empty-Vault Sweep Recipient:** Can receive 90% of staking-token tax that arrives while `totalShares == 0` (see *Empty-vault tax sweep*).

The owner **cannot** access user deposits, adjust fee parameters, pause the vault, block `claimYield` or `ragequit`, or withdraw streamed or unstreamed yield. The descriptor is executed exclusively via read-only `tokenURI` calls and cannot interrupt deposits, claims, or ragequits.

---

## Ecosystem Modules & Adapters

Ecosystem adapters route liquidity pool creator fees and external revenue streams into individual vaults. Each pool has its own deployed adapter instance:
- **`LavAdapterPns`:** Universal adapter for ERC-20 quote pairs (including USDG and tokenized stocks). Routes creator trading fees from PNS liquidity pair fee escrows into the corresponding vault. `usdg()` is the getter for the immutable pair token (either USDG or tokenized stock).
- **`LavAdapterPnsEth`:** Claims native ETH creator trading fees from PNS escrow, wraps them into WETH, and routes WETH yield into the vault stream.

### Fee Split & Protocol Treasury Mechanics
The protocol treasury receives 10% of all incoming creator fees regardless of `vaultShareBps` (with rounding dust favoring the team):
- **Vault portion:** `vaultShareBps` is expressed in bps of trading volume (minimum `MIN_VAULT_SHARE_BPS = 100`, i.e. 1%) and cannot exceed the pool's total creator fee (`totalCreatorBps`). The vault receives `vaultShareBps / totalCreatorBps` of every pulled amount. Inside the vault, 10% is retained by the protocol treasury (`YIELD_PROTOCOL_FEE_BPS = 1000`) and 90% is streamed over 24 hours to active stakers.
- **Team portion:** The remainder (`total - toVault`) is split: 90% to the project team wallet (`teamWallet`) and 10% to the protocol treasury (`PROTOCOL_SHARE_BPS = 1000`).
- **Non-blocking failure recovery:** Failed transfers accrue independently to `vaultOwed`, `teamOwed`, and `treasuryOwed`. Any caller can settle accrued debts permissionlessly via `claimVaultOwed()`, `claimTeamOwed()`, and `claimTreasuryOwed()`.
- **Supported tokens:** Standard ERC-20 tokens only. Rebasing, fee-on-transfer, and transfer-hook (ERC-777) tokens are unsupported and can cause accounting discrepancies or reentrancy.
- **Throughput & Parameters:** Adapter throughput is throttled at `maxPullPerCall` per `minPullInterval` (both immutable). Excess fees remain safely in the PONS escrow and are paid out in subsequent pulls. Authoritative link is registered as the escrow `recipient`; `Bound` events are for discovery and indexing only.
- **Multi-Adapter Support:** A single vault can receive yield streams from multiple adapters simultaneously (1 vault -> N adapters). Each adapter is permanently locked to its target vault once bound.
- **Dynamic Vaults:** Vaults are created permissionlessly via `LavFactory.createVault()` and are not listed in static deployment files. Enumerate them onchain via `allVaults(index)` and verify any address with `LavFactory.isVault(addr)`.

#### Protocol Fee Accounting & Split Breakdown
The protocol treasury retains 10% of gross incoming creator fees pulled by an adapter, regardless of the split configured between the vault and the project team. Because both the vault portion and the team portion are subject to the same 10% rate, the aggregate fee received by the treasury remains 10% across all allocation ratios:

$$\text{Total Fee} = 10\% \times \text{Vault Share} + 10\% \times \text{Team Share} = 10\% \times (\text{Vault Share} + \text{Team Share}) = 10\%$$

- **Example 1 (40% Vault / 60% Team Allocation):**
  - Gross creator fees pulled: 100 USDG
  - Vault portion (40 USDG): 4 USDG to protocol treasury (10%), 36 USDG streamed to active stakers (90%)
  - Team portion (60 USDG): 6 USDG to protocol treasury (10%), 54 USDG paid to team wallet (90%)
  - Total protocol fee collected: 4 + 6 = 10 USDG (10% of gross fees)

- **Example 2 (1% Vault / 99% Team Allocation — Minimum Vault Floor):**
  - Gross creator fees pulled: 100 USDG
  - Vault portion (1 USDG): 0.10 USDG to protocol treasury (10%), 0.90 USDG streamed to active stakers (90%)
  - Team portion (99 USDG): 9.90 USDG to protocol treasury (10%), 89.10 USDG paid to team wallet (90%)
  - Total protocol fee collected: 0.10 + 9.90 = 10 USDG (10% of gross fees)

- **Net Distribution Summary:** At any configured `vaultShareBps`, the protocol treasury receives 10% of gross fees, active stakers receive 90% of the vault allocation, and the project team receives 90% of the team allocation.

---

## Compiler Settings

| Setting | Value |
|---|---|
| Solidity Compiler | `v0.8.24+commit.e11b9ed9` |
| EVM Version | `shanghai` |
| Optimizer | `enabled: true`, `runs: 200` |
| Metadata | `appendCBOR: false`, `bytecodeHash: none` |

---

## License

`UNLICENSED` — All rights reserved. Source published for transparency, auditing, and verification purposes only.
`ERC6551Account.sol` is based on the reference implementation under MIT License.

## Build & Test

```bash
git clone --recursive https://github.com/lavFACTORY/lavFACTORY-protocol
cd lavFACTORY-protocol
forge build
forge test
```

### Onchain Verification

```bash
export ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com
chmod +x script/check-onchain.sh
./script/check-onchain.sh
```
