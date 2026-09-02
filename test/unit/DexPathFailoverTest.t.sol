// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IFeeHandler} from "src/interfaces/IFeeHandler.sol";
import {IWRBTC} from "src/interfaces/IWRBTC.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {DexHelperConfig} from "script/DexHelperConfig.s.sol";
import {SovrynErc20HandlerDex} from "src/sovryn/SovrynErc20HandlerDex.sol";
import {MockIsusdToken} from "test/mocks/MockIsusdToken.sol";
import {BitChillOwnable} from "src/BitChillOwnable.sol";
import {ownableUnauthorized} from "../utils/OzRevert.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @notice Allowlisted Dex path activation. `setUp` skips MoC lanes so they do not report empty PASSes.
 */
contract DexPathFailoverTest is DcaDappTest {
    event PurchaseUniswap_NewPathSet(address[] intermediateTokens, uint24[] poolFeeRates, bytes newPath);
    event PurchaseUniswap_PurchasePathAllowedSet(
        bytes32 pathHash, bytes encodedPath, address[] intermediateTokens, uint24[] poolFeeRates, bool allowed
    );

    address internal constant HANDLER_OWNER = address(uint160(uint256(keccak256("handler-owner"))));

    function setUp() public override {
        if (!isDexSwaps) vm.skip(true);
        super.setUp();
    }

    function testSwapperAndHandlerOwnerCanActivateAllowlistedPath() public {
        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        _allow(mids, fees, true);

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

    function testCannotActivatePathThatIsNotAllowlisted() public {
        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseUniswap.PurchaseUniswap__PurchasePathNotAllowed.selector, keccak256(path))
        );
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
    }

    function testArbitraryEoaCannotActivateAllowlistedPath() public {
        (address[] memory mids, uint24[] memory fees,) = _alternatePath();
        _allow(mids, fees, true);

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseUniswap.PurchaseUniswap__UnauthorizedPurchasePathSetter.selector, USER)
        );
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
    }

    function testOnlyHandlerOwnerCanAllowlist() public {
        (address[] memory mids, uint24[] memory fees,) = _alternatePath();
        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePathAllowed(mids, fees, true);
    }

    function testSetPurchasePathAllowedRejectsUnchanged() public {
        (address[] memory ctorMids, uint24[] memory ctorFees) = _constructorComponents();
        bytes memory ctorPath = _encodePath(ctorMids, ctorFees);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseUniswap.PurchaseUniswap__PurchasePathPermissionUnchanged.selector, keccak256(ctorPath), true
            )
        );
        _allow(ctorMids, ctorFees, true);
    }

    function testRevokedPathCannotBeActivated() public {
        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        _allow(mids, fees, true);
        _allow(mids, fees, false);

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseUniswap.PurchaseUniswap__PurchasePathNotAllowed.selector, keccak256(path))
        );
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
    }

    function testActivePathCannotBeRevokedUntilSwitched() public {
        (address[] memory ctorMids, uint24[] memory ctorFees) = _constructorComponents();
        bytes memory active = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseUniswap.PurchaseUniswap__CannotRevokeActivePurchasePath.selector, keccak256(active)
            )
        );
        _allow(ctorMids, ctorFees, false);

        (address[] memory mids, uint24[] memory fees,) = _alternatePath();
        _allow(mids, fees, true);
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);

        _allow(ctorMids, ctorFees, false);
        assertFalse(IPurchaseUniswap(address(stablecoinHandler)).isPurchasePathAllowed(keccak256(active)));
    }

    function testRevokeSwapperDoesNotMutateActivePath() public {
        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        _allow(mids, fees, true);
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);

        vm.prank(OWNER);
        operationsAdmin.revokeSwapper(SWAPPER);
        assertEq(IPurchaseUniswap(address(stablecoinHandler)).getSwapPath(), path);

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseUniswap.PurchaseUniswap__UnauthorizedPurchasePathSetter.selector, SWAPPER)
        );
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);

        (address[] memory ctorMids, uint24[] memory ctorFees) = _constructorComponents();
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(ctorMids, ctorFees);
        assertEq(IPurchaseUniswap(address(stablecoinHandler)).getSwapPath(), _encodePath(ctorMids, ctorFees));
    }

    function testDivergentOwnersDoNotGiveAdminOwnerPathActivation() public {
        vm.prank(OWNER);
        BitChillOwnable(address(stablecoinHandler)).transferOwnership(HANDLER_OWNER);
        vm.prank(HANDLER_OWNER);
        BitChillOwnable(address(stablecoinHandler)).acceptOwnership();

        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        vm.expectRevert(ownableUnauthorized(OWNER));
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePathAllowed(mids, fees, true);

        vm.prank(HANDLER_OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePathAllowed(mids, fees, true);

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseUniswap.PurchaseUniswap__UnauthorizedPurchasePathSetter.selector, OWNER)
        );
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);

        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
        assertEq(IPurchaseUniswap(address(stablecoinHandler)).getSwapPath(), path);

        vm.expectRevert(ownableUnauthorized(OWNER));
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumSafetyCheck(0.996 ether);

        vm.prank(HANDLER_OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumSafetyCheck(0.996 ether);
        assertEq(IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumSafetyCheck(), 0.996 ether);

        vm.prank(HANDLER_OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
    }

    function testSlippageAndOracleRemainHandlerOwnerOnly() public {
        vm.expectRevert(ownableUnauthorized(SWAPPER));
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumSafetyCheck(0.996 ether);

        vm.expectRevert(ownableUnauthorized(SWAPPER));
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).updateMocOracle(address(1));
    }

    function testConstructorSelfAllowlistsActivePathWithoutSetter() public {
        (address[] memory mids, uint24[] memory fees) = _constructorComponents();
        bytes memory path = _encodePath(mids, fees);
        bytes32 pathHash = keccak256(path);

        vm.recordLogs();
        IPurchaseUniswap other = _secondHandler();
        _assertConstructorInstallLogs(address(other), vm.getRecordedLogs(), mids, fees, path);

        assertEq(other.getSwapPath(), path);
        assertTrue(other.isPurchasePathAllowed(pathHash));
    }

    function testConstructorPathIsAllowlistedBeforeAssignment() public {
        bytes memory path = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        assertTrue(IPurchaseUniswap(address(stablecoinHandler)).isPurchasePathAllowed(keccak256(path)));
        assertEq(operationsAdmin.getTokenHandler(address(stablecoin), s_routeIndex), address(stablecoinHandler));
    }

    function testUnauthorizedActivationOfNonAllowlistedPathFails() public {
        bytes memory path = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        assertTrue(IPurchaseUniswap(address(stablecoinHandler)).isPurchasePathAllowed(keccak256(path)));

        (address[] memory mids, uint24[] memory fees, bytes memory other) = _alternatePath();
        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseUniswap.PurchaseUniswap__PurchasePathNotAllowed.selector, keccak256(other))
        );
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
    }

    function testAllowlistIsLocalToEachHandler() public {
        (address[] memory mids, uint24[] memory fees, bytes memory path) = _alternatePath();
        bytes32 pathHash = keccak256(path);
        _allow(mids, fees, true);
        IPurchaseUniswap other = _secondHandler();
        assertTrue(other.isPurchasePathAllowed(keccak256(other.getSwapPath())));

        vm.expectRevert(
            abi.encodeWithSelector(IPurchaseUniswap.PurchaseUniswap__PurchasePathNotAllowed.selector, pathHash)
        );
        vm.prank(OWNER);
        other.setPurchasePath(mids, fees);

        vm.prank(OWNER);
        other.setPurchasePathAllowed(mids, fees, true);
        assertTrue(other.isPurchasePathAllowed(pathHash));
        vm.prank(OWNER);
        other.setPurchasePathAllowed(mids, fees, false);
        assertFalse(other.isPurchasePathAllowed(pathHash));
        assertTrue(IPurchaseUniswap(address(stablecoinHandler)).isPurchasePathAllowed(pathHash));
    }

    function testSetPurchasePathAllowedRevertsWithWrongArrayLengths() public {
        address[] memory mids = new address[](1);
        mids[0] = makeAddr("r52-bad-mid");
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        vm.expectRevert(
            abi.encodeWithSelector(
                IPurchaseUniswap.PurchaseUniswap__WrongNumberOfTokensOrFeeRates.selector, mids.length, fees.length
            )
        );
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePathAllowed(mids, fees, true);
    }

    function testPathPolicyConfigurationGas() public {
        (address[] memory mids, uint24[] memory fees,) = _alternatePath();
        (address[] memory ctorMids, uint24[] memory ctorFees) = _constructorComponents();
        uint256 allowStart = gasleft();
        _allow(mids, fees, true);
        uint256 allowGas = allowStart - gasleft();

        uint256 activateStart = gasleft();
        vm.prank(SWAPPER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(mids, fees);
        uint256 activateGas = activateStart - gasleft();

        uint256 revokeStart = gasleft();
        _allow(ctorMids, ctorFees, false);
        uint256 revokeGas = revokeStart - gasleft();

        emit log_named_uint("setPurchasePathAllowed(true) gas", allowGas);
        emit log_named_uint("setPurchasePath gas", activateGas);
        emit log_named_uint("setPurchasePathAllowed(false) gas", revokeGas);
        assertGt(allowGas, 0);
        assertGt(activateGas, 0);
        assertGt(revokeGas, 0);
    }

    function _assertConstructorInstallLogs(
        address emitter,
        Vm.Log[] memory logs,
        address[] memory mids,
        uint24[] memory fees,
        bytes memory path
    ) private {
        bytes32 newPathSig = IPurchaseUniswap.PurchaseUniswap_NewPathSet.selector;
        bytes32 allowedSig = IPurchaseUniswap.PurchaseUniswap_PurchasePathAllowedSet.selector;
        int256 newPathIdx = -1;
        int256 allowedIdx = -1;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics[0] == newPathSig) newPathIdx = int256(i);
            if (logs[i].topics[0] == allowedSig) allowedIdx = int256(i);
        }
        assertFalse(newPathIdx < 0, "constructor must emit NewPathSet");
        assertFalse(allowedIdx < 0, "constructor must emit PurchasePathAllowedSet");
        assertLt(uint256(newPathIdx), uint256(allowedIdx), "NewPathSet then PurchasePathAllowedSet");

        _assertNewPathSetLog(logs[uint256(newPathIdx)].data, mids, fees, path);
        _assertPurchasePathAllowedSetLog(logs[uint256(allowedIdx)].data, mids, fees, path);
    }

    function _assertNewPathSetLog(
        bytes memory data,
        address[] memory mids,
        uint24[] memory fees,
        bytes memory path
    ) private {
        (address[] memory logMids, uint24[] memory logFees, bytes memory logPath) =
            abi.decode(data, (address[], uint24[], bytes));
        assertEq(logMids, mids);
        assertEq(abi.encode(logFees), abi.encode(fees));
        assertEq(logPath, path);
    }

    function _assertPurchasePathAllowedSetLog(
        bytes memory data,
        address[] memory mids,
        uint24[] memory fees,
        bytes memory path
    ) private {
        (
            bytes32 logHash,
            bytes memory logEncoded,
            address[] memory logAllowedMids,
            uint24[] memory logAllowedFees,
            bool logAllowed
        ) = abi.decode(data, (bytes32, bytes, address[], uint24[], bool));
        assertEq(logHash, keccak256(path));
        assertEq(logEncoded, path);
        assertEq(logAllowedMids, mids);
        assertEq(abi.encode(logAllowedFees), abi.encode(fees));
        assertTrue(logAllowed);
    }

    function _allow(address[] memory mids, uint24[] memory fees, bool allowed) private {
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePathAllowed(mids, fees, allowed);
    }

    function _secondHandler() private returns (IPurchaseUniswap other) {
        DexHelperConfig.NetworkConfig memory config = dexHelperConfig.getActiveNetworkConfig();
        IPurchaseUniswap primary = IPurchaseUniswap(address(stablecoinHandler));
        other = IPurchaseUniswap(
            address(
                new SovrynErc20HandlerDex(
                    address(dcaManager),
                    address(stablecoin),
                    address(new MockIsusdToken(address(stablecoin))),
                    IPurchaseUniswap.UniswapSettings({
                        wrBtcToken: IWRBTC(address(wrBtcToken)),
                        swapRouter02: ISwapRouter02(config.swapRouter02Address),
                        swapIntermediateTokens: config.swapIntermediateTokens,
                        swapPoolFeeRates: config.swapPoolFeeRates,
                        mocOracle: ICoinPairPrice(config.mocOracleAddress)
                    }),
                    FEE_COLLECTOR,
                    IFeeHandler(address(stablecoinHandler)).getFeeSettings(),
                    primary.getAmountOutMinimumSafetyCheck(),
                    OWNER
                )
            )
        );
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
