// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IStablecoin
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Mintable ERC-20 subset used by test mocks. Not a production token ABI.
 */
interface IStablecoin {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
}
