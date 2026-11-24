// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @title LavAdapterPnsEth: lavADAPTER v1.0.1 (PNS, native ETH)
/// @author lavFACTORY protocol author
/// @notice Variant of LavAdapterPns for PNS launches paired with native ETH. PNS reports such a launch with the
///         zero address as pair token and pays the creator fee in native ETH through the native path of its fee
///         escrow. This adapter claims the ETH, wraps it into WETH and splits the WETH exactly like LavAdapterPns
///         splits its pair token: the vault part goes to a LAV whose yield token is WETH, the team part goes to the
///         team wallet, and 10% of the team part goes to the protocol treasury. All payouts are in WETH.
///         No admin, no proxy. The team wallet can only be changed by itself, in two steps.
///
/// All rights reserved.

import {
    IERC20, PnsFeePolicy, PnsLaunch, IPnsFactory, IPnsCurve, ILavVault, ILavFactory
} from "./LavAdapterPns.sol";

/// @dev Native-ETH path of the PNS fee escrow.
interface IPnsFeeEscrowNative {
    function claim(uint256 amount) external returns (uint256);
    function balanceOf(address recipient) external view returns (uint256);
}

interface IWETH {
    function deposit() external payable;
}

/// @notice One adapter per PNS token paired with native ETH. It is the creator-fee recipient on the PNS side,
///         claims native ETH from the PNS fee escrow, wraps it into WETH, and splits the WETH between a LAV
///         (Liquid Account Vault) and a team wallet. 10% of the team part goes to the protocol treasury (read
///         from the LAV once, at binding).
///         No admin, no proxy.
contract LavAdapterPnsEth {
    /// @notice Version label: lavADAPTER v.<integration code>.<major.minor.patch>.
    string public constant VERSION = "lavADAPTER v1.0.1 (PNS, native ETH)";
    /// @notice Floor for the LAV share, in bps of trading volume (0.10%). It only rules out a dust share; any real
    ///         launch, with or without creator tax, can bind at or above it.
    uint16 public constant MIN_VAULT_SHARE_BPS = 10;
    uint256 internal constant BPS = 10_000;
    /// @notice Protocol share of the team part, in bps (10%). The LAV part is charged by the LAV itself.
    uint16 public constant PROTOCOL_SHARE_BPS = 1_000;
    /// @notice Hard lower bound of minPullInterval: 15 minutes. Makes looping pull() inside one transaction impossible.
    uint256 public constant MIN_PULL_INTERVAL_FLOOR = 900;
    /// @notice Hard upper bound of maxPullPerCall, in wei (2 ETH).
    uint256 public constant MAX_PULL_CAP_WEI = 2 ether;
    uint256 internal constant SYNC_GAS = 300_000;
    /// @notice Gas that must still be available when `sweepCurve()` reaches the curve call. Without this floor a
    ///         caller-chosen gas limit could let the curve call run out of gas while the transaction itself
    ///         succeeded with `CurveSweep(curve, false)`; `eth_estimateGas` returned exactly such a limit.
    uint256 public constant SWEEP_MIN_GAS = 400_000;

    /// @notice PNS fee escrow the creator fees are claimed from.
    IPnsFeeEscrowNative public immutable escrow;
    /// @notice PNS launch factory, source of the per-launch fee terms.
    IPnsFactory public immutable pnsFactory;
    /// @notice Canonical LavFactory; only LAVs it created are accepted.
    ILavFactory public immutable lavFactory;
    /// @notice Wrapped Ether. Every payout of this adapter is made in it; the LAV's yield token must equal it.
    address public immutable weth;
    /// @notice Address that created this adapter; the only caller of bindVault.
    address public immutable deployer;
    /// @notice Maximum ETH (in wei) processed by one pull().
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
    /// @notice Team part that could not be paid yet, in WETH.
    uint256 public teamOwed;
    /// @notice LAV part that could not be paid yet.
    uint256 public vaultOwed;
    /// @notice Protocol part that could not be paid yet.
    uint256 public treasuryOwed;
    /// @notice Timestamp of the last successful pull().
    uint256 public lastPull;
    /// @dev Reentrancy lock for pull() and the three claim functions.
    bool private locked;

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
    error Reentrancy();
    error WethNot18Decimals();
    error InsufficientGas();

    /// @param _escrow PNS fee escrow.
    /// @param _pnsFactory PNS launch factory.
    /// @param _lavFactory canonical LavFactory.
    /// @param _weth Wrapped Ether (18 decimals). ETH claimed from PNS is wrapped into it.
    /// @param _maxPullPerCall cap of one pull(), in wei (for example 0.02 ether).
    /// @param _minPullInterval pause between pulls in seconds (for example 3600).
    constructor(
        address _escrow,
        address _pnsFactory,
        address _lavFactory,
        address _weth,
        uint256 _maxPullPerCall,
        uint256 _minPullInterval
    ) {
        if (_escrow == address(0) || _pnsFactory == address(0) || _lavFactory == address(0) || _weth == address(0)) {
            revert ZeroAddress();
        }
        require(_weth.code.length > 0, "WETH not a contract");
        if (IERC20(_weth).decimals() != 18) revert WethNot18Decimals();
        require(_maxPullPerCall > 0, "Zero cap");
        if (_minPullInterval < MIN_PULL_INTERVAL_FLOOR) revert IntervalTooShort();
        if (_maxPullPerCall > MAX_PULL_CAP_WEI) revert CapTooHigh();
        escrow = IPnsFeeEscrowNative(_escrow);
        pnsFactory = IPnsFactory(_pnsFactory);
        lavFactory = ILavFactory(_lavFactory);
        weth = _weth;
        maxPullPerCall = _maxPullPerCall;
        minPullInterval = _minPullInterval;
        deployer = msg.sender;
    }

    /// @notice One-time binding to a LAV and to the PNS terms of one token.
    /// @dev Only the deployer. Reads the fee terms PNS froze for `token`.
    /// @param _vault LAV created by the canonical LavFactory for `token` with WETH as yield token.
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
        if (v.stakingToken() != token || v.yieldToken() != weth) revert WrongVaultTokens();
        address treasury_ = v.protocolTreasury();
        if (treasury_ == address(0)) revert ZeroAddress();

        PnsLaunch memory l = pnsFactory.getLaunchedToken(token);
        // PNS reports a native ETH launch with the zero address as pair token.
        if (!l.exists || l.pairToken != address(0)) revert NotLaunched();
        // With buyback on, part of the creator base share is spent on a buyback, not paid in ETH.
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

    /// @notice Accepts native ETH: the PNS escrow pays claims here, and anyone may send ETH to be split.
    /// @dev No logic on purpose, so a payment can never fail or re-enter.
    receive() external payable {}

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    /// @notice Public. Claims native ETH from the PNS escrow (at most maxPullPerCall, at most once per
    ///         minPullInterval), adds ETH and WETH sent to this adapter directly, wraps the ETH and splits the total.
    /// @dev Never reverts on a failed payout: the failed part goes to vaultOwed, teamOwed or treasuryOwed and is never
    ///      split again. The ETH actually received from the escrow is measured. Returns 0 without effect before
    ///      binding or inside the pause.
    /// @return total wei split by this call (paid out as WETH).
    function pull() external nonReentrant returns (uint256 total) {
        if (!bound) return 0;
        if (block.timestamp < lastPull + minPullInterval) return 0;

        // ETH and WETH on the adapter count together: every wei here is either owed or waiting to be split.
        uint256 bal = IERC20(weth).balanceOf(address(this)) + address(this).balance;
        uint256 owed = teamOwed + vaultOwed + treasuryOwed;
        uint256 local = bal > owed ? bal - owed : 0;
        uint256 want = local + escrow.balanceOf(address(this));
        // One cap for every source: escrow claim and funds already on the adapter together never exceed
        // maxPullPerCall in one call. Whatever is above waits on the adapter for the next interval.
        uint256 target = want > maxPullPerCall ? maxPullPerCall : want;
        if (target == 0) return 0;
        lastPull = block.timestamp;

        uint256 fromLocal = local > target ? target : local;
        uint256 received;
        if (target > fromLocal) {
            uint256 before = address(this).balance;
            escrow.claim(target - fromLocal);
            received = address(this).balance - before;
        }
        total = fromLocal + received;
        // If the escrow ever pays more than asked, the surplus stays on the adapter for the next interval.
        if (total > target) total = target;
        if (total == 0) return 0;

        // Wrap every wei of native ETH held; from here on the adapter works in WETH only.
        uint256 native = address(this).balance;
        if (native > 0) IWETH(weth).deposit{value: native}();

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

    /// @dev Low-level WETH transfer that reports failure instead of reverting.
    function _tryTransfer(address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory d) = weth.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
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
    function claimVaultOwed() external nonReentrant {
        uint256 a = vaultOwed;
        if (a == 0) return;
        vaultOwed = 0;
        if (!_tryTransfer(vault, a)) revert TransferFailed();
        try ILavVault(vault).syncYield{gas: SYNC_GAS}() {} catch {}
        emit VaultOwedPaid(a);
    }

    /// @notice Public. Retries a team payout that failed earlier.
    function claimTeamOwed() external nonReentrant {
        uint256 a = teamOwed;
        if (a == 0) return;
        teamOwed = 0;
        if (!_tryTransfer(teamWallet, a)) revert TransferFailed();
        emit TeamOwedPaid(a);
    }

    /// @notice Public. Retries a protocol payout that failed earlier.
    function claimTreasuryOwed() external nonReentrant {
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
