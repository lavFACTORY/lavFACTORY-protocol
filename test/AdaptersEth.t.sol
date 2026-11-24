// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LavAdapterPnsEth, IPnsFeeEscrowNative, IWETH} from "../src/adapters/LavAdapterPnsEth.sol";
import {IERC20, PnsFeePolicy, PnsLaunch, IPnsFactory, ILavVault, ILavFactory} from "../src/adapters/LavAdapterPns.sol";
import {MockPnsFactory, MockLavFactory, MockLavVault} from "./Adapters.t.sol";

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

contract AdaptersEthTest is Test {
    LavAdapterPnsEth public adapter;
    MockPnsFeeEscrowNative public escrow;
    MockPnsFactory public pnsFactory;
    MockLavFactory public lavFactory;
    MockWETH public weth;
    MockLavVault public vault;

    address public deployer = address(0xD1);
    address public team = address(0x7EA);
    address public treasury = address(0x78EA);
    address public pnsToken = address(0x70CE);

    function setUp() public {
        escrow = new MockPnsFeeEscrowNative();
        pnsFactory = new MockPnsFactory();
        lavFactory = new MockLavFactory();
        weth = new MockWETH();

        vm.prank(deployer);
        adapter = new LavAdapterPnsEth(
            address(escrow),
            address(pnsFactory),
            address(lavFactory),
            address(weth),
            100 ether,
            900
        );

        vault = new MockLavVault(address(0x57A), address(weth), treasury);
        lavFactory.setVault(address(vault), true);

        // PNS fee policy for native ETH launch: pairToken == address(0)
        pnsFactory.setFeePolicy(pnsToken, PnsFeePolicy({
            feeRecipient: team,
            hookFeeBps: 200,
            protocolFeeShareBps: 1000,
            exempt: false
        }));
        pnsFactory.setLaunch(pnsToken, PnsLaunch({
            curve: address(0),
            token: pnsToken,
            pairToken: address(0), // Native ETH pair
            creatorTaxBps: 100
        }));
    }

    function test_bindVault_eth() public {
        vm.prank(deployer);
        adapter.bindVault(pnsToken, address(vault), 100);

        assertTrue(adapter.bound());
        assertEq(adapter.vault(), address(vault));
        assertEq(adapter.vaultBps(), 100);
        assertEq(adapter.teamBps(), 180);
        assertEq(adapter.protocolTreasury(), treasury);
    }

    function test_pull_wraps_eth_to_weth_and_splits() public {
        vm.prank(deployer);
        adapter.bindVault(pnsToken, address(vault), 100);

        uint256 grossEth = 10 ether;
        vm.deal(address(escrow), grossEth);
        escrow.setBalance(address(adapter), grossEth);

        adapter.pull();

        uint256 expectedVault = (grossEth * 100) / 280;
        uint256 teamPart = grossEth - expectedVault;
        uint256 expectedTreasury = (teamPart * 1000) / 10000;
        uint256 expectedTeam = teamPart - expectedTreasury;

        assertEq(weth.balanceOf(address(vault)), expectedVault);
        assertEq(weth.balanceOf(treasury), expectedTreasury);
        assertEq(weth.balanceOf(team), expectedTeam);
        assertEq(weth.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
    }
}
