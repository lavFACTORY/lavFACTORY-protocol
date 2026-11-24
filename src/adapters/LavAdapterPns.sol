// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @title LavAdapterPns: lavADAPTER v1.0.1 (PNS)
/// @author lavFACTORY protocol author
/// @notice One adapter per PNS token. Receives the creator fee stream from the PNS fee escrow,
///         routes the creator tax directly to the lavNFT vault, and splits the base creator fee
///         (90% to team wallet, 10% to the protocol treasury).
///         No admin, no proxy. The team wallet can only be changed by itself, in two steps.
///
/// All rights reserved.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IPnsFeeEscrow {
    function claimToken(address token, uint256 amount) external returns (uint256);
    function balanceOfToken(address recipient, address token) external view returns (uint256);
}

struct PnsFeePolicy {
    address protocolFeeRecipient;
    uint16 protocolFeeShareBps;
    uint16 buybackBurnBps;
    uint16 hookFeeBps;
    uint16 maxInternalPriceImpactBps;
}

struct PnsLaunch {
    address token;
    address curve;
    address deployer;
    address creatorFeeRecipient;
    address pairToken;
    uint256 graduationThreshold;
    uint24 poolFee;
    int24 tickSpacing;
    uint16 creatorTaxBps;
    bool buybackEnabled;
    uint8 phase;
    uint256 sweptQuote;
    uint256 sweptTokens;
    uint256 sweptAt;
    bool exists;
}

interface IPnsFactory {
    function getLaunchedToken(address token) external view returns (PnsLaunch memory);
    function getLaunchFeePolicy(address token) external view returns (PnsFeePolicy memory);
}

interface IPnsCurve {
    function feeBps() external view returns (uint256);
    function graduated() external view returns (bool);
    function sweepFees(uint256 minBuybackTokensOut) external;
}

interface ILavVault {
    function stakingToken() external view returns (address);
    function yieldToken() external view returns (address);
    function protocolTreasury() external view returns (address);
    function syncYield() external;
}

interface ILavFactory {
    function isVault(address) external view returns (bool);
}

