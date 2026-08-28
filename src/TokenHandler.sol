// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ITokenHandler} from "./interfaces/ITokenHandler.sol";
import {FeeHandler} from "./FeeHandler.sol";
import {DcaManagerAccessControl} from "./DcaManagerAccessControl.sol";

/**
 * @title TokenHandler
 * @author BitChill team: Antonio Rodríguez-Ynyesto
 * @notice Base contract for depositing and withdrawing a handler's stablecoin. Owns FeeHandler.
 */
abstract contract TokenHandler is ITokenHandler, ERC165, FeeHandler, DcaManagerAccessControl {
    using SafeERC20 for IERC20;

    IERC20 public immutable i_stableToken; // The stablecoin token to be deposited

    /**
     * @param dcaManagerAddress The DcaManager allowed to call deposit and withdraw.
     * @param tokenAddress The stablecoin this handler holds.
     * @param feeCollector Address that receives purchase fees.
     * @param feeSettings Linear fee parameters.
     * @param initialOwner Address that owns fee configuration immediately after deploy.
     */
    constructor(
        address dcaManagerAddress,
        address tokenAddress,
        address feeCollector,
        FeeSettings memory feeSettings,
        address initialOwner
    ) FeeHandler(feeCollector, feeSettings, initialOwner) DcaManagerAccessControl(dcaManagerAddress) {
        i_stableToken = IERC20(tokenAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc ITokenHandler
     * @dev A deposit cannot be negative: if `balanceOf` falls, the subtraction panics. That is an
     *      invariant break, not a mismatch amount. This function does not return the credited amount.
     */
    function depositToken(address user, uint256 depositAmount) public virtual override onlyDcaManager {
        uint256 balanceBefore = i_stableToken.balanceOf(address(this));
        i_stableToken.safeTransferFrom(user, address(this), depositAmount);
        uint256 depositedAmount = i_stableToken.balanceOf(address(this)) - balanceBefore;
        if (depositedAmount != depositAmount) revert TokenHandler__DepositAmountMismatch(depositAmount, depositedAmount);
        emit TokenHandler__TokenDeposited(address(i_stableToken), user, depositAmount);
    }

    /**
     * @inheritdoc ITokenHandler
     */
    function withdrawToken(address user, uint256 withdrawalAmount) public virtual override onlyDcaManager returns (uint256 withdrawnAmount) {
        uint256 balanceBefore = i_stableToken.balanceOf(address(this));
        i_stableToken.safeTransfer(user, withdrawalAmount);
        withdrawnAmount = balanceBefore - i_stableToken.balanceOf(address(this));
        emit TokenHandler__TokenWithdrawn(address(i_stableToken), user, withdrawnAmount);
    }

    /**
     * @dev ERC-165: `ITokenHandler` plus whatever the parent advertises.
     */
    function supportsInterface(bytes4 interfaceID) public view virtual override returns (bool) {
        return interfaceID == type(ITokenHandler).interfaceId || super.supportsInterface(interfaceID);
    }
}
