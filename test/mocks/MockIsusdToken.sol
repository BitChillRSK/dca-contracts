// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IStablecoin} from "../../src/interfaces/IStablecoin.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {console} from "forge-std/Test.sol";

contract MockIsusdToken is ERC20, ERC20Burnable, Ownable, ERC20Permit {
    IStablecoin immutable i_docToken;
    uint256 constant DECIMALS = 1e18;
    uint256 constant STARTING_EXCHANGE_RATE = 2 * DECIMALS / 100; // Each DOC token deposited mints 50 iSUSD tokens, each iSUSD token redeems 0.02 DOC tokens
    uint256 immutable i_deploymentTimestamp;
    uint256 constant ANNUAL_INCREASE = 5; // The DOC tokens redeemed by each iSUSD token increase by 5% annually (mocking behaviour)
    uint256 constant YEAR_IN_SECONDS = 31536000;

    constructor(address docTokenAddress) ERC20("Tropykus iSUSD", "iSUSD") Ownable() ERC20Permit("Tropykus iSUSD") {
        i_docToken = IStablecoin(docTokenAddress);
        i_deploymentTimestamp = block.timestamp;
    }

    function mint(address receiver, uint256 depositAmount) external returns (uint256 mintAmount) {
        require(i_docToken.allowance(msg.sender, address(this)) >= depositAmount, "Insufficient allowance");
        i_docToken.transferFrom(msg.sender, address(this), depositAmount); // Deposit DOC into Tropykus
        mintAmount = depositAmount * DECIMALS / tokenPrice(); //  Mint iSUSD to user that deposited DOC (in our case, the DocHandler contract)
        _mint(receiver, mintAmount);
        return mintAmount;
    }

    /**
     * @dev This function is used to withdraw DOC from the Sovryn protocol, burning the corresponding iSUSD
     * @param receiver The account getting the redeemed DOC tokens.
     * @param burnAmount The amount of iSUSD to burn.
     */
    function burn(address receiver, uint256 burnAmount) external returns (uint256 loanAmountPaid) {
        require(balanceOf(msg.sender) >= burnAmount, "Insufficient balance");
        loanAmountPaid = Math.ceilDiv(burnAmount * tokenPrice(), DECIMALS);
        i_docToken.transfer(receiver, loanAmountPaid);
        _burn(msg.sender, burnAmount);
        return loanAmountPaid;
    }

    /**
     * @dev Returns the current exchange rate between DOC and iSUSD.
     * @notice Calculates the exchange rate from the underlying DOC to iSusd
     * @return price of iSusd/DOC
     */
    function tokenPrice() public view returns (uint256 price) {
        uint256 timeElapsed = block.timestamp - i_deploymentTimestamp; // Time elapsed since deployment in seconds
        uint256 yearsElapsed = (timeElapsed * DECIMALS) / YEAR_IN_SECONDS; // Convert timeElapsed to years with 18 decimals

        // Calculate the rate increase: STARTING_EXCHANGE_RATE * ANNUAL_INCREASE * yearsElapsed
        // Divide by 100 for the percentage and by DECIMALS (1e18) to adjust for the extra decimals on yearsElapsed
        uint256 exchangeRateIncrease = (STARTING_EXCHANGE_RATE * ANNUAL_INCREASE * yearsElapsed) / (100 * DECIMALS);

        return STARTING_EXCHANGE_RATE + exchangeRateIncrease; // Current exchange rate
    }

    /**
     * @notice Get the initially deposited amount of DOC
     * @return The user's initial balance of underlying token.
     *
     */
    function assetBalanceOf(address _owner) public view returns (uint256) {
        return balanceOf(_owner) * STARTING_EXCHANGE_RATE / DECIMALS;
    }

    /**
     * @notice Wrapper for internal _profitOf low level function.
     * @param user The user address.
     * @return The profit of a user.
     *
     */
    function profitOf(address user) external view returns (int256) {
        uint256 initialDocBalance = assetBalanceOf(user);
        uint256 currentDocBalance = balanceOf(user) * tokenPrice() / DECIMALS;
        return int256(currentDocBalance) - int256(initialDocBalance);
    }
}
