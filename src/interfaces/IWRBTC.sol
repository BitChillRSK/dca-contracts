// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

/**
 * @title IWRBTC
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Wrapped rBTC surface BitChill uses on the Uniswap purchase path.
 * @dev Third-party ABI. Dex handlers unwrap to native rBTC before paying the signer.
 */
interface IWRBTC {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event Approval(address indexed src, address indexed guy, uint256 wad);
    event Transfer(address indexed src, address indexed dst, uint256 wad);
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function totalSupply() external view returns (uint256);
    function approve(address guy, uint256 wad) external returns (bool);
    function transfer(address dst, uint256 wad) external returns (bool);
    function transferFrom(address src, address dst, uint256 wad) external returns (bool);
}
