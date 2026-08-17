// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/**
 * @title IiSusdToken
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @dev Interface for the iSusd token contract.
 */
interface IiSusdToken {
    /**
     * @dev This function is used to deposit stablecoin into the Sovryn protocol and get iSusd in exchange
     *
     * @param depositAmount the amount of stablecoin to be deposited
     * @param receiver the receiver of iSusd in return for depositing stablecoin
     * @return mintAmount the amount of iSusd received
     */
    function mint(address receiver, uint256 depositAmount) external returns (uint256 mintAmount);

    /**
     * @dev This function is used to withdraw stablecoin from the Sovryn protocol and give back the corresponding iSusd
     * @param receiver The account getting the redeemed iSusd tokens.
     * @param burnAmount The amount of loan tokens to redeem.
     */
    function burn(address receiver, uint256 burnAmount) external returns (uint256 loanAmountPaid);

    /**
     * @notice Get loan token balance.
     * @return The user's balance of underlying token.
     *
     */
    function assetBalanceOf(address _owner) external view returns (uint256);

    /**
     * @dev Returns the balance of the specified address.
     * @param owner The address to query the balance of.
     * @return The balance of the specified address.
     */
    function balanceOf(address owner) external returns (uint256);

    /**
     * @notice Calculates the exchange rate from the underlying stablecoin to iSusd
     * @return price of iSusd/stablecoin
     */
    function tokenPrice() external view returns (uint256 price);
}
