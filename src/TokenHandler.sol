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
 * @dev Base contract for handling stablecoins.
 */
abstract contract TokenHandler is ITokenHandler, ERC165, FeeHandler, DcaManagerAccessControl {
    using SafeERC20 for IERC20;

    IERC20 public immutable i_stableToken; // The stablecoin token to be deposited

    /**
     * @param dcaManagerAddress: the address of the DCA manager
     * @param tokenAddress: the address of the token to be deposited
     * @param feeCollector: the address of the fee collector
     * @param feeSettings: the fee settings
     * @param initialOwner: the address that owns fee/oracle configuration immediately after deploy
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
     * @notice deposit the full token amount for DCA on the contract
     * @notice This function transfers the selected token from the user to this contract. The user must have called the token contract's
     * approve function with this contract's address and the amount approved
     * @param user: the address of the user making the deposit
     * @param depositAmount: the amount requested from the user
     * @return depositedAmount the amount this contract actually received (balance delta around transferFrom),
     * which this function guarantees equals depositAmount
     * @dev The listed stablecoins are 1:1, so a delta other than the request means the token started taking a
     * transfer fee (or a hook minted extra). That fails closed: the transferFrom rolls back with the rest of the
     * transaction rather than crediting the user a schedule balance they did not ask for. A drop in
     * `balanceOf` is reported as received 0 rather than underflowing.
     */
    function depositToken(address user, uint256 depositAmount) public virtual override onlyDcaManager returns (uint256 depositedAmount) {
        uint256 balanceBefore = i_stableToken.balanceOf(address(this));
        i_stableToken.safeTransferFrom(user, address(this), depositAmount);
        uint256 balanceAfter = i_stableToken.balanceOf(address(this));
        depositedAmount = balanceAfter < balanceBefore ? 0 : balanceAfter - balanceBefore;
        if (depositedAmount != depositAmount) revert TokenHandler__DepositAmountMismatch(depositAmount, depositedAmount);
        emit TokenHandler__TokenDeposited(address(i_stableToken), user, depositedAmount);
    }

    /**
     * @notice withdraw some or all of the stablecoin token previously deposited
     * @notice This function transfers stablecoin token from this contract back to the user
     * @param user: the address of the user making the withdrawal
     * @param withdrawalAmount: the amount of stablecoin token to withdraw
     * @return withdrawnAmount the amount that left this contract (balance delta around safeTransfer)
     */
    function withdrawToken(address user, uint256 withdrawalAmount) public virtual override onlyDcaManager returns (uint256 withdrawnAmount) {
        uint256 balanceBefore = i_stableToken.balanceOf(address(this));
        i_stableToken.safeTransfer(user, withdrawalAmount);
        withdrawnAmount = balanceBefore - i_stableToken.balanceOf(address(this));
        emit TokenHandler__TokenWithdrawn(address(i_stableToken), user, withdrawnAmount);
    }

    /**
     * @notice check if the contract supports an interface
     * @param interfaceID: the interface ID to check
     * @return true if the contract supports the interface, false otherwise
     */
    function supportsInterface(bytes4 interfaceID) public view virtual override returns (bool) {
        return interfaceID == type(ITokenHandler).interfaceId || super.supportsInterface(interfaceID);
    }
}
