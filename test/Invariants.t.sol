// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LiquidAccountVault} from "../src/LiquidAccountVault.sol";
import {MockERC20, BlockERC20, MockRegistry} from "./Mocks.sol";

address constant DEAD = 0x000000000000000000000000000000000000dEaD;

/// Shared deployment: 18-dec staking token, 6-dec yield token (USDC-like).
abstract contract VaultBase is Test {
    MockERC20 internal stake;
    MockERC20 internal usdc;
    LiquidAccountVault internal v;
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    uint256 internal constant YIELD_FEE_BPS = 1_000; // YIELD_PROTOCOL_FEE_BPS in the v1.0.0 source (10%)

    function _deploy(MockERC20 st, MockERC20 yt) internal returns (LiquidAccountVault) {
        return new LiquidAccountVault(
            address(st), address(yt), "Vault", "LAV", creator, treasury, address(new MockRegistry()), address(0xBEEF)
        );
    }

    function _setUpBase() internal {
        stake = new MockERC20("Stake", "STK", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        v = _deploy(stake, usdc);
    }

    function _dep(address who, uint256 amt) internal returns (uint256 id) {
        stake.mint(who, amt);
        vm.startPrank(who);
        stake.approve(address(v), amt);
        id = v.deposit(amt);
        vm.stopPrank();
    }

    function _tax(uint256 amt) internal {
        stake.mint(address(v), amt);
        v.notifyTaxBody();
    }

    function _yield(uint256 amt) internal {
        usdc.mint(address(v), amt);
        v.syncYield();
    }

    function _near(uint256 a, uint256 b, uint256 tol, string memory m) internal pure {
        uint256 d = a > b ? a - b : b - a;
        require(d <= tol, m);
    }
}

// ════════════════════════════════════════════════════════════════════════
// Stateful handler: random sequences of user actions + ghost accounting
// ════════════════════════════════════════════════════════════════════════
contract Handler is Test {
    LiquidAccountVault public v;
    MockERC20 public stake;
    MockERC20 public usdc;
    address public treasury;
    address public creator;
    address public keeper = address(0xCAFE);
    address[4] public actors;
    uint256[] public ids;

    // stake-token ghosts
    uint256 public gStakeIn; // deposits (received) + tax donated
    uint256 public gBodyPaid; // ragequit body payouts
    uint256 public gBurned;
    // yield-token ghosts
    uint256 public gYieldMinted;
    uint256 public gYieldPaid; // paid to users (claim + ragequit)
    uint256 public gYieldTreasury; // expected treasury balance
    uint256 public gYieldCreator; // expected creator balance (early sweeps)
    uint256 public gUnsynced; // sent to the vault but not yet synced
    uint256 public gEvents; // rounding-dust budget: distributions + claims + exits
    uint256 public gRagequits;
    bool public mathBroken;

    constructor(LiquidAccountVault _v, MockERC20 _s, MockERC20 _y, address _t, address _c) {
        v = _v; stake = _s; usdc = _y; treasury = _t; creator = _c;
        for (uint256 i; i < 4; i++) actors[i] = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
    }

    // ----- helpers -----
    function idsLength() external view returns (uint256) { return ids.length; }

    function live(uint256 id) public view returns (bool) {
        try v.ownerOf(id) returns (address) { return true; } catch { return false; }
    }

    function _pick(uint256 seed) internal view returns (uint256) {
        uint256 n = ids.length;
        if (n == 0) return 0;
        for (uint256 i; i < n; i++) {
            uint256 id = ids[(seed + i) % n];
            if (live(id)) return id;
        }
        return 0;
    }

    /// Mirror what the vault does at the start of every state-changing call:
    /// classify unsynced yield by totalShares at that moment, then sync.
    function _sync() internal {
        uint256 u = gUnsynced;
        if (u > 0) {
            gUnsynced = 0;
            uint256 fee = (u * 1_000) / 10_000;
            gYieldTreasury += fee;
            if (v.totalShares() == 0) gYieldCreator += u - fee; // swept to owner (== creator)
            gEvents++;
        }
        v.syncYield();
    }

    // ----- actions -----
    function deposit(uint256 seed, uint256 amt) external {
        amt = bound(amt, 1, 1e24);
        address a = actors[seed % 4];
        _sync();
        stake.mint(a, amt);
        vm.startPrank(a);
        stake.approve(address(v), amt);
        try v.deposit(amt) returns (uint256 id) {
            ids.push(id);
            gStakeIn += amt;
        } catch {
            // e.g. "Zero shares minted" for dust deposits into a high-value share: tokens stay with the actor
        }
        vm.stopPrank();
    }

    function tax(uint256 amt) external {
        amt = bound(amt, 0, 1e23);
        _sync();
        stake.mint(address(v), amt);
        gStakeIn += amt;
        v.notifyTaxBody();
    }

    function taxViaReceive(uint256 amt) external {
        amt = bound(amt, 1, 1e23);
        _sync();
        stake.mint(keeper, amt);
        gStakeIn += amt;
        vm.startPrank(keeper);
        stake.approve(address(v), amt);
        v.receiveTaxBody(amt);
        vm.stopPrank();
    }

    function directYield(uint256 amt, bool doSync) external {
        amt = bound(amt, 0, 1e12);
        usdc.mint(address(v), amt);
        gYieldMinted += amt;
        gUnsynced += amt;
        if (doSync) _sync();
    }

    function distribute(uint256 amt) external {
        if (v.totalShares() == 0) return;
        amt = bound(amt, 1, 1e12);
        _sync();
        usdc.mint(keeper, amt);
        gYieldMinted += amt;
        vm.startPrank(keeper);
        usdc.approve(address(v), amt);
        v.distributeYield(amt);
        vm.stopPrank();
        gYieldTreasury += (amt * 1_000) / 10_000;
        gEvents++;
    }

    function claim(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == 0) return;
        _sync();
        vm.prank(v.ownerOf(id));
        gYieldPaid += v.claimYield(id);
        gEvents++;
    }

    function ragequit(uint256 seed) external {
        uint256 id = _pick(seed);
        if (id == 0) return;
        _sync();
        address o = v.ownerOf(id);
        (uint256 shares,,,,) = v.positionOf(id);
        uint256 gross = (shares * v.totalBody()) / v.totalShares();
        uint256 burnBefore = stake.balanceOf(DEAD);
        uint256 ownerBefore = stake.balanceOf(o);
        vm.prank(o);
        (uint256 bodyPayout, uint256 yieldPayout) = v.ragequit(id);
        uint256 burned = stake.balanceOf(DEAD) - burnBefore;
        // 95/5 with burn, exact: burn = floor(gross * 5%), payout = gross - burn
        if (burned != (gross * 500) / 10_000) mathBroken = true;
        if (bodyPayout + burned != gross) mathBroken = true;
        if (stake.balanceOf(o) - ownerBefore != bodyPayout) mathBroken = true;
        gBodyPaid += bodyPayout;
        gBurned += burned;
        gYieldPaid += yieldPayout;
        gEvents++;
        gRagequits++;
    }

    function transferNft(uint256 seed, uint256 toSeed) external {
        uint256 id = _pick(seed);
        if (id == 0) return;
        address o = v.ownerOf(id);
        address to = actors[toSeed % 4];
        if (to == o) return;
        vm.prank(o);
        v.transferFrom(o, to, id);
    }

    /// Everybody leaves: after this the vault must be (almost) empty.
    function exitAll() external {
        uint256 n = ids.length;
        for (uint256 i; i < n; i++) {
            uint256 id = ids[i];
            if (!live(id)) continue;
            _sync();
            address o = v.ownerOf(id);
            (uint256 shares,,,,) = v.positionOf(id);
            uint256 gross = (shares * v.totalBody()) / v.totalShares();
            uint256 burnBefore = stake.balanceOf(DEAD);
            vm.prank(o);
            (uint256 bodyPayout, uint256 yieldPayout) = v.ragequit(id);
            uint256 burned = stake.balanceOf(DEAD) - burnBefore;
            if (burned != (gross * 500) / 10_000 || bodyPayout + burned != gross) mathBroken = true;
            gBodyPaid += bodyPayout;
            gBurned += burned;
            gYieldPaid += yieldPayout;
            gEvents++;
            gRagequits++;
        }
    }
}

