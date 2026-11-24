// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LavAdapterPnsEth, IPnsFeeEscrowNative, IWETH} from "../src/adapters/LavAdapterPnsEth.sol";
import {LavAdapterPns, IERC20, IPnsFeeEscrow, IPnsFactory, IPnsCurve, ILavVault, ILavFactory, PnsLaunch, PnsFeePolicy} from "../src/adapters/LavAdapterPns.sol";
import {MockERC20, BlockERC20} from "./Mocks.sol";

contract MockPnsFeeEscrow is IPnsFeeEscrow {
    mapping(address => mapping(address => uint256)) public balances;

    function setBalance(address recipient, address token, uint256 amount) external {
        balances[recipient][token] = amount;
    }

    function balanceOfToken(address recipient, address token) external view returns (uint256) {
        return balances[recipient][token];
    }

    function claimToken(address token, uint256 amount) external returns (uint256) {
        require(balances[msg.sender][token] >= amount, "escrow: insufficient balance");
        balances[msg.sender][token] -= amount;
        MockERC20(token).mint(msg.sender, amount);
        return amount;
    }
}

contract MockPnsFactory is IPnsFactory {
    mapping(address => PnsLaunch) public launches;
    mapping(address => PnsFeePolicy) public policies;

    function setLaunch(address token, PnsLaunch memory l) external {
        launches[token] = l;
    }

    function setPolicy(address token, PnsFeePolicy memory p) external {
        policies[token] = p;
    }

    function getLaunchedToken(address token) external view returns (PnsLaunch memory) {
        return launches[token];
    }

    function getLaunchFeePolicy(address token) external view returns (PnsFeePolicy memory) {
        return policies[token];
    }
}

contract MockLavVault is ILavVault {
    address public immutable override stakingToken;
    address public immutable override yieldToken;
    address public immutable override protocolTreasury;
    uint256 public syncYieldCalls;
    bool public shouldFailSync;

    constructor(address _stakingToken, address _yieldToken, address _treasury) {
        stakingToken = _stakingToken;
        yieldToken = _yieldToken;
        protocolTreasury = _treasury;
    }

    function setShouldFailSync(bool _fail) external {
        shouldFailSync = _fail;
    }

    function syncYield() external override {
        if (shouldFailSync) revert("sync failed");
        syncYieldCalls++;
    }
}

contract MockLavFactory is ILavFactory {
    mapping(address => bool) public vaults;

    function setVault(address v, bool isV) external {
        vaults[v] = isV;
    }

    function isVault(address v) external view override returns (bool) {
        return vaults[v];
    }
}

