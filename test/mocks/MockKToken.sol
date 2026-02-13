// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IStablecoin} from "../../src/interfaces/IStablecoin.sol";
import {console} from "forge-std/Test.sol";

contract MockKToken is ERC20, ERC20Burnable, Ownable, ERC20Permit {
    IStablecoin immutable i_stablecoin;
    uint256 constant DECIMALS = 1e18;
    uint256 constant STARTING_EXCHANGE_RATE = 2 * DECIMALS / 100; // Each DOC token deposited mints 50 kDOC tokens, each kDOC token redeems 0.02 DOC tokens
    uint256 immutable i_deploymentTimestamp;
    uint256 constant ANNUAL_INCREASE = 5; // The DOC tokens redeemed by each kDOC token increase by 5% annually (mocking behaviour)
    uint256 constant YEAR_IN_SECONDS = 31536000;

    constructor(address stablecoinAddress) ERC20("Tropykus kToken", "kToken") Ownable() ERC20Permit("Tropykus kToken") {
        i_stablecoin = IStablecoin(stablecoinAddress);
        i_deploymentTimestamp = block.timestamp;
    }

    function mint(uint256 amount) public returns (uint256) {
        require(i_stablecoin.allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");
        i_stablecoin.transferFrom(msg.sender, address(this), amount); // Deposit DOC into Tropykus
        _mint(msg.sender, amount * DECIMALS / exchangeRateCurrent()); //  Mint kDOC to user that deposited DOC (in our case, the DocHandler contract)
        return 0;
    }

    function redeemUnderlying(uint256 amount) public returns (uint256) {
        uint256 kTokenToBurn = amount * DECIMALS / exchangeRateCurrent();
        require(balanceOf(msg.sender) >= kTokenToBurn, "Insufficient balance");
        // Ensure we have enough stablecoin to transfer (mint if needed to simulate yield generation)
        uint256 currentBalance = i_stablecoin.balanceOf(address(this));
        if (currentBalance < amount) {
            // Mint the difference to simulate yield generation from the lending protocol
            IStablecoin(address(i_stablecoin)).mint(address(this), amount - currentBalance);
        }
        i_stablecoin.transfer(msg.sender, amount);
        _burn(msg.sender, kTokenToBurn); // Burn an amount of kDOC equivalent to the amount of DOC divided by the exchange rate (e.g.: 1 DOC redeemed => 1 / 0.02 = 50 kDOC burnt)
        return 0;
    }

    function redeem(uint256 kTokenToBurn) public returns (uint256) {
        uint256 stablecoinToRedeem = kTokenToBurn * exchangeRateCurrent() / DECIMALS;
        require(balanceOf(msg.sender) >= kTokenToBurn, "Insufficient balance");
        // Ensure we have enough stablecoin to transfer (mint if needed to simulate yield generation)
        uint256 currentBalance = i_stablecoin.balanceOf(address(this));
        if (currentBalance < stablecoinToRedeem) {
            // Mint the difference to simulate yield generation from the lending protocol
            IStablecoin(address(i_stablecoin)).mint(address(this), stablecoinToRedeem - currentBalance);
        }
        i_stablecoin.transfer(msg.sender, stablecoinToRedeem);
        _burn(msg.sender, kTokenToBurn); // Burn an amount of kDOC equivalent to the amount of DOC divided by the exchange rate (e.g.: 1 DOC redeemed => 1 / 0.02 = 50 kDOC burnt)
        return 0;
    }

    /**
     * @dev Returns the stored exchange rate between DOC and kDOC.
     * The exchange rate increases linearly over time at 5% per year.
     */
    function exchangeRateStored() public view returns (uint256) {
        uint256 timeElapsed = block.timestamp - i_deploymentTimestamp; // Time elapsed since deployment in seconds
        uint256 yearsElapsed = (timeElapsed * DECIMALS) / YEAR_IN_SECONDS; // Convert timeElapsed to years with 18 decimals

        // Calculate the rate increase: STARTING_EXCHANGE_RATE * ANNUAL_INCREASE * yearsElapsed
        // Divide by 100 for the percentage and by DECIMALS (1e18) to adjust for the extra decimals on yearsElapsed
        uint256 exchangeRateIncrease = (STARTING_EXCHANGE_RATE * ANNUAL_INCREASE * yearsElapsed) / (100 * DECIMALS);

        return STARTING_EXCHANGE_RATE + exchangeRateIncrease; // Current exchange rate
    }

    /**
     * @dev Returns the current exchange rate between DOC and kDOC. (same mocking behaviour as exchangeRateStored())
     * The exchange rate increases linearly over time at 5% per year.
     */
    function exchangeRateCurrent() public view returns (uint256) {
        uint256 timeElapsed = block.timestamp - i_deploymentTimestamp; // Time elapsed since deployment in seconds
        uint256 yearsElapsed = (timeElapsed * DECIMALS) / YEAR_IN_SECONDS; // Convert timeElapsed to years with 18 decimals

        // Calculate the rate increase: STARTING_EXCHANGE_RATE * ANNUAL_INCREASE * yearsElapsed
        // Divide by 100 for the percentage and by DECIMALS (1e18) to adjust for the extra decimals on yearsElapsed
        uint256 exchangeRateIncrease = (STARTING_EXCHANGE_RATE * ANNUAL_INCREASE * yearsElapsed) / (100 * DECIMALS);

        return STARTING_EXCHANGE_RATE + exchangeRateIncrease; // Current exchange rate
    }
}
