// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IStablecoin} from "../../src/interfaces/IStablecoin.sol";
import {console} from "forge-std/Test.sol";

contract MockKdocToken is ERC20, ERC20Burnable, Ownable, ERC20Permit {
    IStablecoin immutable i_docToken;
    uint256 constant DECIMALS = 1e18;
    uint256 constant STARTING_EXCHANGE_RATE = 2 * DECIMALS / 100; // 0.02 DOC per kDOC
    uint256 immutable i_deploymentTimestamp;
    uint256 constant ANNUAL_INCREASE = 5; // 5% APR (linear for simplicity)
    uint256 constant YEAR_IN_SECONDS = 31536000;

    // Compound-style: keep the last stored exchange rate and the timestamp it was accrued
    uint256 private s_exchangeRateStored;
    uint256 private s_lastAccrualTimestamp;

    constructor(address docTokenAddress) ERC20("Tropykus kDOC", "kDOC") Ownable(msg.sender) ERC20Permit("Tropykus kDOC") {
        i_docToken = IStablecoin(docTokenAddress);
        i_deploymentTimestamp = block.timestamp;

        s_exchangeRateStored = STARTING_EXCHANGE_RATE;
        s_lastAccrualTimestamp = block.timestamp;
    }

    /**
     * @notice When set, redeem calls burn the kDOC, transfer nothing, and still return the success code 0.
     * @dev Models a Compound-style market that reports success while paying out nothing (paused transfer,
     * empty market, upgraded implementation). Integrators that trust the return code lose the burnt shares.
     */
    bool private s_silentZeroPayout;
    /// @notice mint succeeds (code 0) but mints no kDOC, so the handler's zero-delta guard can fire.
    bool private s_forceZeroMint;
    /**
     * @notice When set, mint keeps all the cash it pulled but credits shares for only part of it.
     * @dev Models the hop-2 lag: a 1:1 stablecoin arrives in full, then the market mints shares worth less than
     * the deposit. DcaManager's book then sits ahead of the share-backed underlying, which is what the per-user
     * share clamp exists for. Hop 1 is fee-free, so `TokenHandler` never sees a mismatch.
     */
    uint256 private s_mintShortfallBps;

    function setSilentZeroPayout(bool silentZeroPayout) external {
        s_silentZeroPayout = silentZeroPayout;
    }

    function setForceZeroMint(bool forceZeroMint) external {
        s_forceZeroMint = forceZeroMint;
    }

    function setMintShortfallBps(uint256 mintShortfallBps) external {
        require(mintShortfallBps <= 10_000, "Shortfall above 100%");
        s_mintShortfallBps = mintShortfallBps;
    }

    function mint(uint256 amount) public returns (uint256) {
        require(i_docToken.allowance(msg.sender, address(this)) >= amount, "Insufficient allowance");
        // Compound-style doTransferIn: mint shares from cash actually received, not the argument.
        // 1:1 tokens are unchanged (`received == amount`).
        uint256 balanceBefore = i_docToken.balanceOf(address(this));
        i_docToken.transferFrom(msg.sender, address(this), amount);
        if (s_forceZeroMint) return 0;
        uint256 received = i_docToken.balanceOf(address(this)) - balanceBefore;
        uint256 credited = received * (10_000 - s_mintShortfallBps) / 10_000;
        _mint(msg.sender, credited * DECIMALS / exchangeRateCurrent());
        return 0;
    }

    function redeemUnderlying(uint256 amount) public returns (uint256) {
        uint256 kDocToBurn = amount * DECIMALS / exchangeRateCurrent();
        require(balanceOf(msg.sender) >= kDocToBurn, "Insufficient balance");
        if (s_silentZeroPayout) {
            _burn(msg.sender, kDocToBurn);
            return 0;
        }
        // Ensure we have enough stablecoin to transfer (mint if needed to simulate yield generation)
        uint256 currentBalance = i_docToken.balanceOf(address(this));
        if (currentBalance < amount) {
            // Mint the difference to simulate yield generation from the lending protocol
            IStablecoin(address(i_docToken)).mint(address(this), amount - currentBalance);
        }
        i_docToken.transfer(msg.sender, amount);
        _burn(msg.sender, kDocToBurn); // Burn an amount of kDOC equivalent to the amount of DOC divided by the exchange rate (e.g.: 1 DOC redeemed => 1 / 0.02 = 50 kDOC burnt)
        return 0;
    }

    function redeem(uint256 kDocToBurn) public returns (uint256) {
        uint256 docToRedeem = kDocToBurn * exchangeRateCurrent() / DECIMALS;
        require(balanceOf(msg.sender) >= kDocToBurn, "Insufficient balance");
        if (s_silentZeroPayout) {
            _burn(msg.sender, kDocToBurn);
            return 0;
        }
        // Ensure we have enough stablecoin to transfer (mint if needed to simulate yield generation)
        uint256 currentBalance = i_docToken.balanceOf(address(this));
        if (currentBalance < docToRedeem) {
            // Mint the difference to simulate yield generation from the lending protocol
            IStablecoin(address(i_docToken)).mint(address(this), docToRedeem - currentBalance);
        }
        i_docToken.transfer(msg.sender, docToRedeem);
        _burn(msg.sender, kDocToBurn); // Burn an amount of kDOC equivalent to the amount of DOC divided by the exchange rate (e.g.: 1 DOC redeemed => 1 / 0.02 = 50 kDOC burnt)
        return 0;
    }

    /**
     * @notice Returns the last stored exchange rate (no state changes).
     */
    function exchangeRateStored() public view returns (uint256) {
        return s_exchangeRateStored;
    }

    /**
     * @dev Accrues interest linearly at 5% APR and updates the stored rate.
     */
    function exchangeRateCurrent() public returns (uint256) {
        if (block.timestamp == s_lastAccrualTimestamp) {
            // No time has passed since last accrual; return stored value
            return s_exchangeRateStored;
        }

        uint256 timeElapsed = block.timestamp - i_deploymentTimestamp; // seconds since deployment
        uint256 yearsElapsed = (timeElapsed * DECIMALS) / YEAR_IN_SECONDS; // 18-dec fixed-point years

        // Linear increase: STARTING_RATE + STARTING_RATE * APR% * yearsElapsed
        uint256 exchangeRateIncrease = (STARTING_EXCHANGE_RATE * ANNUAL_INCREASE * yearsElapsed) / (100 * DECIMALS);
        uint256 newRate = STARTING_EXCHANGE_RATE + exchangeRateIncrease;

        // Persist
        s_exchangeRateStored = newRate;
        s_lastAccrualTimestamp = block.timestamp;

        return newRate;
    }
}
