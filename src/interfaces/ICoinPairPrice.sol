// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/**
 * @title ICoinPairPrice
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice MoC BTC/USD oracle surface. BitChill calls `getPriceInfo` to build Uniswap `amountOutMinimum`.
 * @dev Third-party ABI copied from Money on Chain. Do not treat this as a BitChill-owned interface;
 *      function-level comments below are the vendor's.
 */
interface ICoinPairPrice {
    // getOracleOwnerAddress: Given an Oracle address return the Oracle Owner address.
    // Used during publication, the servers sign with the oracle address, but the list of selected oracles
    // is by oracle owner address.
    // getOracleOwnerStake: Get the stake stored in the supporters smart-contract
    // prettier-ignore
    struct CoinPairPriceCallbacks {
        function (address) external view returns (address) getOracleOwnerAddress;
        function (address) external view returns (uint256) getOracleOwnerStake;
    }

    /// @notice subscribe an oracle to this coin pair, allowing it to be selected in the next round.
    /// If the subscribed list is full and the current oracle has more stake than one with minimum stake in the
    /// subscribed list, then the one with minimum stake is replaced.
    /// @param oracleOwnerAddr The address of the owner of the oracle to remove from system.
    /// @dev This is designed to be called from OracleManager.
    function subscribe(address oracleOwnerAddr) external;

    /// @notice Unsubscribe an oracle from this coin pair. The oracle won't be selected in the next round.
    /// After the round end, the oracle can withdraw stake without having the risk of loosing won points.
    /// @param oracleOwnerAddr The address of the owner of the oracle to remove from system.
    /// @dev This is designed to be called from OracleManager.
    function unsubscribe(address oracleOwnerAddr) external;

    /// @notice Returns true if an oracle is subscribed to this contract' coin pair
    /// @param oracleOwnerAddr The address of the owner of the oracle to remove from system.
    /// @dev This is designed to be called from OracleManager.
    function isSubscribed(address oracleOwnerAddr) external view returns (bool);

    /// @notice Publish a price. (The message contain oracleAddresses that must be converted to owner addresses).
    /// @param _version Version number of message format (3)
    /// @param _coinpair The coin pair to report (must match this contract)
    /// @param _price Price to report.
    /// @param _votedOracle The address of the oracle voted as a publisher by the network.
    /// @param _blockNumber The block number acting as nonce to prevent replay attacks.
    /// @param _sigV The array of V-component of Oracle signatures.
    /// @param _sigR The array of R-component of Oracle signatures.
    /// @param _sigS The array of S-component of Oracle signatures.
    function publishPrice(
        uint256 _version,
        bytes32 _coinpair,
        uint256 _price,
        address _votedOracle,
        uint256 _blockNumber,
        uint8[] calldata _sigV,
        bytes32[] calldata _sigR,
        bytes32[] calldata _sigS
    ) external;

    /// @notice Publish a price without signature validation (when there is an emergecy!!!).
    /// @param _price Price to report.
    function emergencyPublish(uint256 _price) external;

    /// @notice The oracle owner has withdrawn some stake.
    /// Must check if the oracle is part of current round and if he lost his place with the
    /// new stake value (the stake is global and is saved in the supporters contract).
    /// @param oracleOwnerAddr the oracle owner that is trying to withdraw
    function onWithdraw(address oracleOwnerAddr) external returns (uint256);

    /// @notice Switch contract context to a new round. With the objective of
    /// being a decentralized solution, this can be called by *anyone* if current
    /// round lock period is expired.
    /// This method search the subscribed list and choose the 10 with more stake.
    function switchRound() external;

    //////////////////////////////////////////////////////////////////////////////////// GETTERS

    /// @notice Return the available reward fees
    ///
    function getAvailableRewardFees() external view returns (uint256);

    //////////////////////////////////////////////////////////////////////////////////// GETTERS TO GET CURRENT PRICE
    // MUST BE WHITELISTED
    /// @notice Return the current price, compatible with old MOC Oracle
    function peek() external view returns (bytes32, bool);

    /// @notice Return the current price
    function getPrice() external view returns (uint256);

    /// @notice Return the current price with validity information
    /// @return price The current price
    /// @return isValid Whether the price is valid and up-to-date
    /// @return lastPubBlock The block number when the price was last updated
    function getPriceInfo() external view returns (uint256 price, bool isValid, uint256 lastPubBlock);

    ///////////////////////////////////////////////////////////////////////////////// GETTERS TO GET CURRENT PRICE END

    /// @notice Return current round information
    function getRoundInfo()
        external
        view
        returns (
            uint256 round,
            uint256 startBlock,
            uint256 lockPeriodTimestamp,
            uint256 totalPoints,
            address[] memory selectedOwners,
            address[] memory selectedOracles
        );

    /// @notice Return round information for specific oracle
    function getOracleRoundInfo(address addr) external view returns (uint256 points, bool selectedInCurrentRound);

    // The maximum count of oracles selected to participate each round
    function maxOraclesPerRound() external view returns (uint256);

    // The round lock period in secs
    function roundLockPeriodSecs() external view returns (uint256);

    function isOracleInCurrentRound(address oracleAddr) external view returns (bool);

    /// @notice Returns the amount of oracles subscribed to this coin pair.
    function getSubscribedOraclesLen() external view returns (uint256);

    /// @notice Returns the oracle owner address that is subscribed to this coin pair
    /// @param idx index to query.
    function getSubscribedOracleAtIndex(uint256 idx) external view returns (address ownerAddr);

    // Public variable
    function getMaxSubscribedOraclesPerRound() external view returns (uint256);

    // Public variable
    function getCoinPair() external view returns (bytes32);

    // Public variable
    function getLastPublicationBlock() external view returns (uint256);

    // Public variable
    function getValidPricePeriodInBlocks() external view returns (uint256);

    // Public variable
    function getEmergencyPublishingPeriodInBlocks() external view returns (uint256);

    // Public variable
    // function getOracleManager() external view returns (IOracleManager);

    // Public variable
    function getToken() external view returns (IERC20);

    // function getRegistry() external view returns (IRegistry);

    // Public value from Registry:
    //   The minimum count of oracles selected to participate each round
    function getMinOraclesPerRound() external view returns (uint256);
}
