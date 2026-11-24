// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/**
 * @title LiquidAccountVault (LAV core r7)
 * @author lavFACTORY Standard authors — reference ERC-721 / accounting infrastructure
 * @dev Dual-engine body growth, protocol share & performance fee, 95/5 ragequit, factory wiring
 *
 * @notice Sovereign, non-custodial, unpausable vault that turns a project token into a
 *         yield-bearing transferable NFT position. Deployed through LavFactory.
 *
 *         Economics:
 *         - Tax body: 10% protocol / 90% shared body growth
 *         - Yield:    10% protocol fee / 90% stakers
 *         - Exit:     5% body burn on ragequit, 100% yield returned
 *         - No creator fee. No pause. Ragequit always available.
 *
 * All rights reserved.
 */

import {ILiquidAccountVault} from "./ILiquidAccountVault.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface IERC6551Registry {
    function account(
        address implementation,
        bytes32 salt,
        uint256 chainId,
        address tokenContract,
        uint256 tokenId
    ) external view returns (address);
}

interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

contract LiquidAccountVault is ILiquidAccountVault {
    // ──────────────────────────────────────────────
    // Metadata
    // ──────────────────────────────────────────────

    string public name;
    string public symbol;
    string public baseURI;
    /// @notice ERC-7572 contract-level metadata (collection name, image, banner, links) for marketplaces.
    ///         Empty until the owner sets it. Display only: nothing in the vault reads it.
    string public contractURI;
    /// @notice True after the owner froze the collection info for good.
    bool public contractURIFrozen;
    /// @dev Upper bound on the stored contract URI, in bytes.
    uint256 internal constant MAX_CONTRACT_URI_BYTES = 4096;
    address public descriptor;
    /// @notice Card color palette the owner has chosen for NEW receipts (0 = canonical gold). Display only.
    uint8 public palette;
    /// @notice Palette stamped on a receipt when it was minted (0 = canonical gold). Never changes afterwards. Display only.
    mapping(uint256 => uint8) public receiptPalette;

    // ──────────────────────────────────────────────
    // Immutable config
    // ──────────────────────────────────────────────

    address public immutable override stakingToken;
    address public immutable override yieldToken;
    address public immutable override protocolTreasury;
    address public immutable override creator;
    address public immutable override factory;

    /// @dev 10^(18 - yieldDecimals)
    uint256 public immutable yieldScale;

    address public immutable erc6551Registry;
    address public immutable erc6551Implementation;

    // ──────────────────────────────────────────────
    // Constants
    // ──────────────────────────────────────────────

    uint256 public constant TAX_PROTOCOL_SHARE_BPS = 1_000; // 10% of tax -> treasury
    uint256 public constant YIELD_PROTOCOL_FEE_BPS = 1_000; // 10% performance fee on yield -> treasury

    uint256 public constant RAGEQUIT_BURN_BPS = 500;        // 5% body burn
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant ACC_PRECISION = 1e18;
    uint256 public constant SHARE_OFFSET = 1e6;
    /// @notice r7: staker yield is released evenly over this period.
    uint256 public constant STREAM_DURATION = 1 days;
    /// @dev Extra precision of rewardRate so division remainders are not lost.
    uint256 internal constant RATE_PRECISION = 1e18;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    /// @dev Calls that must never block a deposit, a claim or an exit (the yield token's `balanceOf` and `transfer`,
    ///      and the burn transfer) get a fixed gas amount and return at most 32 bytes. A hostile token then can neither
    ///      use up the gas of the caller nor make it copy a huge return value (a "returndata bomb").
    uint256 internal constant TOKEN_VIEW_GAS = 100_000;
    uint256 internal constant TOKEN_XFER_GAS = 500_000;

    // ──────────────────────────────────────────────
    // Admin (cosmetic only — no pause, no fee control)
    // ──────────────────────────────────────────────

    address public owner;

    // ──────────────────────────────────────────────
    // Accounting
    // ──────────────────────────────────────────────

    uint256 public nextTokenId = 1;
    uint256 public override totalShares;
    uint256 public override totalBody;
    uint256 public override accYieldPerShare;
    uint256 public override accountedYieldBalance;
    uint256 public protocolYieldOwed;

    // r7 streaming state (Engine 2 only; Engine 1 / tax body stays discrete)
    /// @notice Yield units per second, scaled by yieldScale * RATE_PRECISION.
    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;

    // event YieldPayoutFailed is declared in ILiquidAccountVault

    uint256 public totalTaxReceived;
    uint256 public totalTaxToBody;
    uint256 public totalTaxToProtocol;
    uint256 public totalYieldDistributed;
    uint256 public totalYieldToProtocol;
    uint256 public totalBurned;
    /// @notice Staking tokens that should have been burned but could not be sent to the burn address. Locked forever.
    uint256 public lockedBurn;

    struct Position {
        uint256 shares;
        uint256 rewardDebt;
        uint256 pendingYield;
        uint256 depositTimestamp;
        uint256 initialDeposit;
    }

    mapping(uint256 => Position) internal _positions;

    // ──────────────────────────────────────────────
    // ERC-721
    // ──────────────────────────────────────────────

    mapping(uint256 => address) internal _owners;
    mapping(address => uint256) internal _balances;
    mapping(uint256 => address) internal _tokenApprovals;
    mapping(address => mapping(address => bool)) internal _operatorApprovals;

    // ──────────────────────────────────────────────
    // Reentrancy
    // ──────────────────────────────────────────────

    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ──────────────────────────────────────────────
    // Events (ERC-721)
    // ──────────────────────────────────────────────

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    /// @dev ERC-7572: tells marketplaces to read contractURI() again.
    event ContractURIUpdated();
    /// @dev The owner froze the collection info; contractURI can never change again.
    event ContractURIFrozen();
    /// @dev ERC-4906: Metadata Update events for automatic OpenSea re-indexing
    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    /// @dev The staking token refused the 5% transfer to the burn address. The amount stays in the vault, locked
    ///      for good (`lockedBurn`): it is not income, not body, and nobody can take it. The exit itself is not blocked.
    event BurnTransferFailed(uint256 indexed tokenId, uint256 amount);
    // ──────────────────────────────────────────────
    // Modifiers
    // ──────────────────────────────────────────────

    modifier nonReentrant() {
        require(_status != _ENTERED, "Reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not vault owner");
        _;
    }

    // ──────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────

    constructor(
        address _stakingToken,
        address _yieldToken,
        string memory _name,
        string memory _symbol,
        address _creator,
        address _protocolTreasury,
        address _erc6551Registry,
        address _erc6551Implementation
    ) {
        require(_stakingToken != address(0), "Zero staking token");
        require(_yieldToken != address(0), "Zero yield token");
        require(_stakingToken != _yieldToken, "Identical tokens");
        require(_creator != address(0), "Zero creator");
        require(_protocolTreasury != address(0), "Zero treasury");

        stakingToken = _stakingToken;
        yieldToken = _yieldToken;
        protocolTreasury = _protocolTreasury;
        creator = _creator;
        owner = _creator;
        factory = msg.sender;

        erc6551Registry = _erc6551Registry;
        erc6551Implementation = _erc6551Implementation;

        name = _name;
        symbol = _symbol;
        _status = _NOT_ENTERED;

        uint8 yDec = 18;
        try IERC20(_yieldToken).decimals() returns (uint8 d) {
            yDec = d;
        } catch {}
        require(yDec <= 18, "Yield decimals > 18");
        yieldScale = 10 ** (18 - yDec);
    }

    // ──────────────────────────────────────────────
    // Engine 1: Deposits & Body Growth
    // ──────────────────────────────────────────────

    function deposit(uint256 amount) external override returns (uint256 tokenId) {
        return depositTo(amount, msg.sender);
    }

    function depositTo(uint256 amount, address recipient)
        public
        override
        nonReentrant
        returns (uint256 tokenId)
    {
        require(recipient != address(0), "Zero recipient");
        require(amount > 0, "Zero amount");

        _syncYieldInternal();

        if (totalShares == 0) {
            uint256 strayBal = IERC20(stakingToken).balanceOf(address(this));
            uint256 stray = strayBal > lockedBurn ? strayBal - lockedBurn : 0;
            if (stray > 0) {
                _sweepEarlyTax(stray);
            }
        }

        uint256 balBefore = IERC20(stakingToken).balanceOf(address(this));
        _safeTransferFrom(stakingToken, msg.sender, address(this), amount);
        uint256 received = IERC20(stakingToken).balanceOf(address(this)) - balBefore;
        require(received > 0, "No tokens received");

        uint256 shares;
        if (totalShares == 0) {
            shares = received;
        } else {
            shares = (received * (totalShares + SHARE_OFFSET)) / (totalBody + SHARE_OFFSET);
        }
        require(shares > 0, "Zero shares minted");

        tokenId = nextTokenId++;
        _mint(recipient, tokenId);
        if (palette != 0) receiptPalette[tokenId] = palette;

        _positions[tokenId] = Position({
            shares: shares,
            rewardDebt: (shares * accYieldPerShare) / ACC_PRECISION,
            pendingYield: 0,
            depositTimestamp: block.timestamp,
            initialDeposit: received
        });

        totalShares += shares;
        totalBody += received;

        emit Deposited(recipient, tokenId, received, shares);
    }

    function receiveTaxBody(uint256 amount) external override nonReentrant {
        if (amount == 0) return;

        if (totalShares == 0) {
            uint256 protocolFee = (amount * TAX_PROTOCOL_SHARE_BPS) / BPS_DENOMINATOR;
            uint256 projectShare = amount - protocolFee;
            if (protocolFee > 0) {
                _safeTransferFrom(stakingToken, msg.sender, protocolTreasury, protocolFee);
            }
            if (projectShare > 0) {
                address recipient = owner;
                if (recipient == address(0)) {
                    recipient = protocolTreasury;
                }
                (bool success, bytes memory data) = stakingToken.call(
                    abi.encodeWithSelector(IERC20.transferFrom.selector, msg.sender, recipient, projectShare)
                );
                bool transferred = success && (data.length == 0 || abi.decode(data, (bool)));
                if (!transferred) {
                    _safeTransferFrom(stakingToken, msg.sender, protocolTreasury, projectShare);
                }
            }
            emit TaxSweptEarly(projectShare, protocolFee);
            return;
        }

        uint256 balBefore = IERC20(stakingToken).balanceOf(address(this));
        _safeTransferFrom(stakingToken, msg.sender, address(this), amount);
        uint256 received = IERC20(stakingToken).balanceOf(address(this)) - balBefore;
        if (received == 0) return;

        _processTax(received);
    }

    function notifyTaxBody() external override nonReentrant {
        uint256 currentBalance = IERC20(stakingToken).balanceOf(address(this));
        if (currentBalance <= totalBody + lockedBurn) return;
        uint256 excess = currentBalance - totalBody - lockedBurn;

        if (totalShares == 0) {
            _sweepEarlyTax(excess);
            return;
        }

        _processTax(excess);
    }

    function _sweepEarlyTax(uint256 amount) internal {
        if (amount == 0) return;
        uint256 protocolFee = (amount * TAX_PROTOCOL_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 projectShare = amount - protocolFee;

        if (protocolFee > 0) {
            _safeTransfer(stakingToken, protocolTreasury, protocolFee);
        }

        if (projectShare > 0) {
            address recipient = owner;
            if (recipient == address(0)) {
                recipient = protocolTreasury;
            }
            (bool success, bytes memory data) = stakingToken.call(
                abi.encodeWithSelector(IERC20.transfer.selector, recipient, projectShare)
            );
            bool transferred = success && (data.length == 0 || abi.decode(data, (bool)));
            if (!transferred) {
                _safeTransfer(stakingToken, protocolTreasury, projectShare);
            }
        }

        emit TaxSweptEarly(projectShare, protocolFee);
    }

    function _processTax(uint256 received) internal {
        uint256 protocolShare = (received * TAX_PROTOCOL_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 bodyShare = received - protocolShare;

        totalTaxReceived += received;
        totalTaxToBody += bodyShare;
        totalTaxToProtocol += protocolShare;
        totalBody += bodyShare;

        if (protocolShare > 0) {
            _safeTransfer(stakingToken, protocolTreasury, protocolShare);
        }

        emit TaxBodyReceived(received, bodyShare, protocolShare, totalBody);

        // ERC-4906: notify OpenSea to auto-refresh all token metadata & cards
        if (nextTokenId > 1) {
            emit BatchMetadataUpdate(1, nextTokenId - 1);
        }
    }

    // ──────────────────────────────────────────────
    // Engine 2: Yield
    // ──────────────────────────────────────────────

    function distributeYield(uint256 amount) external override nonReentrant {
        require(amount > 0, "Zero yield amount");

        _syncYieldInternal();

        uint256 balBefore = IERC20(yieldToken).balanceOf(address(this));
        _safeTransferFrom(yieldToken, msg.sender, address(this), amount);
        uint256 received = IERC20(yieldToken).balanceOf(address(this)) - balBefore;
        require(received > 0, "No yield tokens received");

        _processYield(received);
    }

    function syncYield() external override nonReentrant {
        _syncYieldInternal();
    }

    function _syncYieldInternal() internal {
        _updateStream();

        (bool okBal, uint256 currentBal) = _boundedBalanceOf(yieldToken, address(this));
        if (!okBal) return;
        if (currentBal <= accountedYieldBalance) return;
        uint256 received = currentBal - accountedYieldBalance;

        // r7: with no stakers the yield is not swept to the owner. It enters the stream and the
        // stream clock stays frozen (rollover) until the first staker enters.
        _processYield(received);
    }

    /// @dev Brings accYieldPerShare up to now. While there are no shares the clock is frozen:
    ///      the running stream is pushed back by the elapsed time, nothing is accrued or lost.
    function _updateStream() internal {
        uint256 last = lastUpdateTime;
        if (last == block.timestamp) return;
        if (rewardRate != 0) {
            if (totalShares == 0) {
                if (periodFinish > last) periodFinish += block.timestamp - last;
            } else {
                accYieldPerShare = _currentAcc();
            }
        }
        lastUpdateTime = block.timestamp;
    }

    /// @dev accYieldPerShare as of now, without writing state.
    function _currentAcc() internal view returns (uint256 acc) {
        acc = accYieldPerShare;
        if (rewardRate == 0 || totalShares == 0) return acc;
        uint256 t = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (t > lastUpdateTime) {
            acc += (rewardRate * (t - lastUpdateTime) * ACC_PRECISION) / (RATE_PRECISION * totalShares);
        }
    }

    function currentAccYieldPerShare() external view returns (uint256) {
        return _currentAcc();
    }

    /// @notice Yield (in yield-token units) received but not yet released to stakers.
    function unstreamedYield() external view returns (uint256) {
        if (rewardRate == 0) return 0;
        uint256 remainingTime;
        if (totalShares == 0) {
            remainingTime = periodFinish > lastUpdateTime ? periodFinish - lastUpdateTime : 0;
        } else {
            remainingTime = periodFinish > block.timestamp ? periodFinish - block.timestamp : 0;
        }
        return (rewardRate * remainingTime) / RATE_PRECISION / yieldScale;
    }

    /// @dev Pays the treasury; if the yield token refuses, keeps the amount in the vault as
    ///      "owed" (already counted in accountedYieldBalance, so it is never re-distributed)
    ///      and lets anyone push it later with sweepProtocolYield().
    function _payTreasuryYield(uint256 amount) internal {
        if (amount == 0) return;
        if (!_tryTransfer(yieldToken, protocolTreasury, amount)) {
            protocolYieldOwed += amount;
            accountedYieldBalance += amount;
        }
    }

    function sweepProtocolYield() external nonReentrant {
        uint256 a = protocolYieldOwed;
        if (a == 0) return;
        protocolYieldOwed = 0;
        accountedYieldBalance -= a;
        _safeTransfer(yieldToken, protocolTreasury, a);
    }

    /// @dev `token.balanceOf(who)` with a gas cap and at most 32 bytes of return data. `ok` is false if the call
    ///      failed or returned less than 32 bytes.
    function _boundedBalanceOf(address token, address who) internal view returns (bool ok, uint256 bal) {
        uint256 g = TOKEN_VIEW_GAS;
        bytes4 sel = IERC20.balanceOf.selector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, sel)
            mstore(add(ptr, 4), who)
            let success := staticcall(g, token, ptr, 36, ptr, 32)
            ok := and(success, iszero(lt(returndatasize(), 32)))
            if ok { bal := mload(ptr) }
        }
    }

    /// @dev `token.transfer(to, amount)` with a gas cap and at most 32 bytes of return data. True if the call
    ///      succeeded and returned nothing or `true` (a value other than 1 counts as failure).
    function _tryTransfer(address token, address to, uint256 amount) internal returns (bool good) {
        uint256 g = TOKEN_XFER_GAS;
        bytes4 sel = IERC20.transfer.selector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, sel)
            mstore(add(ptr, 4), to)
            mstore(add(ptr, 36), amount)
            let success := call(g, token, 0, ptr, 68, ptr, 32)
            let rs := returndatasize()
            good := and(success, or(iszero(rs), and(iszero(lt(rs, 32)), eq(mload(ptr), 1))))
        }
    }

    function _processYield(uint256 received) internal {
        uint256 protocolFee = (received * YIELD_PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 stakerYield = received - protocolFee;

        totalYieldDistributed += received;
        totalYieldToProtocol += protocolFee;
        accountedYieldBalance += stakerYield;

        // Stream: whatever is still unreleased is merged with the new amount and spread over a fresh period.
        // _updateStream() has run in this transaction, so lastUpdateTime == block.timestamp.
        uint256 remaining = periodFinish > block.timestamp ? rewardRate * (periodFinish - block.timestamp) : 0;
        rewardRate = (stakerYield * yieldScale * RATE_PRECISION + remaining) / STREAM_DURATION;
        periodFinish = block.timestamp + STREAM_DURATION;
        lastUpdateTime = block.timestamp;

        _payTreasuryYield(protocolFee);

        emit YieldDistributed(received, stakerYield, protocolFee, accYieldPerShare);
        emit YieldStreamed(received, stakerYield, protocolFee, rewardRate, periodFinish);

        // ERC-4906: notify OpenSea to auto-refresh all token metadata & cards
        if (nextTokenId > 1) {
            emit BatchMetadataUpdate(1, nextTokenId - 1);
        }
    }

    function claimYield(uint256 tokenId) public override nonReentrant returns (uint256 payout) {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not owner or approved");

        _syncYieldInternal();

        payout = _updatePositionYield(tokenId);
        if (payout == 0) return 0;

        _positions[tokenId].pendingYield = 0;
        if (accountedYieldBalance >= payout) {
            accountedYieldBalance -= payout;
        } else {
            accountedYieldBalance = 0;
        }
        _safeTransfer(yieldToken, msg.sender, payout);

        emit YieldClaimed(tokenId, msg.sender, payout);
    }

    // ──────────────────────────────────────────────
    // Exit: 95/5 ragequit (always available)
    // ──────────────────────────────────────────────

    function ragequit(uint256 tokenId)
        external
        override
        nonReentrant
        returns (uint256 bodyPayout, uint256 yieldPayout)
    {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not owner or approved");

        _syncYieldInternal();

        yieldPayout = _updatePositionYield(tokenId);
        _positions[tokenId].pendingYield = 0;

        Position memory pos = _positions[tokenId];
        require(pos.shares > 0, "Empty position");
        require(totalShares > 0, "No shares");

        uint256 grossBody = (pos.shares * totalBody) / totalShares;
        uint256 burnAmount = (grossBody * RAGEQUIT_BURN_BPS) / BPS_DENOMINATOR;
        bodyPayout = grossBody - burnAmount;

        totalShares -= pos.shares;
        totalBody -= grossBody;

        delete _positions[tokenId];
        _burn(tokenId);

        uint256 burned;
        if (burnAmount > 0) {
            if (_tryTransfer(stakingToken, BURN_ADDRESS, burnAmount)) {
                burned = burnAmount;
                totalBurned += burnAmount;
            } else {
                lockedBurn += burnAmount;
                emit BurnTransferFailed(tokenId, burnAmount);
            }
        }
        if (bodyPayout > 0) {
            _safeTransfer(stakingToken, msg.sender, bodyPayout);
        }
        if (yieldPayout > 0) {
            if (_tryTransfer(yieldToken, msg.sender, yieldPayout)) {
                if (accountedYieldBalance >= yieldPayout) {
                    accountedYieldBalance -= yieldPayout;
                } else {
                    accountedYieldBalance = 0;
                }
            } else {
                emit YieldPayoutFailed(tokenId, msg.sender, yieldPayout);
                yieldPayout = 0;
            }
        }

        emit Ragequitted(tokenId, msg.sender, bodyPayout, burned, yieldPayout);
    }

    // ──────────────────────────────────────────────
    // Internal accounting
    // ──────────────────────────────────────────────

    function _updatePositionYield(uint256 tokenId) internal returns (uint256 totalClaimable) {
        Position storage pos = _positions[tokenId];
        uint256 accumulated = (pos.shares * accYieldPerShare) / ACC_PRECISION;
        uint256 pending = 0;
        if (accumulated > pos.rewardDebt) {
            pending = (accumulated - pos.rewardDebt) / yieldScale;
        }
        totalClaimable = pos.pendingYield + pending;
        pos.rewardDebt = accumulated;
        pos.pendingYield = totalClaimable;
    }

    // ──────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────

    function bodyOf(uint256 tokenId) public view override returns (uint256) {
        if (!_exists(tokenId) || totalShares == 0) return 0;
        return (_positions[tokenId].shares * totalBody) / totalShares;
    }

    function pendingYieldOf(uint256 tokenId) external view override returns (uint256) {
        if (!_exists(tokenId)) return 0;
        Position memory pos = _positions[tokenId];
        uint256 accumulated = (pos.shares * _currentAcc()) / ACC_PRECISION;
        uint256 pending = 0;
        if (accumulated > pos.rewardDebt) {
            pending = (accumulated - pos.rewardDebt) / yieldScale;
        }
        return pos.pendingYield + pending;
    }

    function positionOf(uint256 tokenId)
        external
        view
        override
        returns (
            uint256 shares,
            uint256 currentBody,
            uint256 claimableYield,
            uint256 initialDeposit,
            uint256 depositTimestamp
        )
    {
        if (!_exists(tokenId)) return (0, 0, 0, 0, 0);
        Position memory pos = _positions[tokenId];
        shares = pos.shares;
        currentBody = bodyOf(tokenId);

        uint256 accumulated = (pos.shares * _currentAcc()) / ACC_PRECISION;
        uint256 pending = 0;
        if (accumulated > pos.rewardDebt) {
            pending = (accumulated - pos.rewardDebt) / yieldScale;
        }
        claimableYield = pos.pendingYield + pending;
        initialDeposit = pos.initialDeposit;
        depositTimestamp = pos.depositTimestamp;
    }

    function tbaOf(uint256 tokenId) public view override returns (address) {
        if (!_exists(tokenId) || erc6551Registry == address(0) || erc6551Implementation == address(0)) {
            return address(0);
        }
        return IERC6551Registry(erc6551Registry).account(
            erc6551Implementation,
            bytes32(0),
            block.chainid,
            address(this),
            tokenId
        );
    }

    // ──────────────────────────────────────────────
    // ERC-165
    // ──────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC165
            || interfaceId == 0x80ac58cd // ERC721
            || interfaceId == 0x5b5e139f // ERC721Metadata
            || interfaceId == 0x49064906; // ERC4906 MetadataUpdate (OpenSea auto-refresh)
    }

    // ──────────────────────────────────────────────
    // ERC-721
    // ──────────────────────────────────────────────

    function balanceOf(address owner_) external view returns (uint256) {
        require(owner_ != address(0), "Zero address");
        return _balances[owner_];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address o = _owners[tokenId];
        require(o != address(0), "Nonexistent token");
        return o;
    }

    function approve(address to, uint256 tokenId) external {
        address o = ownerOf(tokenId);
        require(msg.sender == o || _operatorApprovals[o][msg.sender], "Not authorized");
        _tokenApprovals[tokenId] = to;
        emit Approval(o, to, tokenId);
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        require(_exists(tokenId), "Nonexistent token");
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) external {
        require(operator != msg.sender, "Approve to caller");
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address owner_, address operator) external view returns (bool) {
        return _operatorApprovals[owner_][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not approved or owner");
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        require(_checkOnERC721Received(from, to, tokenId, data), "Non ERC721Receiver");
    }

    function setDescriptor(address newDescriptor) external onlyOwner {
        descriptor = newDescriptor;
        emit MetadataUpdate(0);
        emit BatchMetadataUpdate(1, type(uint256).max);
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        require(_exists(tokenId), "Nonexistent token");
        if (descriptor != address(0)) {
            (bool success, bytes memory data) = descriptor.staticcall(
                abi.encodeWithSignature("tokenURI(address,uint256)", address(this), tokenId)
            );
            if (success && data.length > 0) {
                return abi.decode(data, (string));
            }
        }
        if (bytes(baseURI).length == 0) return "";
        return string(abi.encodePacked(baseURI, _toString(tokenId)));
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return _owners[tokenId] != address(0);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address o = ownerOf(tokenId);
        return (
            spender == o
                || _tokenApprovals[tokenId] == spender
                || _operatorApprovals[o][spender]
        );
    }

    function _mint(address to, uint256 tokenId) internal {
        _owners[tokenId] = to;
        _balances[to] += 1;
        emit Transfer(address(0), to, tokenId);
    }

    function _burn(uint256 tokenId) internal {
        address o = ownerOf(tokenId);
        delete _tokenApprovals[tokenId];
        _balances[o] -= 1;
        delete _owners[tokenId];
        emit Transfer(o, address(0), tokenId);
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        require(ownerOf(tokenId) == from, "Wrong from");
        require(to != address(0), "Zero to");

        delete _tokenApprovals[tokenId];
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;

        emit Transfer(from, to, tokenId);
    }

    function _checkOnERC721Received(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) internal returns (bool) {
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
                return retval == IERC721Receiver.onERC721Received.selector;
            } catch {
                return false;
            }
        }
        return true;
    }

    // ──────────────────────────────────────────────
    // Safe transfers
    // ──────────────────────────────────────────────

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TransferFrom failed");
    }

    // ──────────────────────────────────────────────
    // Admin (cosmetic only)
    // ──────────────────────────────────────────────

    function setBaseURI(string memory _newURI) external onlyOwner {
        baseURI = _newURI;
        emit BaseURIUpdated(_newURI);
    }

    /// @notice Set the collection info shown by marketplaces (ERC-7572 JSON: name, description, image,
    ///         banner_image, external_link). Owner only, display only, impossible after freezeContractURI().
    function setContractURI(string calldata newURI) external onlyOwner {
        require(!contractURIFrozen, "Collection info frozen");
        require(bytes(newURI).length <= MAX_CONTRACT_URI_BYTES, "Contract URI too long");
        contractURI = newURI;
        emit ContractURIUpdated();
    }

    /// @notice Choose the card color palette for receipts minted from now on. Receipts already minted keep their color.
    ///         Owner only, display only, impossible after freezeContractURI().
    function setPalette(uint8 index) external onlyOwner {
        require(!contractURIFrozen, "Collection info frozen");
        palette = index;
    }

    /// @notice Lock the collection info for good. Cannot be undone.
    function freezeContractURI() external onlyOwner {
        require(!contractURIFrozen, "Collection info frozen");
        contractURIFrozen = true;
        emit ContractURIFrozen();
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero new owner");
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
