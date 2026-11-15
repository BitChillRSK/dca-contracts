// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.36;

/**
 * @title IWRBTC
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Wrapped rBTC surface BitChill uses on the Uniswap purchase path.
 * @dev Third-party ABI. Dex handlers unwrap to native rBTC before paying the signer.
 */
interface IWRBTC {
    function withdraw(uint256 wad) external;
}