contract VaultInvariants is VaultBase {
    Handler internal h;

    function setUp() public {
        _setUpBase();
        h = new Handler(v, stake, usdc, treasury, creator);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](9);
        sel[0] = h.deposit.selector;
        sel[1] = h.tax.selector;
        sel[2] = h.taxViaReceive.selector;
        sel[3] = h.directYield.selector;
        sel[4] = h.distribute.selector;
        sel[5] = h.claim.selector;
        sel[6] = h.ragequit.selector;
        sel[7] = h.transferNft.selector;
        sel[8] = h.exitAll.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    function _liveSums() internal view returns (uint256 sumShares, uint256 sumBody, uint256 sumPending, uint256 n) {
        uint256 len = h.idsLength();
        for (uint256 i; i < len; i++) {
            uint256 id = h.ids(i);
            if (!h.live(id)) continue;
            (uint256 s,,,,) = v.positionOf(id);
            sumShares += s;
            sumBody += v.bodyOf(id);
            sumPending += v.pendingYieldOf(id);
            n++;
        }
    }

    // I1  stake-token solvency: the vault holds exactly the pooled body
    function invariant_I1_vaultStakeBalanceEqualsTotalBody() public view {
        assertEq(stake.balanceOf(address(v)), v.totalBody());
    }

    // I2  convergence: shares == 0  <=>  body == 0 (no orphaned body after the last exit)
    function invariant_I2_zeroSharesIffZeroBody() public view {
        assertEq(v.totalShares() == 0, v.totalBody() == 0);
    }

    // I3  Σ position shares == totalShares ; Σ position body ≤ totalBody, rounding dust ≤ #live positions
    function invariant_I3_sharesAndBodyAddUp() public view {
        (uint256 ss, uint256 sb,, uint256 n) = _liveSums();
        assertEq(ss, v.totalShares());
        assertLe(sb, v.totalBody());
        assertLe(v.totalBody() - sb, n);
    }

    // I4  95/5 exit math is exact on every exit, burn address balance == Σ burns == vault.totalBurned()
    function invariant_I4_ragequitIs95_5_withBurn() public view {
        assertFalse(h.mathBroken());
        assertEq(stake.balanceOf(DEAD), h.gBurned());
        assertEq(v.totalBurned(), h.gBurned());
    }

    // I5  stake-token conservation: everything that went in is in the vault, treasury, creator, burned or paid out
    function invariant_I5_stakeConservation() public view {
        assertEq(
            h.gStakeIn(),
            stake.balanceOf(address(v)) + stake.balanceOf(treasury) + stake.balanceOf(creator) + h.gBurned()
                + h.gBodyPaid()
        );
    }

    // I6  yield-token conservation (nothing created or lost)
    function invariant_I6_yieldConservation() public view {
        assertEq(
            h.gYieldMinted(),
            usdc.balanceOf(address(v)) + usdc.balanceOf(treasury) + usdc.balanceOf(creator) + h.gYieldPaid()
        );
    }

    // I7  treasury gets exactly floor(10%) of every synced/distributed amount; creator gets the rest of early yield
    function invariant_I7_yieldFeeSplit() public view {
        assertEq(usdc.balanceOf(treasury), h.gYieldTreasury());
        assertEq(usdc.balanceOf(creator), h.gYieldCreator());
        assertEq(v.protocolYieldOwed(), 0); // token never blocks in this suite
    }

    // I8  syncYield bookkeeping: unsynced == balance - accounted ; accounted covers every pending claim; dust is bounded
    function invariant_I8_yieldAccounting() public view {
        uint256 bal = usdc.balanceOf(address(v));
        uint256 acc = v.accountedYieldBalance();
        assertGe(bal, acc);
        assertEq(bal - acc, h.gUnsynced());
        (,, uint256 sumPending,) = _liveSums();
        assertLe(sumPending, acc, "pending exceeds accounted");
        assertLe(acc - sumPending, h.gEvents() + 1, "unclaimable dust above rounding budget");
    }
}

