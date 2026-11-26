// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, Vm} from "forge-std/Test.sol";
import {DcaManager} from "src/DcaManager.sol";
import {OperationsAdmin} from "src/OperationsAdmin.sol";
import {IdleDocHandlerMoc} from "src/idle/IdleDocHandlerMoc.sol";
import {IdleHandlerDex} from "src/idle/IdleHandlerDex.sol";
import {LayerBankDocHandlerMoc} from "src/layerbank/LayerBankDocHandlerMoc.sol";
import {LayerBankHandlerDex} from "src/layerbank/LayerBankHandlerDex.sol";
import {IDcaManager} from "src/interfaces/IDcaManager.sol";
import {IDcaManagerAccessControl} from "src/interfaces/IDcaManagerAccessControl.sol";
import {IPurchaseUniswap} from "src/interfaces/IPurchaseUniswap.sol";
import {IPurchaseFees} from "src/interfaces/IPurchaseFees.sol";
import {ICoinPairPrice} from "src/interfaces/ICoinPairPrice.sol";
import {IWRBTC} from "src/interfaces/IWRBTC.sol";
import {IUniswapV3SwapRouter} from "src/interfaces/IUniswapV3SwapRouter.sol";
import {MockStablecoin} from "test/mocks/MockStablecoin.sol";
import {MockLayerBankAToken, MockLayerBankPool} from "test/mocks/MockLayerBank.sol";
import {MockMocOracle} from "test/mocks/MockMocOracle.sol";
import {MockWrbtcToken} from "test/mocks/MockWrbtcToken.sol";
import "test/Constants.sol";

/**
 * @notice R123 (Kann #23 and #20 item 5): constructors log the configuration they write, and every
 *         production handler leaf refuses a zero DcaManager.
 * @dev Each event must come from the deployed contract, once, carrying the value its getter returns.
 *      Old/new events report zero as the old value. Handlers are built with this test as their
 *      DcaManager, as in `ZeroStablecoinTest`.
 */
