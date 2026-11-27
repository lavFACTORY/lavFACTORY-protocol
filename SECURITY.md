# Security Policy

## Audit Status
The contracts **have not undergone an independent security audit**. An internal review covered yield streaming, zero-share pausing, update ordering, exit penalty, owner permissions, ERC-6551 implementation, and on-chain matching. An internal review is not a substitute for an audit. Use at your own risk.

## Scope (Robinhood Chain, chainId 4663)
- `LavFactory`: `0x262d4d478eFe72Eb1731310a4f7A252644aA4B5F`
- `LiquidAccountVault` (All vaults deployed via `LavFactory`)
- `ERC6551Account`: `0xC55D74fba44eb126ef5F6FbCcb93e443d4f40902`
- `lavADAPTER` / `lavADAPTER ETH` (Standalone fee routing adapters deployed per-project via launch interface)
- `LavDescriptor` (Modular on-chain SVG and metadata renderers bound to vaults)

## Trust Model & Roles

| Role | Permissions & Constraints |
|---|---|
| **LavFactory** | Autonomous. No owner, no admin, no pause. All addresses immutable. |
| **Protocol Treasury** | Safe (2/3 Multisig: `0xeDbc...a4f1`). Receives creation fees and protocol splits. No operational contract control. |
| **Vault Owner** | Scoped strictly to `setDescriptor` (visual SVG card). Zero access to user principal or reward streams. |
| **ERC-6551 Implementation** | Reference implementation. Non-upgradeable, no admin keys. Authorized signer strictly determined by NFT ownership. |
| **lavADAPTER** | Immutable fee router. Binds once to vault, token, and split share at deployment. Zero upgradeability, no pause, no admin drain. |
| **LavDescriptor** | Read-only visual & metadata renderer. Stateless, immutable, zero access to vault funds or accounting. Queried strictly in view mode via `tokenURI`. |

## Design Properties
- **No Governance Pause:** Vaults operate autonomously and cannot be halted by administrators.
- **Unconditional Exit:** `ragequit` is permanently available to stakers.
- **Gas-Metered External Calls:** Balance checks (`TOKEN_VIEW_GAS = 100_000`) and transfers (`TOKEN_XFER_GAS = 500_000`) are strictly gas-limited with bounded return data copying to prevent griefing attacks.
- **Descriptor Isolation:** Descriptor contracts are queried strictly in view mode via `tokenURI` and cannot alter vault state or revert core operations.
- **Adapter Pull Rate Limiting:** Cooldown periods and fixed per-call extraction limits protect fee escrows from drain anomalies.

## Vulnerability Reporting
Please report vulnerabilities privately:
- **Email:** security@lavfactory.org
- **Expected initial response:** 24–48 hours
- Please do not disclose vulnerabilities publicly until patched or mitigated.
