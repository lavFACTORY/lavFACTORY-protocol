// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ILiquidAccountVault} from "../src/ILiquidAccountVault.sol";

contract MockERC20 {
    string public name; string public symbol; uint8 public decimals; uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, string memory s, uint8 d) { name = n; symbol = s; decimals = d; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { _t(msg.sender, to, a); return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) { require(al >= a, "allowance"); allowance[f][msg.sender] = al - a; }
        _t(f, t, a);
        return true;
    }
    function _t(address f, address t, uint256 a) internal virtual {
        require(balanceOf[f] >= a, "balance");
        balanceOf[f] -= a; balanceOf[t] += a;
    }
}

/// 10% of every transfer is destroyed.
contract FeeERC20 is MockERC20 {
    constructor() MockERC20("Fee", "FEE", 18) {}
    function _t(address f, address t, uint256 a) internal override {
        require(balanceOf[f] >= a, "balance");
        uint256 fee = a / 10;
        balanceOf[f] -= a; balanceOf[t] += a - fee; totalSupply -= fee;
    }
}

/// Transfers to or from a blocked address revert.
contract BlockERC20 is MockERC20 {
    mapping(address => bool) public blocked;
    constructor() MockERC20("Block", "BLK", 18) {}
    function setBlocked(address a, bool b) external { blocked[a] = b; }
    function _t(address f, address t, uint256 a) internal override {
        require(!blocked[f] && !blocked[t], "blocked");
        require(balanceOf[f] >= a, "balance");
        balanceOf[f] -= a; balanceOf[t] += a;
    }
}

/// 1% tax on transfers between non-excluded addresses, pushed to the vault + notifyTaxBody().
contract TaxHookToken is MockERC20 {
    address public vault;
    mapping(address => bool) public excluded;
    constructor() MockERC20("TaxHook", "TAX", 18) {}
    function setVault(address v, bool excludeVault) external { vault = v; excluded[v] = excludeVault; }
    function setExcluded(address a, bool e) external { excluded[a] = e; }
    function _t(address f, address t, uint256 a) internal override {
        require(balanceOf[f] >= a, "balance");
        if (vault != address(0) && !excluded[f] && !excluded[t]) {
            uint256 tax = a / 100;
            balanceOf[f] -= a; balanceOf[t] += a - tax; balanceOf[vault] += tax;
            ILiquidAccountVault(vault).notifyTaxBody();
        } else {
            balanceOf[f] -= a; balanceOf[t] += a;
        }
    }
}

contract SafeLike { receive() external payable {} }

contract MockRegistry {
    function account(address, bytes32, uint256, address, uint256) external pure returns (address) {
        return address(uint160(uint256(keccak256("tba"))));
    }
}