contract AdaptersTest is Test {
    MockPnsFeeEscrow internal escrow;
    MockPnsFactory internal pnsFactory;
    MockLavFactory internal lavFactory;
    MockERC20 internal usdg;
    MockERC20 internal token;
    MockLavVault internal vault;

    LavAdapterPns internal adapter;

    address internal deployer = makeAddr("deployer");
    address internal team = makeAddr("team");
    address internal treasury = makeAddr("treasurySafe");

    uint256 internal constant MAX_PULL = 50e6; // 50 USDG
    uint256 internal constant INTERVAL = 900; // 15 mins

    function setUp() public {
        vm.startPrank(deployer);
        escrow = new MockPnsFeeEscrow();
        pnsFactory = new MockPnsFactory();
        lavFactory = new MockLavFactory();
        usdg = new MockERC20("USDG", "USDG", 6);
        token = new MockERC20("Token", "TKN", 18);

        vault = new MockLavVault(address(token), address(usdg), treasury);
        lavFactory.setVault(address(vault), true);

        PnsLaunch memory l = PnsLaunch({
            token: address(token),
            curve: address(0),
            deployer: deployer,
            creatorFeeRecipient: address(0),
            pairToken: address(usdg),
            graduationThreshold: 0,
            poolFee: 3000,
            tickSpacing: 60,
            creatorTaxBps: 100, // 1%
            buybackEnabled: false,
            phase: 2,
            sweptQuote: 0,
            sweptTokens: 0,
            sweptAt: 0,
            exists: true
        });
        pnsFactory.setLaunch(address(token), l);

        PnsFeePolicy memory p = PnsFeePolicy({
            protocolFeeRecipient: address(0xdead),
            protocolFeeShareBps: 2000, // 20% to PNS protocol
            buybackBurnBps: 0,
            hookFeeBps: 100, // 1%
            maxInternalPriceImpactBps: 500
        });
        pnsFactory.setPolicy(address(token), p);

        adapter = new LavAdapterPns(
            address(escrow),
            address(pnsFactory),
            address(lavFactory),
            address(usdg),
            MAX_PULL,
            INTERVAL
        );
        vm.stopPrank();
    }

    function test_bindVault_success() public {
        vm.prank(deployer);
        adapter.bindVault(address(vault), address(token), team, 50);

        assertTrue(adapter.bound());
        assertEq(adapter.vault(), address(vault));
        assertEq(adapter.teamWallet(), team);
        assertEq(adapter.protocolTreasury(), treasury);
        assertEq(adapter.vaultBps(), 50);
        // base = 100 * (10000 - 2000) / 10000 = 80 bps. totalCreatorBps = 80 + 100 = 180 bps.
        // teamBps = 180 - 50 = 130 bps.
        assertEq(adapter.teamBps(), 130);
    }

    function test_bindVault_floorReverts() public {
        vm.prank(deployer);
        // MIN_VAULT_SHARE_BPS is 10 bps
        vm.expectRevert(LavAdapterPns.VaultShareBelowFloor.selector);
        adapter.bindVault(address(vault), address(token), team, 9);
    }

    function test_bindVault_exceedsTotalReverts() public {
        vm.prank(deployer);
        // totalCreatorBps is 180 bps
        vm.expectRevert(LavAdapterPns.VaultShareExceedsTotal.selector);
        adapter.bindVault(address(vault), address(token), team, 181);
    }

    function test_bindVault_nonDeployerReverts() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LavAdapterPns.NotDeployer.selector);
        adapter.bindVault(address(vault), address(token), team, 50);
    }

    function test_pull_feeSplit() public {
        vm.prank(deployer);
        adapter.bindVault(address(vault), address(token), team, 90); // 90 bps vault, 90 bps team (50/50 split of creator fees)

        escrow.setBalance(address(adapter), address(usdg), 100e6); // 100 USDG in escrow

        vm.warp(block.timestamp + INTERVAL + 1);
        uint256 pulled = adapter.pull();
        // Capped by maxPullPerCall = 50 USDG
        assertEq(pulled, 50e6);

        // vault receives 50% = 25 USDG
        assertEq(usdg.balanceOf(address(vault)), 25e6);
        assertEq(vault.syncYieldCalls(), 1);

        // teamPart = 25 USDG.
        // toTreasury = 25e6 * 1000 / 10000 = 2.5e6 (10% of team part)
        // toTeam = 25e6 - 2.5e6 = 22.5e6 (90% of team part)
        assertEq(usdg.balanceOf(treasury), 2.5e6);
        assertEq(usdg.balanceOf(team), 22.5e6);
    }

    function test_pull_intervalEnforced() public {
        vm.prank(deployer);
        adapter.bindVault(address(vault), address(token), team, 90);
        escrow.setBalance(address(adapter), address(usdg), 100e6);

        vm.warp(block.timestamp + INTERVAL + 1);
        uint256 pulled1 = adapter.pull();
        assertEq(pulled1, 50e6);

        // Calling immediately returns 0
        uint256 pulledImmediate = adapter.pull();
        assertEq(pulledImmediate, 0);

        // Advance by minPullInterval
        vm.warp(block.timestamp + INTERVAL + 1);
        uint256 pulled2 = adapter.pull();
        assertEq(pulled2, 50e6);
    }

    function test_pull_owedAccrualAndNoDoubleCounting() public {
        // Deploy adapter where usdg is a BlockERC20 to simulate transfer failure to treasury
        BlockERC20 badUsdg = new BlockERC20();
        badUsdg.setBlocked(treasury, true); // treasury blocked

        vm.startPrank(deployer);
        MockLavVault v2 = new MockLavVault(address(token), address(badUsdg), treasury);
        lavFactory.setVault(address(v2), true);

        PnsLaunch memory l2 = pnsFactory.getLaunchedToken(address(token));
        l2.pairToken = address(badUsdg);
        pnsFactory.setLaunch(address(token), l2);

        LavAdapterPns ad2 = new LavAdapterPns(
            address(escrow),
            address(pnsFactory),
            address(lavFactory),
            address(badUsdg),
            MAX_PULL,
            INTERVAL
        );
        ad2.bindVault(address(v2), address(token), team, 90);
        vm.stopPrank();

        escrow.setBalance(address(ad2), address(badUsdg), 100e18);

        vm.warp(block.timestamp + INTERVAL + 1);
        ad2.pull();

        // treasury transfer failed -> accrued to treasuryOwed
        uint256 owed = ad2.treasuryOwed();
        assertGt(owed, 0);
        assertEq(badUsdg.balanceOf(treasury), 0);

        // Next pull after interval: verify owed balance is NOT re-split or counted as local surplus
        vm.warp(block.timestamp + INTERVAL + 1);
        uint256 pulled2 = ad2.pull();
        assertGt(pulled2, 0);

        // Unblock treasury and permissionlessly claim owed
        badUsdg.setBlocked(treasury, false);
        ad2.claimTreasuryOwed();
        assertEq(ad2.treasuryOwed(), 0);
        assertEq(badUsdg.balanceOf(treasury), owed);
    }

    function test_teamWalletTwoStepTransfer() public {
        vm.prank(deployer);
        adapter.bindVault(address(vault), address(token), team, 90);

        address newTeam = makeAddr("newTeam");

        // Stranger cannot propose
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LavAdapterPns.NotTeam.selector);
        adapter.proposeTeamWallet(newTeam);

        // Team proposes
        vm.prank(team);
        adapter.proposeTeamWallet(newTeam);
        assertEq(adapter.pendingTeamWallet(), newTeam);

        // Non-pending cannot accept
        vm.prank(team);
        vm.expectRevert(LavAdapterPns.NotPending.selector);
        adapter.acceptTeamWallet();

        // New team accepts
        vm.prank(newTeam);
        adapter.acceptTeamWallet();
        assertEq(adapter.teamWallet(), newTeam);
        assertEq(adapter.pendingTeamWallet(), address(0));
    }
}


contract MockWETH is IERC20, IWETH {
    mapping(address => uint256) public balanceOf;
    uint8 public decimals = 18;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockPnsFeeEscrowNative is IPnsFeeEscrowNative {
    mapping(address => uint256) public balanceOf;

    function setBalance(address recipient, uint256 amount) external {
        balanceOf[recipient] = amount;
    }

    function claim(uint256 amount) external returns (uint256) {
        require(balanceOf[msg.sender] >= amount, "escrow bal");
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth transfer failed");
        return amount;
    }

    receive() external payable {}
}
