# Architecture Specification

## Overview Diagram

```
Ecosystem Revenue / Adapters
              │
              │ Yield distribution (transfer + syncYield)
              ▼
    LiquidAccountVault (lavNFT) ◄── Deposits (ERC-20 Project Token)
       ├── Engine 1: Instant Body Growth (10% Treasury Safe / 90% Stakers)
       ├── Engine 2: 24h Yield Stream (10% Treasury Safe / 90% Stakers)
       ├── ERC-721 Receipt Positions + Deterministic TBA (ERC-6551)
       └── Exit: 95/5 Ragequit -> up to 5% burned to 0x...dEaD
```

## Core Protocol Contracts

1. **`LavFactory` (`0x262d4d478eFe72Eb1731310a4f7A252644aA4B5F`):**
   - Permissionless multi-vault deployment factory.
   - Fixed `CREATION_FEE = 0.002 ETH` forwarded directly to `protocolTreasury`.
   - Immutable protocol parameters: `protocolTreasury`, `erc6551Registry`, `erc6551Implementation`.
   - Zero owner, zero admin, zero pause mechanism.

2. **`LiquidAccountVault`:**
   - Monolithic sovereign vault managing share accounting and dual-engine tokenomics.
   - **Engine 1 (Body Growth):** Direct transfers or taxes increase `totalBody` (10% treasury, 90% stakers). Credited instantly.
   - **Engine 2 (Yield Streaming):** Reward tokens streamed evenly over 24 hours (`STREAM_DURATION = 86400`).
   - Pauses stream timer automatically when `totalShares == 0` without loss of yield.
   - **95/5 Ragequit:** Returns at least 95% of principal, up to 5% burned to `0x...dEaD`.

3. **`ERC6551Account` (`0xC55D74fba44eb126ef5F6FbCcb93e443d4f40902`):**
   - Canonical implementation adhering strictly to EIP-6551 specification.
   - Operations restricted to `CALL` (`operation == 0`).
   - Signer validity strictly tied to `IERC721(vault).ownerOf(tokenId)`.
