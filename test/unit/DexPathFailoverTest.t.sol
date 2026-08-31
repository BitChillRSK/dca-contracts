// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IOperationsAdmin} from "src/interfaces/IOperationsAdmin.sol";
import {BitChillOwnable} from "src/BitChillOwnable.sol";
import {ownableUnauthorized} from "../utils/OzRevert.sol";

/**
 * @notice R52: allowlisted Dex path activation. Skips on MoC lanes (`onlyDexSwaps`).
 */
contract DexPathFailoverTest is DcaDappTest {
    event PurchaseUniswap_NewPathSet(address[] intermediateTokens, uint24[] poolFeeRates, bytes newPath);

    address internal constant HANDLER_OWNER = address(uint160(uint256(keccak256("handler-owner"))));

    function testSwapperAndAdminOwnerCanActivateAllowlistedPath() public onlyDexSwaps {
        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        vm.prank(OWNER);
        operationsAdmin.setPurchasePathAllowed(address(stablecoinHandler), path, true);

        vm.expectEmit(false, false, false, true, address(stablecoinHandler));
        emit PurchaseUniswap_NewPathSet(mids, fees, path);
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
        assertEq(IPurchaseUniswap(address(stablecoinHandler)).getSwapPath(), path);

        (address[] memory ctorMids, uint24[] memory ctorFees) = _constructorComponents();
        bytes memory constructorPath = _encodePath(ctorMids, ctorFees);
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(ctorMids, ctorFees);
        assertEq(IPurchaseUniswap(address(stablecoinHandler)).getSwapPath(), constructorPath);
    }

    function testCannotActivatePathThatIsNotAllowlisted() public onlyDexSwaps {
        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__PurchasePathNotAllowed.selector,
                address(stablecoinHandler),
                keccak256(path)
            )
        );
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
    }

    function testArbitraryEoaCannotActivateAllowlistedPath() public onlyDexSwaps {
        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        vm.prank(OWNER);
        operationsAdmin.setPurchasePathAllowed(address(stablecoinHandler), path, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__UnauthorizedPurchasePathSetter.selector, USER
            )
        );
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
    }

    function testHandlerACannotSpendHandlerBAllowlist() public onlyDexSwaps {
        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        DummyPathCaller attacker = new DummyPathCaller(address(operationsAdmin));
        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__PurchasePathNotAllowed.selector, address(attacker), keccak256(path)
            )
        );
        attacker.claim(OWNER, keccak256(path));

        vm.prank(OWNER);
        operationsAdmin.setPurchasePathAllowed(address(stablecoinHandler), path, true);
        vm.prank(address(stablecoinHandler));
        operationsAdmin.requirePurchasePathSetter(SWAPPER, keccak256(path));
        // silence unused
        mids;
        fees;
    }

    function testRevokedPathCannotBeActivated() public onlyDexSwaps {
        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        vm.startPrank(OWNER);
        operationsAdmin.setPurchasePathAllowed(address(stablecoinHandler), path, true);
        operationsAdmin.setPurchasePathAllowed(address(stablecoinHandler), path, false);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__PurchasePathNotAllowed.selector,
                address(stablecoinHandler),
                keccak256(path)
            )
        );
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
    }

    function testActivePathCannotBeRevokedUntilSwitched() public onlyDexSwaps {
        bytes memory active = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__CannotRevokeActivePurchasePath.selector,
                address(stablecoinHandler),
                keccak256(active)
            )
        );
        vm.prank(OWNER);
        operationsAdmin.setPurchasePathAllowed(address(stablecoinHandler), active, false);

        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        vm.startPrank(OWNER);
        operationsAdmin.setPurchasePathAllowed(address(stablecoinHandler), path, true);
        vm.stopPrank();
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);

        vm.prank(OWNER);
        operationsAdmin.setPurchasePathAllowed(address(stablecoinHandler), active, false);
        assertFalse(operationsAdmin.isPurchasePathAllowed(address(stablecoinHandler), keccak256(active)));
    }

    function testRevokeSwapperDoesNotMutateActivePath() public onlyDexSwaps {
        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        vm.prank(OWNER);
        operationsAdmin.setPurchasePathAllowed(address(stablecoinHandler), path, true);
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);

        vm.prank(OWNER);
        operationsAdmin.revokeSwapper(SWAPPER);
        assertEq(IPurchaseUniswap(address(stablecoinHandler)).getSwapPath(), path);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__UnauthorizedPurchasePathSetter.selector, SWAPPER
            )
        );
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);

        (address[] memory ctorMids, uint24[] memory ctorFees) = _constructorComponents();
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(ctorMids, ctorFees);
        assertEq(IPurchaseUniswap(address(stablecoinHandler)).getSwapPath(), _encodePath(ctorMids, ctorFees));
    }

    function testDivergentOwnersSplitPathAndSlippageAuthority() public onlyDexSwaps {
        vm.prank(OWNER);
        BitChillOwnable(address(stablecoinHandler)).transferOwnership(HANDLER_OWNER);
        vm.prank(HANDLER_OWNER);
        BitChillOwnable(address(stablecoinHandler)).acceptOwnership();

        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        vm.prank(OWNER);
        operationsAdmin.setPurchasePathAllowed(address(stablecoinHandler), path, true);

        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
        assertEq(IPurchaseUniswap(address(stablecoinHandler)).getSwapPath(), path);

        vm.expectRevert(ownableUnauthorized(OWNER));
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(0.996 ether);

        vm.prank(HANDLER_OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(0.996 ether);
        assertEq(IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumPercent(), 0.996 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__UnauthorizedPurchasePathSetter.selector, HANDLER_OWNER
            )
        );
        vm.prank(HANDLER_OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
    }

    function testSlippageAndOracleRemainHandlerOwnerOnly() public onlyDexSwaps {
        vm.expectRevert(ownableUnauthorized(SWAPPER));
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(0.996 ether);

        vm.expectRevert(ownableUnauthorized(SWAPPER));
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).updateMocOracle(address(1));
    }

    function testConstructorPathIsAllowlistedBeforeAssignment() public onlyDexSwaps {
        bytes memory path = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        assertTrue(operationsAdmin.isPurchasePathAllowed(address(stablecoinHandler), keccak256(path)));
        assertEq(
            operationsAdmin.getTokenHandler(address(stablecoin), s_routeIndex), address(stablecoinHandler)
        );
    }

    function testUnauthorizedOrHashMismatchedActivationFailsOnFork() public onlyDexSwaps {
        bytes memory path = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        assertTrue(operationsAdmin.isPurchasePathAllowed(address(stablecoinHandler), keccak256(path)));

        (address[] memory mids, uint24[] memory fees, bytes memory other) = _alternatePath();
        vm.expectRevert(
            abi.encodeWithSelector(
                IOperationsAdmin.OperationsAdmin__PurchasePathNotAllowed.selector,
                address(stablecoinHandler),
                keccak256(other)
            )
        );
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
    }

    function testPathPolicyConfigurationGas() public onlyDexSwaps {
        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        bytes memory former = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        uint256 allowStart = gasleft();
        vm.prank(OWNER);
        operationsAdmin.setPurchasePathAllowed(address(stablecoinHandler), path, true);
        uint256 allowGas = allowStart - gasleft();

        uint256 activateStart = gasleft();
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
        uint256 activateGas = activateStart - gasleft();

        uint256 revokeStart = gasleft();
        vm.prank(OWNER);
        operationsAdmin.setPurchasePathAllowed(address(stablecoinHandler), former, false);
        uint256 revokeGas = revokeStart - gasleft();

        emit log_named_uint("setPurchasePathAllowed(true) gas", allowGas);
        emit log_named_uint("setPurchasePath gas", activateGas);
        emit log_named_uint("setPurchasePathAllowed(false) gas", revokeGas);
        assertGt(allowGas, 0);
        assertGt(activateGas, 0);
        assertGt(revokeGas, 0);
    }

    function _constructorComponents() private view returns (address[] memory mids, uint24[] memory fees) {
        mids = dexHelperConfig.getActiveNetworkConfig().swapIntermediateTokens;
        fees = dexHelperConfig.getActiveNetworkConfig().swapPoolFeeRates;
    }

    function _alternatePath()
        private
        returns (address[] memory mids, uint24[] memory fees, bytes memory path)
    {
        mids = new address[](1);
        mids[0] = makeAddr("r52-intermediate");
        fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 3000;
        path = _encodePath(mids, fees);
    }

    function _encodePath(address[] memory mids, uint24[] memory fees) private view returns (bytes memory path) {
        path = abi.encodePacked(address(stablecoin));
        for (uint256 i; i < mids.length; ++i) {
            path = abi.encodePacked(path, fees[i], mids[i]);
        }
        path = abi.encodePacked(path, fees[fees.length - 1], address(wrBtcToken));
    }
}

contract DummyPathCaller {
    IOperationsAdmin internal immutable i_admin;

    constructor(address admin) {
        i_admin = IOperationsAdmin(admin);
    }

    function claim(address caller, bytes32 pathHash) external view {
        i_admin.requirePurchasePathSetter(caller, pathHash);
    }
}
