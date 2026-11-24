// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/**
 * @title ILiquidAccountVault
 * @notice Interface for the lavNFT Liquid Account Vault standard.
 *
 * All rights reserved.
 */
interface ILiquidAccountVault {
    function stakingToken() external view returns (address);
    function yieldToken() external view returns (address);
    function protocolTreasury() external view returns (address);
    function creator() external view returns (address);
    function factory() external view returns (address);

    function totalShares() external view returns (uint256);
    function totalBody() external view returns (uint256);
    function accYieldPerShare() external view returns (uint256);
    function accountedYieldBalance() external view returns (uint256);

    function deposit(uint256 amount) external returns (uint256 tokenId);
    function depositTo(uint256 amount, address recipient) external returns (uint256 tokenId);
    function receiveTaxBody(uint256 amount) external;
    function notifyTaxBody() external;
    function distributeYield(uint256 amount) external;
    function syncYield() external;
    function claimYield(uint256 tokenId) external returns (uint256 payout);
    function sweepProtocolYield() external;

    // r7 streaming views
    function rewardRate() external view returns (uint256);
    function periodFinish() external view returns (uint256);
    function lastUpdateTime() external view returns (uint256);
    function unstreamedYield() external view returns (uint256);
    function currentAccYieldPerShare() external view returns (uint256);
    function protocolYieldOwed() external view returns (uint256);
    function ragequit(uint256 tokenId) external returns (uint256 bodyPayout, uint256 yieldPayout);

    function bodyOf(uint256 tokenId) external view returns (uint256);
    function pendingYieldOf(uint256 tokenId) external view returns (uint256);
    function positionOf(uint256 tokenId)
        external
        view
        returns (
            uint256 shares,
            uint256 currentBody,
            uint256 claimableYield,
            uint256 initialDeposit,
            uint256 depositTimestamp
        );
    function tbaOf(uint256 tokenId) external view returns (address);

    event Deposited(
        address indexed recipient,
        uint256 indexed tokenId,
        uint256 amount,
        uint256 shares
    );

    event TaxBodyReceived(
        uint256 received,
        uint256 bodyShare,
        uint256 protocolShare,
        uint256 newTotalBody
    );

    event YieldDistributed(
        uint256 received,
        uint256 stakerYield,
        uint256 protocolFee,
        uint256 newAccYieldPerShare
    );

    event YieldClaimed(
        uint256 indexed tokenId,
        address indexed to,
        uint256 amount
    );

    event YieldPayoutFailed(
        uint256 indexed tokenId,
        address indexed to,
        uint256 amount
    );

    event Ragequitted(
        uint256 indexed tokenId,
        address indexed to,
        uint256 bodyPayout,
        uint256 burnAmount,
        uint256 yieldPayout
    );

    event YieldStreamed(uint256 received, uint256 stakerYield, uint256 protocolFee, uint256 newRate, uint256 newPeriodFinish);
    event TaxSweptEarly(uint256 projectShare, uint256 protocolFee);

    event BaseURIUpdated(string newBaseURI);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
}
