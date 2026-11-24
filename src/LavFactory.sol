// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/**
 * @title LavFactory
 * @notice lavFACTORY: canonical vault factory and registry of the lavFACTORY protocol. Deploys LAV (LiquidAccountVaults)
 *         vaults and records them (isVault, allVaults, tokenToVaults). `isVault` means "created by this contract",
 *         not "reviewed" or "safe". The factory does not issue tokens.
 *         Permissionless multi-vault deployment. No owner, no admin, no pause.
 *         Anti-spam fee is fixed at exactly 0.002 ETH and forwarded to protocolTreasury.
 *
 * All rights reserved.
 */

import {LiquidAccountVault} from "./LiquidAccountVault.sol";

contract LavFactory {
    address public immutable protocolTreasury;
    address public immutable erc6551Registry;
    address public immutable erc6551Implementation;

    uint256 public constant CREATION_FEE = 0.002 ether;

    address[] public allVaults;
    mapping(address => address[]) public tokenToVaults; // stakingToken => vaults[]
    mapping(address => bool) public isVault;

    event VaultCreated(
        address indexed stakingToken,
        address indexed yieldToken,
        address vault,
        address indexed creator,
        uint256 vaultIndex
    );

    constructor(address _protocolTreasury, address _erc6551Registry, address _erc6551Implementation) {
        require(_protocolTreasury != address(0), "Zero treasury");
        require(_protocolTreasury.code.length > 0, "Treasury not deployed");
        require(_erc6551Registry != address(0), "Zero registry");
        require(_erc6551Registry.code.length > 0, "ERC6551 registry missing");
        require(_erc6551Implementation != address(0), "Zero implementation");
        require(_erc6551Implementation.code.length > 0, "ERC6551 implementation missing");

        protocolTreasury = _protocolTreasury;
        erc6551Registry = _erc6551Registry;
        erc6551Implementation = _erc6551Implementation;
    }

    function totalVaults() external view returns (uint256) {
        return allVaults.length;
    }

    function getVaultsByToken(address token) external view returns (address[] memory) {
        return tokenToVaults[token];
    }

    /**
     * @notice Deploy a new LiquidAccountVault. msg.sender becomes the vault creator/owner.
     * @dev The vault name and symbol are derived here from the staking token's own symbol(), so the caller cannot
     *      choose them: name "lav<SYMBOL> Vault", symbol "lav<SYMBOL>". The symbol is read with a bounded call
     *      (gas and return data limited), reduced to [A-Za-z0-9 ._+-] and cut to 12 characters; if nothing usable
     *      is left it is "TOKEN". Checks, then effects, then the fee transfer last (checks-effects-interactions).
     */
    function createVault(address stakingToken, address yieldToken) external payable returns (address vaultAddress) {
        require(msg.value == CREATION_FEE, "Must send exactly 0.002 ETH");
        require(stakingToken != address(0), "Zero staking token");
        require(stakingToken.code.length > 0, "Staking token not a contract");
        require(yieldToken != address(0), "Zero yield token");
        require(yieldToken.code.length > 0, "Yield token not a contract");
        require(stakingToken != yieldToken, "Identical tokens");

        string memory sym = _cleanSymbol(stakingToken);

        LiquidAccountVault vault = new LiquidAccountVault(
            stakingToken,
            yieldToken,
            string.concat("lav", sym, " Vault"),
            string.concat("lav", sym),
            msg.sender,
            protocolTreasury,
            erc6551Registry,
            erc6551Implementation
        );

        vaultAddress = address(vault);
        allVaults.push(vaultAddress);
        tokenToVaults[stakingToken].push(vaultAddress);
        isVault[vaultAddress] = true;

        emit VaultCreated(stakingToken, yieldToken, vaultAddress, msg.sender, allVaults.length - 1);

        (bool sent, ) = protocolTreasury.call{value: CREATION_FEE}("");
        require(sent, "Treasury transfer failed");
    }

    uint256 internal constant SYMBOL_GAS = 50_000;
    uint256 internal constant SYMBOL_MAX_LEN = 12;

    /// @dev Reads token.symbol() (string or bytes32) with bounded gas and at most 128 bytes of reply, then keeps
    ///      only [A-Za-z0-9 ._+-], at most SYMBOL_MAX_LEN characters. Returns "TOKEN" if nothing remains.
    function _cleanSymbol(address token) internal view returns (string memory) {
        bytes memory raw = new bytes(128);
        uint256 size;
        uint256 g = SYMBOL_GAS;
        bytes4 sel = 0x95d89b41; // symbol()
        bool ok;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, sel)
            ok := staticcall(g, token, ptr, 4, add(raw, 32), 128)
            size := returndatasize()
            if gt(size, 128) { size := 128 }
        }
        bytes memory src;
        if (ok && size == 32) {
            // bytes32 symbol: take bytes up to the first zero
            uint256 n;
            while (n < 32 && raw[n] != 0) n++;
            src = new bytes(n);
            for (uint256 i; i < n; i++) src[i] = raw[i];
        } else if (ok && size >= 96) {
            uint256 off;
            uint256 len;
            assembly ("memory-safe") {
                off := mload(add(raw, 32))
                len := mload(add(raw, 64))
            }
            if (off == 32 && len <= size - 64) {
                src = new bytes(len);
                for (uint256 i; i < len; i++) src[i] = raw[64 + i];
            }
        }
        bytes memory out = new bytes(SYMBOL_MAX_LEN);
        uint256 m;
        for (uint256 i; i < src.length && m < SYMBOL_MAX_LEN; i++) {
            bytes1 c = src[i];
            if (
                (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x20
                    || c == 0x2E || c == 0x5F || c == 0x2B || c == 0x2D
            ) {
                out[m++] = c;
            }
        }
        if (m == 0) return "TOKEN";
        assembly ("memory-safe") {
            mstore(out, m)
        }
        return string(out);
    }
}
