# Risks and Trust Assumptions

› ⚠️ **These contracts have not undergone an independent security audit. Use at your own risk.**

## 1. No Independent Security Audit
These contracts have undergone internal reviews, invariant tests, and formal verification sweeps, but have not been audited by an external third-party security firm.

## 2. 5% Exit Penalty
Calling `ragequit` withholds 5% of the position principal (`RAGEQUIT_BURN_BPS = 500`), rounded down in the user's favor, and burns it to `0x...dEaD`. This is an irreversible, deflationary design guarantee.

## 3. Position Account (ERC-6551) After Exit
- Calling `ragequit` deletes the position and permanently burns the receipt NFT.
- The associated ERC-6551 token-bound account permanently loses its authorized signer (`ownerOf` reverts).
- **All assets must be withdrawn from the TBA before calling `ragequit`.** Any tokens, ETH, or airdrops sent to a burned TBA remain permanently locked at that address.

## 4. Yield Stream Restarts
Any incoming yield arrival merges unstreamed tokens into a fresh 24-hour distribution window. Multiple small periodic deposits smooth payout timing but do not reduce total yield amount.

## 5. Descriptor & Metadata Authority
- The vault owner retains authority to update the SVG receipt descriptor via `setDescriptor()`.
- The descriptor is executed strictly via view-mode `tokenURI` and cannot halt or block deposits, claims, or ragequits.
- Third-party applications should read financial accounting data directly from contract state rather than unvalidated `tokenURI` metadata.

## 6. Non-Standard Tokens & Decimals
- Rebasing tokens or tokens with transfer limits/pauses can distort share accounting and are unsupported.
- Tokens with 6 decimals experience negligible entry/exit variance from `SHARE_OFFSET = 1e6`; for 18-decimal tokens the difference is micro-dust (~10⁻¹² tokens).

- **Empty-vault tax sweep:** while `totalShares == 0`, 90% of incoming staking-token tax goes to the current vault owner (or fallback to protocol treasury). An owner who is the sole staker could exit (paying the 5% ragequit burn) to route subsequent tax to themselves. Token projects integrating a vault should be aware of this when directing transfer taxes to it. Note: the `TaxSweptEarly` event emits `(projectShare, protocolFee)` without indexing the recipient address; verify recipient onchain via the ERC-20 `Transfer` event in the same transaction.
- **Frozen-stream capture:** reward yield that arrives while `totalShares == 0` is held and resumes streaming on the next deposit. Until other stakers join, the first depositor (regardless of size) accrues the full stream.

## 7. Known Edge Cases & Limitations
- **Stray staking tokens in an empty vault:** If  and the vault holds staking tokens sent directly (),  sweeps them: 90% project share goes to the owner via low-level call, falling back to the treasury Safe on failure. If neither the owner nor the treasury Safe can receive the staking token (e.g. issuer blacklist or pause),  reverts until the restriction is lifted. Dust amounts sent by any actor while empty can trigger this branch. Not applicable to standard tokens without transfer restrictions.
- **Immutable protocol treasury in adapters:**  is copied once during  and is immutable. If the treasury Safe is ever blacklisted or restricted by a token issuer,  on the adapter and  in the vault cannot be redirected to an alternate address.
- **PONS Parameter Immutability:** The vault/team ratio fixed at  assumes PONS pool fee parameters (, , ) remain immutable after pool launch.