/// @notice One adapter per PNS token. It is the creator-fee recipient on the PNS side, claims USDG from the
///         PNS fee escrow, and splits it between a LAV (Liquid Account Vault) and a team wallet. 10% of the team
///         part goes to the protocol treasury (read from the LAV once, at binding).
///         No admin, no proxy.
contract LavAdapterPns {
    /// @notice Version label: lavADAPTER v.<integration code>.<major.minor.patch>.
    string public constant VERSION = "lavADAPTER v1.0.1 (PNS)";
    /// @notice Floor for the LAV share, in bps of trading volume (0.10%). It only rules out a dust share; any real
    ///         launch, with or without creator tax, can bind at or above it.
    uint16 public constant MIN_VAULT_SHARE_BPS = 10;
    uint256 internal constant BPS = 10_000;
    /// @notice Protocol share of the team part, in bps (10%). The LAV part is charged by the LAV itself.
    uint16 public constant PROTOCOL_SHARE_BPS = 1_000;
    /// @notice Hard lower bound of minPullInterval: 15 minutes. Makes looping pull() inside one transaction impossible.
    uint256 public constant MIN_PULL_INTERVAL_FLOOR = 900;
    /// @notice Hard upper bound of maxPullPerCall, in whole quote-token units (5,000 USDG).
    uint256 public constant MAX_PULL_CAP_WHOLE = 5_000;
    uint256 internal constant SYNC_GAS = 300_000;
    /// @notice Gas that must still be available when `sweepCurve()` reaches the curve call. Without this floor a
    ///         caller-chosen gas limit could let the curve call run out of gas while the transaction itself
    ///         succeeded with `CurveSweep(curve, false)`; `eth_estimateGas` returned exactly such a limit.
    uint256 public constant SWEEP_MIN_GAS = 400_000;

    /// @notice PNS fee escrow the creator fees are claimed from.
    IPnsFeeEscrow public immutable escrow;
    /// @notice PNS launch factory, source of the per-launch fee terms.
    IPnsFactory public immutable pnsFactory;
    /// @notice Canonical LavFactory; only LAVs it created are accepted.
    ILavFactory public immutable lavFactory;
    /// @notice Quote token paid by PNS (USDG).
    address public immutable usdg;
    /// @notice Address that created this adapter; the only caller of bindVault.
    address public immutable deployer;
    /// @notice Maximum USDG processed by one pull().
    uint256 public immutable maxPullPerCall;
    /// @notice Minimum seconds between two successful pull() calls.
    uint256 public immutable minPullInterval;

    /// @notice PNS token this adapter serves (set once by bindVault).
    address public pnsToken;
    /// @notice LAV that receives the vault part (set once by bindVault).
    address public vault;
    /// @notice LAV share in bps of trading volume.
    uint16 public vaultBps;
    /// @notice Team share in bps of trading volume (everything else the creator receives).
    uint16 public teamBps;
    /// @notice True once bindVault succeeded.
    bool public bound;
    /// @notice Protocol treasury that receives 10% of the team part (copied from the LAV at binding).
    address public protocolTreasury;

    /// @notice Current team wallet (should be a Safe).
    address public teamWallet;
    /// @notice Proposed new team wallet, waiting for acceptTeamWallet().
    address public pendingTeamWallet;
    /// @notice Team part that could not be paid yet (for example USDG blocklist).
    uint256 public teamOwed;
    /// @notice LAV part that could not be paid yet.
    uint256 public vaultOwed;
    /// @notice Protocol part that could not be paid yet.
    uint256 public treasuryOwed;
    /// @notice Timestamp of the last successful pull().
    uint256 public lastPull;

    event Bound(address indexed vault, address indexed token, uint16 vaultBps, uint16 teamBps);
    event Pulled(uint256 total, uint256 toVault, uint256 toTeam, uint256 toTreasury);
    event VaultOwedAccrued(uint256 amount);
    event TeamOwedAccrued(uint256 amount);
    event VaultOwedPaid(uint256 amount);
    event TeamOwedPaid(uint256 amount);
    event TreasuryOwedAccrued(uint256 amount);
    event TreasuryOwedPaid(uint256 amount);
    event CurveSweep(address indexed curve, bool ok);
    event TeamWalletProposed(address indexed proposed);
    event TeamWalletChanged(address indexed newWallet);

    error NotDeployer();
    error AlreadyBound();
    error NotVault();
    error WrongVaultTokens();
    error NotLaunched();
    error BuybackNotSupported();
    error NotTeam();
    error NotPending();
    error ZeroAddress();
    error FeeBpsMismatch();
    error VaultShareBelowFloor();
    error VaultShareExceedsTotal();
    error InvalidTotalBps();
    error IntervalTooShort();
    error CapTooHigh();
    error TransferFailed();
    error InsufficientGas();

    /// @param _escrow PNS fee escrow.
    /// @param _pnsFactory PNS launch factory.
    /// @param _lavFactory canonical LavFactory.
    /// @param _usdg quote token of the PNS launch.
    /// @param _maxPullPerCall cap of one pull(), in USDG units (for example 50e6).
    /// @param _minPullInterval pause between pulls in seconds (for example 3600).
    constructor(
        address _escrow,
        address _pnsFactory,
        address _lavFactory,
        address _usdg,
        uint256 _maxPullPerCall,
        uint256 _minPullInterval
    ) {
        if (_escrow == address(0) || _pnsFactory == address(0) || _lavFactory == address(0) || _usdg == address(0)) {
            revert ZeroAddress();
        }
        require(_usdg.code.length > 0, "USDG not a contract");
        require(_maxPullPerCall > 0, "Zero cap");
        if (_minPullInterval < MIN_PULL_INTERVAL_FLOOR) revert IntervalTooShort();
        // bound is expressed in whole units of the quote token, so it is 5,000_000_000 for a 6-decimals USDG
        if (_maxPullPerCall > MAX_PULL_CAP_WHOLE * (10 ** uint256(IERC20(_usdg).decimals()))) revert CapTooHigh();
        escrow = IPnsFeeEscrow(_escrow);
        pnsFactory = IPnsFactory(_pnsFactory);
        lavFactory = ILavFactory(_lavFactory);
        usdg = _usdg;
        maxPullPerCall = _maxPullPerCall;
        minPullInterval = _minPullInterval;
        deployer = msg.sender;
    }

    /// @notice One-time binding to a LAV and to the PNS terms of one token.
    /// @dev Only the deployer. Reads the fee terms PNS froze for `token`.
    /// @param _vault LAV created by the canonical LavFactory for `token` with USDG as yield token.
    /// @dev Vault authenticity (isVault on the configured LavFactory) is validated once, at binding time.
    /// @param token the PNS token.
    /// @param _teamWallet receiver of the team part.
    /// @param vaultShareBps_ LAV share in bps of volume, at least MIN_VAULT_SHARE_BPS and at most everything the
    ///        creator receives (base share after the PNS cut, plus creator tax).
    function bindVault(address _vault, address token, address _teamWallet, uint16 vaultShareBps_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (bound) revert AlreadyBound();
        if (_teamWallet == address(0)) revert ZeroAddress();
        if (!lavFactory.isVault(_vault)) revert NotVault();
        ILavVault v = ILavVault(_vault);
        if (v.stakingToken() != token || v.yieldToken() != usdg) revert WrongVaultTokens();
        address treasury_ = v.protocolTreasury();
        if (treasury_ == address(0)) revert ZeroAddress();

        PnsLaunch memory l = pnsFactory.getLaunchedToken(token);
        if (!l.exists || l.pairToken != usdg) revert NotLaunched();
        // With buyback on, part of the creator base share is spent on a buyback, not paid in USDG.
        if (l.buybackEnabled) revert BuybackNotSupported();
        PnsFeePolicy memory p = pnsFactory.getLaunchFeePolicy(token);
        // While the token is still on the bonding curve, the curve charges its own feeBps.
        // Require it to equal the hook fee, otherwise the split ratio would be wrong in one of the two phases.
        if (l.curve != address(0) && !IPnsCurve(l.curve).graduated()) {
            if (IPnsCurve(l.curve).feeBps() != p.hookFeeBps) revert FeeBpsMismatch();
        }

        uint256 base = (uint256(p.hookFeeBps) * (BPS - p.protocolFeeShareBps)) / BPS;
        // everything the creator receives from PNS, in bps of trading volume (base share plus creator tax)
        uint256 totalCreatorBps = base + l.creatorTaxBps;
        if (totalCreatorBps > BPS) revert InvalidTotalBps(); // keeps teamBps inside uint16 and inside 100%
        if (vaultShareBps_ < MIN_VAULT_SHARE_BPS) revert VaultShareBelowFloor();
        if (vaultShareBps_ > totalCreatorBps) revert VaultShareExceedsTotal();
        // the vault gets exactly vaultShareBps_ of volume; the remainder goes to the team
        uint256 team = totalCreatorBps - vaultShareBps_;

        bound = true;
        vault = _vault;
        pnsToken = token;
        teamWallet = _teamWallet;
        protocolTreasury = treasury_;
        vaultBps = vaultShareBps_;
        teamBps = uint16(team);
        emit Bound(_vault, token, vaultShareBps_, uint16(team));
    }

    /// @notice Public. Claims USDG from the PNS escrow (at most maxPullPerCall, at most once per
    ///         minPullInterval), adds USDG sent to this adapter directly, and splits the total.
    /// @dev Never reverts on a failed payout: the failed part goes to vaultOwed, teamOwed or treasuryOwed and is never
    ///      split again. The amount actually received from the escrow is measured, so a quote token that
    ///      charges a transfer fee cannot break the accounting. Returns 0 without effect before binding or
    ///      inside the pause.
    /// @return total USDG split by this call.
    function pull() external returns (uint256 total) {
        if (!bound) return 0;
        if (block.timestamp < lastPull + minPullInterval) return 0;

        uint256 bal = IERC20(usdg).balanceOf(address(this));
        uint256 owed = teamOwed + vaultOwed + treasuryOwed;
        uint256 local = bal > owed ? bal - owed : 0;
        uint256 want = local + escrow.balanceOfToken(address(this), usdg);
        // One cap for every source: escrow claim and USDG already on the adapter together never exceed
        // maxPullPerCall in one call. Whatever is above waits on the adapter for the next interval.
        uint256 target = want > maxPullPerCall ? maxPullPerCall : want;
        if (target == 0) return 0;
        lastPull = block.timestamp;

        uint256 fromLocal = local > target ? target : local;
        uint256 received;
        if (target > fromLocal) {
            uint256 before = IERC20(usdg).balanceOf(address(this));
            escrow.claimToken(usdg, target - fromLocal);
            received = IERC20(usdg).balanceOf(address(this)) - before;
        }
        total = fromLocal + received;
        if (total == 0) return 0;

        uint256 toVault = (total * vaultBps) / (uint256(vaultBps) + teamBps);
        uint256 teamPart = total - toVault; // remainder rule: rounding dust stays in the team part
        uint256 toTreasury = (teamPart * PROTOCOL_SHARE_BPS) / BPS; // 10% of the team part, rounded down
        uint256 toTeam = teamPart - toTreasury; // rounding dust goes to the team

        if (toVault > 0) {
            if (_tryTransfer(vault, toVault)) {
                try ILavVault(vault).syncYield{gas: SYNC_GAS}() {} catch {}
            } else {
                vaultOwed += toVault; // kept on the adapter, never re-split
                emit VaultOwedAccrued(toVault);
            }
        }
        if (toTeam > 0 && !_tryTransfer(teamWallet, toTeam)) {
            teamOwed += toTeam;
            emit TeamOwedAccrued(toTeam);
        }
        if (toTreasury > 0 && !_tryTransfer(protocolTreasury, toTreasury)) {
            treasuryOwed += toTreasury;
            emit TreasuryOwedAccrued(toTreasury);
        }
        emit Pulled(total, toVault, toTeam, toTreasury);
    }

    /// @dev Low-level USDG transfer that reports failure instead of reverting.
    function _tryTransfer(address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory d) = usdg.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        return ok && (d.length == 0 || abi.decode(d, (bool)));
    }

    /// @notice Public. Pushes accrued fees out of the bonding curve into the PNS escrow.
    /// @dev Works because, after the recipient change, this adapter is the curve's creator and PNS lets the
    ///      creator sweep when no buyback is pending (buyback is disabled for bound tokens).
    ///      Returns false instead of reverting (curve graduated, nothing to sweep, interface change).
    ///      Reverts with `InsufficientGas` if less than `SWEEP_MIN_GAS` is left for the curve call, so a sweep
    ///      can never fail silently for lack of gas.
    /// @return ok true if the curve accepted the sweep.
    function sweepCurve() external returns (bool ok) {
        if (!bound) return false;
        address curve = pnsFactory.getLaunchedToken(pnsToken).curve;
        if (curve == address(0)) return false;
        if (gasleft() < SWEEP_MIN_GAS) revert InsufficientGas();
        try IPnsCurve(curve).sweepFees(0) {
            ok = true;
        } catch {
            ok = false;
        }
        emit CurveSweep(curve, ok);
    }

    /// @notice Public. Retries a vault payout that failed earlier.
    function claimVaultOwed() external {
        uint256 a = vaultOwed;
        if (a == 0) return;
        vaultOwed = 0;
        if (!_tryTransfer(vault, a)) revert TransferFailed();
        try ILavVault(vault).syncYield{gas: SYNC_GAS}() {} catch {}
        emit VaultOwedPaid(a);
    }

    /// @notice Public. Retries a team payout that failed earlier (for example USDG blocklist).
    function claimTeamOwed() external {
        uint256 a = teamOwed;
        if (a == 0) return;
        teamOwed = 0;
        if (!_tryTransfer(teamWallet, a)) revert TransferFailed();
        emit TeamOwedPaid(a);
    }

    /// @notice Public. Retries a protocol payout that failed earlier.
    function claimTreasuryOwed() external {
        uint256 a = treasuryOwed;
        if (a == 0) return;
        treasuryOwed = 0;
        if (!_tryTransfer(protocolTreasury, a)) revert TransferFailed();
        emit TreasuryOwedPaid(a);
    }

    /// @notice Step one of a team wallet change. Only the current team wallet.
    /// @param next proposed new team wallet.
    function transferTeamWallet(address next) external {
        if (msg.sender != teamWallet) revert NotTeam();
        if (next == address(0)) revert ZeroAddress();
        pendingTeamWallet = next;
        emit TeamWalletProposed(next);
    }

    /// @notice Step two: the proposed wallet accepts.
    function acceptTeamWallet() external {
        if (msg.sender != pendingTeamWallet) revert NotPending();
        teamWallet = msg.sender;
        pendingTeamWallet = address(0);
        emit TeamWalletChanged(msg.sender);
    }
}
