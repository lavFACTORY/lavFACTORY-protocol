# On-Chain Verification

## Verified Contracts (Robinhood Chain, chainId 4663)

| Contract | Address | Verification Status | Notes |
|---|---|---|---|
| `LavFactory` | `0x262d4d478eFe72Eb1731310a4f7A252644aA4B5F` | Verified (partial match) | Multi-vault factory |
| `ERC6551Registry` | `0x000000006551c19487814612e58FE06813775758` | Canonical singleton | Official EIP-6551 registry |
| `ERC6551Account` implementation | `0xC55D74fba44eb126ef5F6FbCcb93e443d4f40902` | Verified (partial match) | Non-upgradeable reference account |

**Why "partial match":** With compiler settings `appendCBOR: false` and `bytecodeHash: none`, no metadata hash is appended to the contract bytecode. Explorers flag this as partial match because there is no metadata hash to match, but executable bytecodes match 1:1.

## Compiler Settings

| Setting | Value |
|---|---|
| solc | `0.8.24+commit.e11b9ed9` |
| EVM version | `shanghai` |
| Optimizer | enabled, 200 runs |
| `metadata.bytecodeHash` | `none` |
| `metadata.appendCBOR` | `false` |

## On-Chain Verification Commands

```bash
RPC=https://rpc.mainnet.chain.robinhood.com
F=0x262d4d478eFe72Eb1731310a4f7A252644aA4B5F

# 1. Factory constants
cast call $F "protocolTreasury()(address)"  --rpc-url $RPC # 0xeDbc87E40491b9edF65940acF63A5c0E81d8a4f1
cast call $F "CREATION_FEE()(uint256)"      --rpc-url $RPC # 2000000000000000 (0.002 ETH)
cast call $F "erc6551Registry()(address)"   --rpc-url $RPC # 0x000000006551c19487814612e58FE06813775758
cast call $F "erc6551Implementation()(address)" --rpc-url $RPC # 0xC55D74fba44eb126ef5F6FbCcb93e443d4f40902
```
