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
- 10% is routed to the protocol treasury Safe, and 90% is credited instantly to stakers pro rata.

#### Engine 2: Yield Streaming (Reward Token)
- Incoming revenue (e.g. trading fees via ecosystem adapters or direct protocol yield) is streamed to active stakers:
  - 10% protocol fee to the protocol treasury Safe.
  - 90% distributed evenly over a continuous 24-hour stream (`STREAM_DURATION = 86400`).
- Any new yield arrival merges with unstreamed tokens (`remaining`) and initiates a fresh 24-hour linear release window.
- **Empty Vault Protection:** If all positions exit (`totalShares == 0`), the stream timer pauses automatically (`periodFinish` shifts forward). When a new deposit arrives, the stream resumes without any loss of reward funds.
- The vault owner receives no special yield allocation and cannot withdraw unstreamed staker funds.

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

#### 6. Vault Ownership & Descriptors
- The vault creator retains the role of vault owner with strictly scoped permissions:
  - Can only update the visual/metadata card descriptor (`setDescriptor`).
  - Cannot access user deposits, adjust fee parameters, or withdraw yield.
  - The descriptor is executed exclusively via read-only `tokenURI` calls and cannot interrupt deposits, claims, or ragequits.

---

## Ecosystem Modules & Adapters

Ecosystem adapters can route liquidity pool creator fees and external revenue into individual vaults:
- **`LavAdapterPns`:** Collects creator trading fees from PNS liquidity pair fee escrows and routes them into the corresponding vault.
- Features immutable execution, permissionless `pull()` calls with interval and rate throttles, and non-blocking failure recovery (`claim*Owed`).

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
