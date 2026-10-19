// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStablecoin} from "test/interfaces/IStablecoin.sol";

/**
 * @title FizzIToken
 * @notice Sovryn iToken stand-in for the Fizz suite. Unlike `test/mocks/MockIToken.sol`, the price is
 *         a settable number that can fall (Sovryn's `tokenPrice()` drops on realized loan losses), the
 *         burn pays `floor(shares * price / 1e18)` as Sovryn does, and an optional exit fee stays
 *         behind like Sovryn's ExitFeeVault (SIP-0094).
 * @dev Missing cash is minted on burn so interest and rate moves never strand a redemption.
 */
contract FizzIToken is ERC20 {
    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    IStablecoin public immutable i_loanToken;
    uint256 private s_price;
    uint256 private s_exitFeeBps;

    constructor(address loanToken, uint256 initialPrice) ERC20("Fizz iToken", "fiToken") {
        i_loanToken = IStablecoin(loanToken);
        s_price = initialPrice;
    }

    function loanTokenAddress() external view returns (address) {
        return address(i_loanToken);
    }

    function tokenPrice() public view returns (uint256) {
        return s_price;
    }

    function assetBalanceOf(address owner) external view returns (uint256) {
        return balanceOf(owner) * s_price / DECIMALS;
    }

    function mint(address receiver, uint256 depositAmount) external returns (uint256 mintAmount) {
        uint256 balanceBefore = i_loanToken.balanceOf(address(this));
        i_loanToken.transferFrom(msg.sender, address(this), depositAmount);
        uint256 received = i_loanToken.balanceOf(address(this)) - balanceBefore;
        mintAmount = received * DECIMALS / s_price;
        _mint(receiver, mintAmount);
    }

    function burn(address receiver, uint256 burnAmount) external returns (uint256 loanAmountPaid) {
        require(balanceOf(msg.sender) >= burnAmount, "FizzIToken: insufficient balance");
        loanAmountPaid = burnAmount * s_price / DECIMALS;
        uint256 netPayout = loanAmountPaid - loanAmountPaid * s_exitFeeBps / BPS_DENOMINATOR;
        _burn(msg.sender, burnAmount);
        if (netPayout > 0) {
            uint256 cash = i_loanToken.balanceOf(address(this));
            if (cash < netPayout) i_loanToken.mint(address(this), netPayout - cash);
            i_loanToken.transfer(receiver, netPayout);
        }
    }

    function setTokenPrice(uint256 newPrice) external {
        require(newPrice > 0, "FizzIToken: zero price");
        s_price = newPrice;
    }

    function setExitFeeBps(uint256 exitFeeBps) external {
        require(exitFeeBps <= BPS_DENOMINATOR, "FizzIToken: fee above 100%");
        s_exitFeeBps = exitFeeBps;
    }

    function getExitFeeBps() external view returns (uint256) {
        return s_exitFeeBps;
    }
}
