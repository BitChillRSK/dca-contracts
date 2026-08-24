// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IStablecoin} from "src/interfaces/IStablecoin.sol";

/**
 * @title MockLToken
 * @notice LayerBank lToken mock: `onlyCore` supply/redeem, 1e18 starting exchange rate, 5% linear APR.
 * @dev `core` starts unset; call `setCore` once after deploying `MockLayerBankCore`.
 */
contract MockLToken is ERC20 {
    uint256 constant DECIMALS = 1e18;
    uint256 constant STARTING_EXCHANGE_RATE = 1e18;
    uint256 constant ANNUAL_INCREASE = 5;
    uint256 constant YEAR_IN_SECONDS = 31536000;

    IStablecoin public immutable underlyingToken;
    address public core;
    uint256 private immutable i_deploymentTimestamp;
    bool private s_silentZeroPayout;

    error MockLToken__OnlyCore();
    error MockLToken__CoreAlreadySet();
    error MockLToken__InvalidCore();
    error MockLToken__InvalidLAmount();

    modifier onlyCore() {
        if (msg.sender != core) revert MockLToken__OnlyCore();
        _;
    }

    constructor(address underlying_) ERC20("LayerBank lToken", "lTKN") {
        underlyingToken = IStablecoin(underlying_);
        i_deploymentTimestamp = block.timestamp;
    }

    function setCore(address core_) external {
        if (core != address(0)) revert MockLToken__CoreAlreadySet();
        if (core_ == address(0)) revert MockLToken__InvalidCore();
        core = core_;
    }

    function setSilentZeroPayout(bool silentZeroPayout) external {
        s_silentZeroPayout = silentZeroPayout;
    }

    function underlying() external view returns (address) {
        return address(underlyingToken);
    }

    /// @notice View rate including pending interest (LayerBank `exchangeRate`).
    function exchangeRate() public view returns (uint256) {
        uint256 timeElapsed = block.timestamp - i_deploymentTimestamp;
        uint256 yearsElapsed = (timeElapsed * DECIMALS) / YEAR_IN_SECONDS;
        uint256 increase = (STARTING_EXCHANGE_RATE * ANNUAL_INCREASE * yearsElapsed) / (100 * DECIMALS);
        return STARTING_EXCHANGE_RATE + increase;
    }

    /// @notice Mutating rate entry point (LayerBank `accruedExchangeRate`). Same value as the view.
    function accruedExchangeRate() external view returns (uint256) {
        return exchangeRate();
    }

    function supply(address account, uint256 uAmount) external onlyCore returns (uint256 lAmount) {
        uint256 rate = exchangeRate();
        uint256 balanceBefore = underlyingToken.balanceOf(address(this));
        underlyingToken.transferFrom(account, address(this), uAmount);
        uint256 received = underlyingToken.balanceOf(address(this)) - balanceBefore;
        lAmount = received * DECIMALS / rate;
        if (lAmount == 0) revert MockLToken__InvalidLAmount();
        _mint(account, lAmount);
    }

    function redeemUnderlying(address account, uint256 uAmount) external onlyCore returns (uint256) {
        uint256 rate = exchangeRate();
        uint256 lAmount = (uAmount * DECIMALS + rate - 1) / rate;
        _burn(account, lAmount);
        if (s_silentZeroPayout) return 0;
        _payout(account, uAmount);
        return uAmount;
    }

    function redeemToken(address account, uint256 lAmount) external onlyCore returns (uint256 uAmount) {
        uint256 rate = exchangeRate();
        uAmount = lAmount * rate / DECIMALS;
        _burn(account, lAmount);
        if (s_silentZeroPayout) return 0;
        _payout(account, uAmount);
    }

    function _payout(address to, uint256 amount) private {
        uint256 currentBalance = underlyingToken.balanceOf(address(this));
        if (currentBalance < amount) {
            underlyingToken.mint(address(this), amount - currentBalance);
        }
        underlyingToken.transfer(to, amount);
    }
}

/**
 * @title MockLayerBankCore
 * @notice Forwards supply/redeem to the lToken as LayerBank Core does. Returns can be set to a lie
 *         so tests prove the handler measures balance deltas instead of trusting Core.
 */
contract MockLayerBankCore {
    MockLToken public immutable lToken;
    uint256 public supplyReturnOverride;
    bool public useSupplyReturnOverride;

    constructor(MockLToken lToken_) {
        lToken = lToken_;
    }

    function setSupplyReturnOverride(uint256 value, bool enabled) external {
        supplyReturnOverride = value;
        useSupplyReturnOverride = enabled;
    }

    function supply(address, uint256 uAmount) external returns (uint256) {
        uint256 minted = lToken.supply(msg.sender, uAmount);
        if (useSupplyReturnOverride) return supplyReturnOverride;
        return minted;
    }

    function redeemToken(address, uint256 lAmount) external returns (uint256) {
        return lToken.redeemToken(msg.sender, lAmount);
    }

    function redeemUnderlying(address, uint256 uAmount) external returns (uint256) {
        return lToken.redeemUnderlying(msg.sender, uAmount);
    }
}