// ════════════════════════════════════════════════════════════════════════
// Directed fuzz scenarios
// ════════════════════════════════════════════════════════════════════════
contract VaultFuzz is VaultBase {
    function setUp() public { _setUpBase(); }

    // ---- full exit converges to zero ----
    function testFuzz_fullExit_convergesToZero(uint8 nRaw, uint256 seed) public {
        uint256 n = bound(nRaw, 1, 10);
        address[] memory who = new address[](n);
        uint256[] memory id = new uint256[](n);
        uint256 stakeIn;
        uint256 yieldIn;
        uint256 events;

        for (uint256 i; i < n; i++) {
            who[i] = makeAddr(string(abi.encodePacked("u", vm.toString(i))));
            uint256 amt = bound(uint256(keccak256(abi.encode(seed, "a", i))), 1e6, 1e24);
            stake.mint(who[i], amt);
            vm.startPrank(who[i]);
            stake.approve(address(v), amt);
            try v.deposit(amt) returns (uint256 t) {
                id[i] = t;
                stakeIn += amt;
            } catch {}
            vm.stopPrank();

            uint256 tx_ = bound(uint256(keccak256(abi.encode(seed, "t", i))), 0, 1e22);
            _tax(tx_);
            stakeIn += tx_;
            uint256 y = bound(uint256(keccak256(abi.encode(seed, "y", i))), 0, 1e12);
            _yield(y);
            yieldIn += y;
            events++;
        }

        // random exit order (Fisher-Yates)
        uint256[] memory order = new uint256[](n);
        for (uint256 i; i < n; i++) order[i] = i;
        for (uint256 i = n; i > 1; i--) {
            uint256 j = uint256(keccak256(abi.encode(seed, "o", i))) % i;
            (order[i - 1], order[j]) = (order[j], order[i - 1]);
        }

        uint256 bodyPaid;
        uint256 burned;
        uint256 yieldPaid;
        for (uint256 k; k < n; k++) {
            uint256 t = id[order[k]];
            if (t == 0) continue;
            vm.prank(who[order[k]]);
            (uint256 b, uint256 yp) = v.ragequit(t);
            bodyPaid += b;
            yieldPaid += yp;
            events++;
        }
        burned = stake.balanceOf(DEAD);

        assertEq(v.totalShares(), 0, "shares");
        assertEq(v.totalBody(), 0, "body");
        assertEq(stake.balanceOf(address(v)), 0, "stake left in vault");
        assertEq(stakeIn, bodyPaid + burned + stake.balanceOf(treasury) + stake.balanceOf(creator), "stake conservation");
        assertEq(v.totalBurned(), burned);
        // yield: only rounding dust may remain
        uint256 leftover = usdc.balanceOf(address(v));
        assertLe(leftover, events + n, "yield dust");
        assertEq(yieldIn, leftover + yieldPaid + usdc.balanceOf(treasury) + usdc.balanceOf(creator), "yield conservation");

        // the vault is reusable and starts clean
        uint256 again = 1e18;
        uint256 t2 = _dep(makeAddr("again"), again);
        (uint256 s2,,,,) = v.positionOf(t2);
        assertEq(s2, again, "fresh 1:1 shares after empty");
        assertEq(v.totalBody(), again);
    }

    // ---- yield through syncYield at different life-cycle moments ----
    function testFuzz_yield_lifecycle_split(uint256 a, uint256 b, uint256 y0, uint256 y1, uint256 y2) public {
        a = bound(a, 1e9, 1e24);
        b = bound(b, 1e9, 1e24);
        y0 = bound(y0, 1e3, 1e15);
        y1 = bound(y1, 1e3, 1e15);
        y2 = bound(y2, 1e3, 1e15);

        // (0) yield arrives before the first deposit -> swept 10% treasury / 90% owner, never to stakers
        usdc.mint(address(v), y0);
        uint256 idA = _dep(makeAddr("A"), a); // deposit syncs first
        assertEq(usdc.balanceOf(treasury), y0 / 10, "treasury early");
        assertEq(usdc.balanceOf(creator), y0 - y0 / 10, "owner early");
        assertEq(v.pendingYieldOf(idA), 0, "first depositor cannot capture pre-deposit yield");
        assertEq(v.accountedYieldBalance(), 0);

        // (1) yield with only A in the vault
        _yield(y1);
        uint256 s1 = y1 - y1 / 10;
        _near(v.pendingYieldOf(idA), s1, 1, "A gets all staker yield");
        assertEq(usdc.balanceOf(treasury), y0 / 10 + y1 / 10, "treasury after y1");

        // (2) B joins late: must not receive any of y1
        uint256 idB = _dep(makeAddr("B"), b);
        assertEq(v.pendingYieldOf(idB), 0, "late joiner has no claim on old yield");

        _yield(y2);
        uint256 s2 = y2 - y2 / 10;
        (uint256 shA,,,,) = v.positionOf(idA);
        (uint256 shB,,,,) = v.positionOf(idB);
        _near(v.pendingYieldOf(idA), s1 + (s2 * shA) / (shA + shB), 2, "A pro-rata");
        _near(v.pendingYieldOf(idB), (s2 * shB) / (shA + shB), 2, "B pro-rata");
        assertEq(usdc.balanceOf(treasury), y0 / 10 + y1 / 10 + y2 / 10, "treasury total");

        // (3) a direct transfer right before a deposit is synced FIRST (anti-snipe): the new depositor gets none of it
        uint256 y3 = 1e9;
        usdc.mint(address(v), y3);
        uint256 idC = _dep(makeAddr("C"), a);
        assertEq(v.pendingYieldOf(idC), 0, "sniper gets nothing from yield sent before its deposit");

        // (4) the sum of claimable never exceeds what the vault actually holds
        uint256 sum = v.pendingYieldOf(idA) + v.pendingYieldOf(idB) + v.pendingYieldOf(idC);
        assertLe(sum, usdc.balanceOf(address(v)));
        assertEq(v.accountedYieldBalance(), usdc.balanceOf(address(v)));

        // (5) exit of A pays its pending in full and leaves B's claim intact
        uint256 pb = v.pendingYieldOf(idB);
        vm.prank(makeAddr("A"));
        (, uint256 ya) = v.ragequit(idA);
        assertGt(ya, 0);
        assertEq(v.pendingYieldOf(idB), pb, "B untouched by A's exit");
    }

    function testFuzz_distributeYield_equalsSyncYield(uint256 amt) public {
        amt = bound(amt, 1e3, 1e15);
        _dep(makeAddr("A"), 1e18);
        uint256 snap = vm.snapshotState();

        _yield(amt);
        uint256 viaSync = v.accYieldPerShare();
        uint256 trSync = usdc.balanceOf(treasury);

        vm.revertToState(snap);
        usdc.mint(address(this), amt);
        usdc.approve(address(v), amt);
        v.distributeYield(amt);
        assertEq(v.accYieldPerShare(), viaSync);
        assertEq(usdc.balanceOf(treasury), trSync);
        assertEq(trSync, amt / 10);
    }

    // ---- NFT transfer keeps the claim with the token ----
    function testFuzz_transfer_pendingYieldMovesWithToken(uint256 amt, uint256 y1, uint256 y2) public {
        amt = bound(amt, 1e9, 1e24);
        y1 = bound(y1, 1e3, 1e15);
        y2 = bound(y2, 1e3, 1e15);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        uint256 id = _dep(alice, amt);

        _yield(y1);
        uint256 pendingAtTransfer = v.pendingYieldOf(id);
        assertGt(pendingAtTransfer, 0);

        vm.prank(alice);
        v.transferFrom(alice, bob, id);
        assertEq(v.pendingYieldOf(id), pendingAtTransfer, "pending travels with the NFT");

        _yield(y2);

        vm.prank(alice);
        vm.expectRevert("Not owner or approved");
        v.claimYield(id);

        vm.prank(bob);
        uint256 got = v.claimYield(id);
        _near(got, (y1 - y1 / 10) + (y2 - y2 / 10), 2, "new owner gets old + new yield");
        assertEq(usdc.balanceOf(bob), got);
        assertEq(usdc.balanceOf(alice), 0, "seller keeps nothing unclaimed");
        assertEq(v.pendingYieldOf(id), 0);
    }

    /// DOCUMENTED behaviour (not a bug): payout goes to msg.sender, so an approved operator is paid, not the holder.
    function test_documented_operatorClaimPaysOperator() public {
        address alice = makeAddr("alice");
        address op = makeAddr("operator");
        uint256 id = _dep(alice, 1e18);
        _yield(1e9);
        vm.prank(alice);
        v.approve(op, id);
        vm.prank(op);
        uint256 got = v.claimYield(id);
        assertEq(usdc.balanceOf(op), got);
        assertEq(usdc.balanceOf(alice), 0);
    }

    /// DOCUMENTED behaviour: ragequit keeps working if the yield payout fails, but the position's pending yield
    /// is forfeited (stays in the vault, accounted, not claimable by anyone).
    function test_documented_blockedHolder_ragequitPaysBody_butYieldIsForfeited() public {
        BlockERC20 bt = new BlockERC20();
        LiquidAccountVault vb = _deploy(stake, MockERC20(address(bt)));
        address alice = makeAddr("alice");
        stake.mint(alice, 1e18);
        vm.startPrank(alice);
        stake.approve(address(vb), 1e18);
        uint256 id = vb.deposit(1e18);
        vm.stopPrank();
        bt.mint(address(vb), 1e9);
        vb.syncYield();
        uint256 pend = vb.pendingYieldOf(id);
        assertGt(pend, 0);

        bt.setBlocked(alice, true);
        vm.prank(alice);
        (uint256 body, uint256 yp) = vb.ragequit(id);
        assertEq(body, 1e18 - (1e18 * 500) / 10_000, "body still paid 95%");
        assertEq(yp, 0, "yield payout failed -> reported as 0");
        assertEq(vb.totalShares(), 0);
        assertEq(vb.totalBody(), 0);
        assertEq(bt.balanceOf(address(vb)), pend, "forfeited yield remains in the vault");
    }

    // ---- first-depositor / inflation attempts ----
    function testFuzz_firstDepositor_cannotCaptureStrayStakeOrYield(uint256 strayStake, uint256 strayYield, uint256 amt)
        public
    {
        strayStake = bound(strayStake, 1, 1e30);
        strayYield = bound(strayYield, 1, 1e15);
        amt = bound(amt, 1, 1e24);

        stake.mint(address(v), strayStake);
        usdc.mint(address(v), strayYield);
        address attacker = makeAddr("attacker");
        uint256 id = _dep(attacker, amt);

        (uint256 shares,,,,) = v.positionOf(id);
        assertEq(shares, amt, "stray tokens did not inflate share price");
        assertEq(v.totalBody(), amt);
        assertEq(stake.balanceOf(address(v)), amt);
        assertEq(stake.balanceOf(treasury), strayStake / 10);
        assertEq(stake.balanceOf(creator), strayStake - strayStake / 10);
        assertEq(v.pendingYieldOf(id), 0);
    }

    function testFuzz_inflationAttack_victimNotRobbed_attackerNotProfiting(uint256 a, uint256 d, uint256 vAmt) public {
        a = bound(a, 1, 1e24);
        d = bound(d, 0, 1e30);
        vAmt = bound(vAmt, 1, 1e24);
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");

        uint256 idA = _dep(attacker, a);
        _tax(d); // donation through the tax path: 10% to treasury, 90% to the (sole) body

        uint256 bodyBefore = v.totalBody();
        uint256 sharesBefore = v.totalShares();
        stake.mint(victim, vAmt);
        vm.startPrank(victim);
        stake.approve(address(v), vAmt);
        uint256 idV;
        bool ok;
        try v.deposit(vAmt) returns (uint256 t) { idV = t; ok = true; } catch {}
        vm.stopPrank();

        if (!ok) {
            // a reverted deposit loses nothing
            assertEq(stake.balanceOf(victim), vAmt, "reverted deposit must leave victim whole");
        } else {
            // worst-case rounding loss is bounded by the value of ONE share before the deposit
            uint256 oneShare = bodyBefore / sharesBefore + 1;
            uint256 vb = v.bodyOf(idV);
            assertGe(vb + oneShare, vAmt, "victim loss exceeds one share of rounding");
        }

        vm.prank(attacker);
        (uint256 payout,) = v.ragequit(idA);
        // attacker spent a (deposit) + d (donation); it must not come out ahead
        assertLe(payout, a + d, "attacker profited");
    }

    // ---- no admin switch can block exits or claims ----
    function test_noAdminPause_exitAndClaimAlwaysAvailable() public {
        address alice = makeAddr("alice");
        uint256 id = _dep(alice, 1e18);
        _yield(1e9);

        // the owner uses every admin power it has
        vm.startPrank(creator);
        v.setBaseURI("ipfs://x/");
        v.setDescriptor(address(this)); // a contract without tokenURI(address,uint256): must not matter
        v.transferOwnership(address(0xdead));
        vm.stopPrank();
        // ... and tokenURI still doesn't brick anything
        v.tokenURI(id);

        vm.startPrank(alice);
        uint256 c = v.claimYield(id);
        assertGt(c, 0);
        (uint256 body,) = v.ragequit(id);
        assertEq(body, 1e18 - (1e18 * 500) / 10_000);
        vm.stopPrank();
    }

    function test_noPauseFunctionsInAbi() public {
        // the ABI exposes no pause/unpause/setFee selectors
        bytes4[5] memory bad = [
            bytes4(keccak256("pause()")),
            bytes4(keccak256("unpause()")),
            bytes4(keccak256("setPaused(bool)")),
            bytes4(keccak256("setFee(uint256)")),
            bytes4(keccak256("setTreasury(address)"))
        ];
        for (uint256 i; i < bad.length; i++) {
            (bool ok,) = address(v).call(abi.encodeWithSelector(bad[i]));
            assertFalse(ok);
        }
    }
}
