// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStablecoin} from "src/interfaces/IStablecoin.sol";

/**
 * @title MockLayerBankAToken
 * @notice LayerBank aToken mock: scaled ERC20 storage, rebasing `balanceOf`, RAY (1e27) index.
 * @dev `pool` starts unset; call `setPool` once after deploying `MockLayerBankPool`.
 */
contract MockLayerBankAToken is ERC20 {
    uint256 public constant RAY = 1e27;
    uint256 constant ANNUAL_INCREASE = 5;
    uint256 constant YEAR_IN_SECONDS = 31536000;

    IStablecoin public immutable underlyingAsset;
    address public pool;
    uint256 private immutable i_deploymentTimestamp;
    bool private s_silentZeroPayout;
    bool private s_forceZeroMint;
    bool private s_useMintOverride;
    uint256 private s_mintOverride;
    bool private s_usePayoutCap;
    uint256 private s_payoutCap;
    bool private s_useIncomeOverride;
    uint256 private s_incomeOverride;

    error MockLayerBankAToken__OnlyPool();
    error MockLayerBankAToken__PoolAlreadySet();
    error MockLayerBankAToken__InvalidPool();
    error MockLayerBankAToken__InvalidScaledAmount();

    modifier onlyPool() {
        if (msg.sender != pool) revert MockLayerBankAToken__OnlyPool();
        _;
    }

    constructor(address underlying_) ERC20("LayerBank Rootstock DOC", "lRooDOC") {
        underlyingAsset = IStablecoin(underlying_);
        i_deploymentTimestamp = block.timestamp;
    }

    function setPool(address pool_) external {
        if (pool != address(0)) revert MockLayerBankAToken__PoolAlreadySet();
        if (pool_ == address(0)) revert MockLayerBankAToken__InvalidPool();
        pool = pool_;
    }

    function setSilentZeroPayout(bool silentZeroPayout) external {
        s_silentZeroPayout = silentZeroPayout;
    }

    /// @notice Pool.supply succeeds but mints nothing, so the handler's zero-delta guard can fire.
    function setForceZeroMint(bool forceZeroMint) external {
        s_forceZeroMint = forceZeroMint;
    }

    /// @notice Mint a fixed scaled amount regardless of underlying received, so tests can prove
    ///         the handler credits `scaledBalanceOf` delta instead of a computed conversion.
    function setMintOverride(uint256 scaled, bool enabled) external {
        s_mintOverride = scaled;
        s_useMintOverride = enabled;
    }

    /// @notice Cap the underlying paid on withdraw so tests can assert the handler pays the measured delta.
    /// @dev Live Aave `withdraw` transfers underlying from the aToken and reverts on insufficient
    ///      cash rather than under-paying. This hook is deliberately more permissive so
    ///      AGENTS.md invariant 1 has coverage. Do not "fix" the mock to match live behavior.
    function setPayoutCap(uint256 cap, bool enabled) external {
        s_payoutCap = cap;
        s_usePayoutCap = enabled;
    }

    /// @notice Pin the liquidity index so solvency tests can use a non-RAY rate without warping.
    function setNormalizedIncome(uint256 income, bool enabled) external {
        s_incomeOverride = income;
        s_useIncomeOverride = enabled;
    }

    function POOL() external view returns (address) {
        return pool;
    }

    function UNDERLYING_ASSET_ADDRESS() external view returns (address) {
        return address(underlyingAsset);
    }

    function scaledBalanceOf(address account) public view returns (uint256) {
        return super.balanceOf(account);
    }

    /// @notice Rebasing view. Do not store this; the handler uses `scaledBalanceOf`.
    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account) * getNormalizedIncome() / RAY;
    }

    function getNormalizedIncome() public view returns (uint256) {
        if (s_useIncomeOverride) return s_incomeOverride;
        uint256 timeElapsed = block.timestamp - i_deploymentTimestamp;
        uint256 yearsElapsed = (timeElapsed * RAY) / YEAR_IN_SECONDS;
        uint256 increase = (RAY * ANNUAL_INCREASE * yearsElapsed) / (100 * RAY);
        return RAY + increase;
    }

    function mintScaled(address onBehalfOf, uint256 underlyingReceived) external onlyPool returns (uint256 scaled) {
        if (s_forceZeroMint) return 0;
        if (s_useMintOverride) {
            scaled = s_mintOverride;
        } else {
            scaled = _rayDiv(underlyingReceived, getNormalizedIncome());
        }
        if (scaled == 0) revert MockLayerBankAToken__InvalidScaledAmount();
        _mint(onBehalfOf, scaled);
    }

    function burnScaled(address from, address to, uint256 underlyingAmount) external onlyPool returns (uint256 paid) {
        uint256 rate = getNormalizedIncome();
        uint256 scaled = _rayDiv(underlyingAmount, rate);
        _burn(from, scaled);
        if (s_silentZeroPayout) return 0;
        return _payout(to, underlyingAmount);
    }

    /// @dev Aave WadRayMath.rayDiv: round nearest. Used for both mint and burn.
    function _rayDiv(uint256 a, uint256 rayIndex) private pure returns (uint256) {
        return (a * RAY + rayIndex / 2) / rayIndex;
    }

    function _payout(address to, uint256 amount) private returns (uint256) {
        uint256 pay = amount;
        if (s_usePayoutCap && pay > s_payoutCap) pay = s_payoutCap;
        if (pay == 0) return 0;
        uint256 currentBalance = underlyingAsset.balanceOf(address(this));
        if (currentBalance < pay) {
            underlyingAsset.mint(address(this), pay - currentBalance);
        }
        IERC20(address(underlyingAsset)).transfer(to, pay);
        return pay;
    }
}

/**
 * @title MockLayerBankPool
 * @notice Forwards supply/withdraw to the aToken as the live Aave Pool does. `supply` matches
 *         the live ABI (no return). `withdraw` can lie about its return so tests prove the
 *         handler measures DOC `balanceOf` deltas instead of trusting it.
 */
contract MockLayerBankPool {
    MockLayerBankAToken public immutable aToken;
    uint256 public withdrawReturnOverride;
    bool public useWithdrawReturnOverride;

    constructor(MockLayerBankAToken aToken_) {
        aToken = aToken_;
    }

    function setWithdrawReturnOverride(uint256 value, bool enabled) external {
        withdrawReturnOverride = value;
        useWithdrawReturnOverride = enabled;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        IERC20 token = IERC20(asset);
        uint256 balanceBefore = token.balanceOf(address(aToken));
        token.transferFrom(msg.sender, address(aToken), amount);
        uint256 received = token.balanceOf(address(aToken)) - balanceBefore;
        aToken.mintScaled(onBehalfOf, received);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(aToken.UNDERLYING_ASSET_ADDRESS()), "asset");
        uint256 paid = aToken.burnScaled(msg.sender, to, amount);
        if (useWithdrawReturnOverride) return withdrawReturnOverride;
        return paid;
    }

    function getReserveNormalizedIncome(address) external view returns (uint256) {
        return aToken.getNormalizedIncome();
    }
}
