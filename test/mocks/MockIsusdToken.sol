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
    uint256 constant BPS_DIVISOR = 10_000;
    /**
     * @notice SIP-0094 Perimeter Fee, in basis points, charged on burn().
     * @dev Zero models both the pre-activation state and Sovryn's fail-open path, where net == gross.
     * When non-zero, burn() pays the receiver the NET amount and still returns the GROSS one, which is the
     * behaviour that breaks any integrator trusting the return value.
     */
    uint256 private s_exitFeeBps;

    constructor(address docTokenAddress) ERC20("Tropykus iSUSD", "iSUSD") Ownable() ERC20Permit("Tropykus iSUSD") {
        i_docToken = IStablecoin(docTokenAddress);
        i_deploymentTimestamp = block.timestamp;
    }

    function mint(address receiver, uint256 depositAmount) external returns (uint256 mintAmount) {
        require(i_docToken.allowance(msg.sender, address(this)) >= depositAmount, "Insufficient allowance");
        // Measure cash actually received. 1:1 tokens are unchanged (`received == depositAmount`).
        uint256 balanceBefore = i_docToken.balanceOf(address(this));
        i_docToken.transferFrom(msg.sender, address(this), depositAmount);
        uint256 received = i_docToken.balanceOf(address(this)) - balanceBefore;
        mintAmount = received * DECIMALS / tokenPrice();
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
        loanAmountPaid = Math.ceilDiv(burnAmount * tokenPrice(), DECIMALS); // GROSS
        uint256 exitFee = loanAmountPaid * s_exitFeeBps / BPS_DIVISOR;
        uint256 netPayout = loanAmountPaid - exitFee;
        // Yield (tokenPrice grows with time) can exceed the DOC this mock was deposited with.
        // Mint the shortfall the same way MockKdocToken.redeemUnderlying does.
        uint256 currentBalance = i_docToken.balanceOf(address(this));
        if (currentBalance < netPayout) {
            IStablecoin(address(i_docToken)).mint(address(this), netPayout - currentBalance);
        }
        i_docToken.transfer(receiver, netPayout); // NET: the fee stays behind, as Sovryn's goes to the ExitFeeVault
        _burn(msg.sender, burnAmount);
        return loanAmountPaid; // the return value stays GROSS even when the payout was NET
    }

    /**
     * @notice Enable or disable the SIP-0094 Perimeter Fee on burn().
     * @param exitFeeBps the fee in basis points (10 = the 0.10% Sovryn approved). Zero disables it.
     */
    function setExitFeeBps(uint256 exitFeeBps) external {
        require(exitFeeBps <= BPS_DIVISOR, "Fee above 100%");
        s_exitFeeBps = exitFeeBps;
    }

    /**
     * @notice the exit fee currently charged on burn(), in basis points
     */
    function getExitFeeBps() external view returns (uint256) {
        return s_exitFeeBps;
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
     * @notice Get the current underlying value of the owner's iSUSD, interest included.
     * @dev Matches Sovryn: assetBalanceOf is balance * tokenPrice, not the starting rate. profitOf is gone
     * with the redeem preflight that misused it (R1); it was a subset of this value, never an addition to it.
     * @return The user's balance of underlying token.
     */
    function assetBalanceOf(address _owner) public view returns (uint256) {
        return balanceOf(_owner) * tokenPrice() / DECIMALS;
    }
}