contract ConstructorConfigEventsTest is Test {
    address private constant FEE_COLLECTOR = address(0xFEE);
    address private constant MOC_PROXY = address(0x70C);
    address private constant SWAP_ROUTER = address(0x5A9);
    uint256 private constant MAX_SCHEDULES = 7;

    MockStablecoin private s_stablecoin;
    address private s_aToken;
    MockMocOracle private s_oracle;
    MockWrbtcToken private s_wrBtc;

    function setUp() public {
        s_stablecoin = new MockStablecoin(address(this));
        MockLayerBankAToken aToken = new MockLayerBankAToken(address(s_stablecoin));
        aToken.setPool(address(new MockLayerBankPool(aToken)));
        s_aToken = address(aToken);
        s_oracle = new MockMocOracle();
        s_wrBtc = new MockWrbtcToken();
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR EVENTS
    //////////////////////////////////////////////////////////////*/

    function testDcaManagerConstructorLogsPeriodAndCap() public {
        address operationsAdmin = address(new OperationsAdmin(address(this)));
        vm.recordLogs();
        DcaManager dcaManager = new DcaManager(operationsAdmin, 2 days, MAX_SCHEDULES, address(this));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        Vm.Log memory period =
            _onlyLog(logs, address(dcaManager), IDcaManager.DcaManager__MinPurchasePeriodSet.selector);
        assertEq(abi.decode(period.data, (uint256)), dcaManager.getMinPurchasePeriod());
        assertEq(dcaManager.getMinPurchasePeriod(), 2 days);
        Vm.Log memory cap =
            _onlyLog(logs, address(dcaManager), IDcaManager.DcaManager__MaxSchedulesPerTokenSet.selector);
        assertEq(abi.decode(cap.data, (uint256)), dcaManager.getMaxSchedulesPerToken());
        assertEq(dcaManager.getMaxSchedulesPerToken(), MAX_SCHEDULES);
    }

    function testMocLeafConstructorLogsFeeSettings() public {
        vm.recordLogs();
        address handler = address(
            new IdleDocHandlerMoc(
                address(this), address(s_stablecoin), FEE_COLLECTOR, MOC_PROXY, _feeSettings(), address(this)
            )
        );
        _assertFeeEvents(vm.getRecordedLogs(), handler);
    }

    function testDexLeafConstructorLogsFeeSettingsOracleAndFloors() public {
        vm.recordLogs();
        address handler = address(
            new LayerBankHandlerDex(
                address(this),
                address(s_stablecoin),
                s_aToken,
                _uniswapSettings(),
                FEE_COLLECTOR,
                _feeSettings(),
                DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
                address(this)
            )
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertFeeEvents(logs, handler);

        IPurchaseUniswap uniswap = IPurchaseUniswap(handler);
        Vm.Log memory oracle = _onlyLog(logs, handler, IPurchaseUniswap.PurchaseUniswap__OracleSet.selector);
        assertEq(oracle.topics[1], bytes32(0), "initial old oracle is not zero");
        assertEq(address(uint160(uint256(oracle.topics[2]))), address(uniswap.getMocOracle()));
        Vm.Log memory percent =
            _onlyLog(logs, handler, IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentSet.selector);
        (uint256 oldPercent, uint256 newPercent) = abi.decode(percent.data, (uint256, uint256));
        assertEq(oldPercent, 0);
        assertEq(newPercent, uniswap.getAmountOutMinimumPercent());
    }

    /*//////////////////////////////////////////////////////////////
                              ZERO MANAGER
    //////////////////////////////////////////////////////////////*/

    function testIdleMocRejectsZeroDcaManager() public {
        vm.expectRevert(IDcaManagerAccessControl.DcaManagerAccessControl__ZeroDcaManager.selector);
        new IdleDocHandlerMoc(
            address(0), address(s_stablecoin), FEE_COLLECTOR, MOC_PROXY, _feeSettings(), address(this)
        );
    }

    function testIdleDexRejectsZeroDcaManager() public {
        vm.expectRevert(IDcaManagerAccessControl.DcaManagerAccessControl__ZeroDcaManager.selector);
        new IdleHandlerDex(
            address(0),
            address(s_stablecoin),
            _uniswapSettings(),
            FEE_COLLECTOR,
            _feeSettings(),
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            address(this)
        );
    }

    function testLayerBankMocRejectsZeroDcaManager() public {
        vm.expectRevert(IDcaManagerAccessControl.DcaManagerAccessControl__ZeroDcaManager.selector);
        new LayerBankDocHandlerMoc(
            address(0), address(s_stablecoin), s_aToken, FEE_COLLECTOR, MOC_PROXY, _feeSettings(), address(this)
        );
    }

    function testLayerBankDexRejectsZeroDcaManager() public {
        vm.expectRevert(IDcaManagerAccessControl.DcaManagerAccessControl__ZeroDcaManager.selector);
        new LayerBankHandlerDex(
            address(0),
            address(s_stablecoin),
            s_aToken,
            _uniswapSettings(),
            FEE_COLLECTOR,
            _feeSettings(),
            DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT,
            address(this)
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _assertFeeEvents(Vm.Log[] memory logs, address handler) private {
        IPurchaseFees fees = IPurchaseFees(handler);
        IPurchaseFees.FeeSettings memory settings = fees.getFeeSettings();
        Vm.Log memory collector = _onlyLog(logs, handler, IPurchaseFees.PurchaseFees__FeeCollectorAddressSet.selector);
        assertEq(address(uint160(uint256(collector.topics[1]))), fees.getFeeCollector());
        assertEq(fees.getFeeCollector(), FEE_COLLECTOR);
        Vm.Log memory minRate = _onlyLog(logs, handler, IPurchaseFees.PurchaseFees__MinFeeRateSet.selector);
        assertEq(abi.decode(minRate.data, (uint256)), settings.minFeeRate);
        Vm.Log memory maxRate = _onlyLog(logs, handler, IPurchaseFees.PurchaseFees__MaxFeeRateSet.selector);
        assertEq(abi.decode(maxRate.data, (uint256)), settings.maxFeeRate);
        Vm.Log memory bound = _onlyLog(logs, handler, IPurchaseFees.PurchaseFees__PurchaseLowerBoundSet.selector);
        assertEq(abi.decode(bound.data, (uint256)), settings.feePurchaseLowerBound);
    }

    /// @dev The one log with this signature, which must come from `emitter`.
    function _onlyLog(Vm.Log[] memory logs, address emitter, bytes32 topic0) private returns (Vm.Log memory found) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != topic0) continue;
            assertEq(logs[i].emitter, emitter, "configuration event from another contract");
            found = logs[i];
            ++count;
        }
        assertEq(count, 1, "configuration event not logged exactly once");
    }

    function _feeSettings() private pure returns (IPurchaseFees.FeeSettings memory) {
        return IPurchaseFees.FeeSettings({
            minFeeRate: MIN_FEE_RATE, maxFeeRate: MAX_FEE_RATE_TEST, feePurchaseLowerBound: FEE_PURCHASE_LOWER_BOUND
        });
    }

    function _uniswapSettings() private view returns (IPurchaseUniswap.UniswapSettings memory) {
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000;
        return IPurchaseUniswap.UniswapSettings({
            wrbtc: IWRBTC(address(s_wrBtc)),
            swapRouter: IUniswapV3SwapRouter(SWAP_ROUTER),
            swapIntermediateTokens: new address[](0),
            swapPoolFeeRates: poolFeeRates,
            mocOracle: ICoinPairPrice(address(s_oracle))
        });
    }
}
