// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {PurchaseUniswap} from "../../src/PurchaseUniswap.sol";
import {FeeHandler} from "../../src/FeeHandler.sol";
import {DcaManagerAccessControl} from "../../src/DcaManagerAccessControl.sol";
import {IPurchaseUniswap} from "../../src/interfaces/IPurchaseUniswap.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {IFeeHandler} from "../../src/interfaces/IFeeHandler.sol";
import {ICoinPairPrice} from "../../src/interfaces/ICoinPairPrice.sol";
import {IWRBTC} from "../../src/interfaces/IWRBTC.sol";
import {ISwapRouter02} from "@uniswap/swap-router-contracts/contracts/interfaces/ISwapRouter02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockMocOracle} from "../mocks/MockMocOracle.sol";
import "../../script/Constants.sol";
import {ownableUnauthorized} from "../utils/OzRevert.sol";

contract PurchaseUniswapSettingsTest is DcaDappTest {
    uint256 private constant SLIPPAGE_SLOT = 6;

    event PurchaseUniswap_AmountOutMinimumPercentUpdated(uint256 oldValue, uint256 newValue);
    event PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(uint256 oldValue, uint256 newValue);
    event PurchaseUniswap_OracleUpdated(address oldOracle, address newOracle);
    event PurchaseUniswap_NewPathSet(address[] indexed intermediateTokens, uint24[] indexed poolFeeRates, bytes indexed newPath);

    function setUp() public override {
        super.setUp();
    }

    ///////////////////////////////
    /// Slippage Settings Tests ///
    ///////////////////////////////

    /// @dev The two 1e18-scaled percents are uint128s in one slot. The Dex handler's storage is
    ///      Ownable2Step (0, 1), the fee word and bounds (2, 3), the packed user positions (4),
    ///      the oracle (5), then this pair.
    function testSlippagePercentsShareOneSlot() public onlyDexSwaps {
        uint256 percent = IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumPercent();
        uint256 safetyCheck = IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumSafetyCheck();

        uint256 packed = uint256(vm.load(address(stablecoinHandler), bytes32(SLIPPAGE_SLOT)));
        assertEq(uint128(packed), percent, "the swap-time percent is not the low half of the slot");
        assertEq(uint128(packed >> 128), safetyCheck, "the safety check is not the high half of the slot");

        // A write through the setter lands in the same word.
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(0.996 ether);

        packed = uint256(vm.load(address(stablecoinHandler), bytes32(SLIPPAGE_SLOT)));
        assertEq(uint128(packed), 0.996 ether, "the setter did not write the low half");
        assertEq(uint128(packed >> 128), safetyCheck, "the setter disturbed the safety check");
    }

    function testSlippageSettings() public onlyDexSwaps {
        // Get the initial values
        uint256 initialPercent = IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumPercent();
        uint256 initialSafetyCheck = IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumSafetyCheck();
        
        // Verify initial values - should match what we set in the contract
        assertEq(initialPercent, DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT, "Wrong initial slippage percent");
        assertEq(initialSafetyCheck, DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK, "Wrong initial safety check");
        
        // Set new values
        uint256 newPercent = DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT * 999 / 1000;
        uint256 newSafetyCheck = DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK * 999 / 1000;

        // Expect the event with the correct parameters
        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(initialPercent, newPercent);

        // Set the new value
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(newPercent);
        
        // Verify the new value was set
        assertEq(
            IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumPercent(), 
            newPercent, 
            "Slippage percent should be updated"
        );


        // Expect the event with the correct parameters
        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(initialSafetyCheck, newSafetyCheck);
        
        // Execute the function that should emit the event
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumSafetyCheck(newSafetyCheck);

        // Verify the new value was set
        assertEq(
            IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumSafetyCheck(), 
            newSafetyCheck, 
            "Safety check should be updated"
        );
    }
    
    function testSetAmountOutMinimumPercentRevertsIfTooHigh() public onlyDexSwaps {
        // Try to set slippage too high (over 100%)
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentTooHigh.selector);
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(1.01e18);
    }
    
    function testSetAmountOutMinimumPercentRevertsIfTooLow() public onlyDexSwaps {
        // Get the safety check value
        uint256 safetyCheck = IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumSafetyCheck();
        
        // Try to set slippage below safety check
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentTooLow.selector);
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(safetyCheck - 1);
    }
    
    function testSetAmountOutMinimumSafetyCheck() public onlyDexSwaps {
        // Set new safety check
        uint256 newSafetyCheck = DEFAULT_AMOUNT_OUT_MINIMUM_SAFETY_CHECK * 90 / 100;
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumSafetyCheck(newSafetyCheck);
        
        // Verify it was set
        assertEq(
            IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumSafetyCheck(), 
            newSafetyCheck, 
            "Safety check should be updated"
        );
        
        // Now we can set a lower slippage percent
        uint256 newPercent = DEFAULT_AMOUNT_OUT_MINIMUM_PERCENT * 90 / 100;
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(newPercent);
        
        // Verify it was set
        assertEq(
            IPurchaseUniswap(address(stablecoinHandler)).getAmountOutMinimumPercent(), 
            newPercent, 
            "Slippage percent should be updated to lower value"
        );
    }
    
    function testSetAmountOutMinimumSafetyCheckRevertsIfTooHigh() public onlyDexSwaps {
        // Try to set safety check too high
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumSafetyCheckTooHigh.selector);
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumSafetyCheck(1.01e18);
    }

    function testSetAmountOutMinimumSafetyCheckRevertsIfAboveCurrentPercent() public onlyDexSwaps {
        IPurchaseUniswap dex = IPurchaseUniswap(address(stablecoinHandler));
        uint256 percent = dex.getAmountOutMinimumPercent();
        uint256 safetyBefore = dex.getAmountOutMinimumSafetyCheck();

        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__AmountOutMinimumPercentTooLow.selector);
        vm.prank(OWNER);
        dex.setAmountOutMinimumSafetyCheck(percent + 1);

        assertEq(dex.getAmountOutMinimumSafetyCheck(), safetyBefore, "Safety check must be unchanged on revert");
        assertEq(dex.getAmountOutMinimumPercent(), percent, "Percent must be unchanged on revert");
    }

    function testSetAmountOutMinimumPercentAllowsEqualityWithSafety() public onlyDexSwaps {
        IPurchaseUniswap dex = IPurchaseUniswap(address(stablecoinHandler));
        uint256 safetyCheck = dex.getAmountOutMinimumSafetyCheck();
        uint256 percentBefore = dex.getAmountOutMinimumPercent();

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(percentBefore, safetyCheck);

        vm.prank(OWNER);
        dex.setAmountOutMinimumPercent(safetyCheck);

        assertEq(dex.getAmountOutMinimumPercent(), safetyCheck);
        assertEq(dex.getAmountOutMinimumSafetyCheck(), safetyCheck);
    }

    function testSetAmountOutMinimumSafetyCheckAllowsEqualityWithPercent() public onlyDexSwaps {
        IPurchaseUniswap dex = IPurchaseUniswap(address(stablecoinHandler));
        uint256 percent = dex.getAmountOutMinimumPercent();
        uint256 safetyBefore = dex.getAmountOutMinimumSafetyCheck();

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(safetyBefore, percent);

        vm.prank(OWNER);
        dex.setAmountOutMinimumSafetyCheck(percent);

        assertEq(dex.getAmountOutMinimumSafetyCheck(), percent);
        assertEq(dex.getAmountOutMinimumPercent(), percent);
    }

    function testSetSlippageSettingsBothAtHundredPercent() public onlyDexSwaps {
        IPurchaseUniswap dex = IPurchaseUniswap(address(stablecoinHandler));
        uint256 percentBefore = dex.getAmountOutMinimumPercent();
        uint256 safetyBefore = dex.getAmountOutMinimumSafetyCheck();

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(percentBefore, 1 ether);
        vm.prank(OWNER);
        dex.setAmountOutMinimumPercent(1 ether);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(safetyBefore, 1 ether);
        vm.prank(OWNER);
        dex.setAmountOutMinimumSafetyCheck(1 ether);

        assertEq(dex.getAmountOutMinimumPercent(), 1 ether);
        assertEq(dex.getAmountOutMinimumSafetyCheck(), 1 ether);
    }

    function testSetSlippageSettingsRaiseThenLower() public onlyDexSwaps {
        IPurchaseUniswap dex = IPurchaseUniswap(address(stablecoinHandler));
        uint256 initialPercent = dex.getAmountOutMinimumPercent();
        uint256 initialSafety = dex.getAmountOutMinimumSafetyCheck();
        uint256 raisedPercent = (initialPercent + 1 ether) / 2;
        uint256 raisedSafety = (initialSafety + raisedPercent) / 2;

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(initialPercent, raisedPercent);
        vm.prank(OWNER);
        dex.setAmountOutMinimumPercent(raisedPercent);
        assertEq(dex.getAmountOutMinimumPercent(), raisedPercent);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(initialSafety, raisedSafety);
        vm.prank(OWNER);
        dex.setAmountOutMinimumSafetyCheck(raisedSafety);
        assertEq(dex.getAmountOutMinimumSafetyCheck(), raisedSafety);

        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumPercentUpdated(raisedPercent, raisedSafety);
        vm.prank(OWNER);
        dex.setAmountOutMinimumPercent(raisedSafety);
        assertEq(dex.getAmountOutMinimumPercent(), raisedSafety);

        uint256 loweredSafety = raisedSafety / 2;
        vm.expectEmit(true, true, true, true);
        emit PurchaseUniswap_AmountOutMinimumSafetyCheckUpdated(raisedSafety, loweredSafety);
        vm.prank(OWNER);
        dex.setAmountOutMinimumSafetyCheck(loweredSafety);
        assertEq(dex.getAmountOutMinimumSafetyCheck(), loweredSafety);
    }
    
    function testOnlyOwnerCanSetSlippageSettings() public onlyDexSwaps {
        // Try to set slippage as non-owner
        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(0.98e18);
        
        // Try to set safety check as non-owner
        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumSafetyCheck(0.95e18);
    }

    ////////////////////////////
    /// Oracle Update Tests ////
    ////////////////////////////

    function testUpdateOracle() public onlyDexSwaps {
        // Create a new mock oracle
        MockMocOracle newMocOracle = new MockMocOracle();
        
        // Store the current oracle for comparison
        ICoinPairPrice currentOracle = IPurchaseUniswap(address(stablecoinHandler)).getMocOracle();
        address oldOracleAddress = address(currentOracle);
        
        // Expect the event with the correct parameters
        vm.expectEmit(false, false, false, true);
        emit PurchaseUniswap_OracleUpdated(oldOracleAddress, address(newMocOracle));

        // Update the oracle
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).updateMocOracle(address(newMocOracle));
        
        // Verify the oracle was updated
        address updatedOracleAddress = address(IPurchaseUniswap(address(stablecoinHandler)).getMocOracle());
        assertEq(updatedOracleAddress, address(newMocOracle), "Oracle address should be updated");
        assertNotEq(updatedOracleAddress, oldOracleAddress, "Oracle address should be different from the old one");
    }
    
    function testUpdateOracleRevertsIfZeroAddress() public onlyDexSwaps {
        // Try to update with zero address
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__InvalidOracleAddress.selector);
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).updateMocOracle(address(0));
    }
    
    function testOnlyOwnerCanUpdateOracle() public onlyDexSwaps {
        // Create a new mock oracle
        MockMocOracle newMocOracle = new MockMocOracle();
        
        // Try to update oracle as non-owner
        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).updateMocOracle(address(newMocOracle));
    }

    ////////////////////////////
    /// Price Validation Tests //
    ////////////////////////////

    function testOutdatedPriceRevertsSwap() public onlyDexSwaps {
        // Setup: First perform the necessary setup for the test
        vm.startPrank(USER);
        stablecoin.approve(address(stablecoinHandler), AMOUNT_TO_DEPOSIT);
        uint64 scheduleId = dcaManager.getDcaSchedule(USER, address(stablecoin), SCHEDULE_INDEX).scheduleId;
        dcaManager.updatePurchaseAmount(address(stablecoin), SCHEDULE_INDEX, scheduleId, AMOUNT_TO_SPEND);
        vm.stopPrank();
        
        // Create a mock oracle that returns invalid prices
        MockMocOracle invalidOracle = new MockMocOracle();
        invalidOracle.setInvalidPrice();
        
        // Update the oracle to use our invalid one
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).updateMocOracle(address(invalidOracle));
        
        
        // Try to make a purchase, which should revert due to invalid price
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__OutdatedPrice.selector);
        buyRbtcOne(USER, SCHEDULE_INDEX, scheduleId, AMOUNT_TO_SPEND);
    }

    ////////////////////////////
    /// Purchase Path Tests ////
    ////////////////////////////

    function testSetPurchasePath() public onlyDexSwaps {
        // Create test data for new path
        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = makeAddr("newIntermediateToken");
        
        uint24[] memory poolFeeRates = new uint24[](2);
        poolFeeRates[0] = 100; // 0.01%
        poolFeeRates[1] = 300; // 0.03%
        
        // Get the current path
        bytes memory oldPath = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        
        // Expect the event with the correct parameters
        vm.expectEmit(true, true, false, false);
        emit PurchaseUniswap_NewPathSet(intermediateTokens, poolFeeRates, oldPath);

        // Set the new path
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(intermediateTokens, poolFeeRates);
        
        // Verify the path was updated
        bytes memory newPath = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        assertNotEq(keccak256(newPath), keccak256(oldPath), "Path should be updated");
    }
    
    function testSetPurchasePathRevertsWithWrongArrayLengths() public onlyDexSwaps {
        // Create test data with mismatched lengths
        address[] memory intermediateTokens = new address[](2);
        intermediateTokens[0] = makeAddr("token1");
        intermediateTokens[1] = makeAddr("token2");
        
        uint24[] memory poolFeeRates = new uint24[](2); // Should be 3 for 2 intermediate tokens
        poolFeeRates[0] = 100;
        poolFeeRates[1] = 300;
        
        // Try to set the path with mismatched arrays
        vm.expectRevert(abi.encodeWithSelector(
            IPurchaseUniswap.PurchaseUniswap__WrongNumberOfTokensOrFeeRates.selector, 
            intermediateTokens.length, 
            poolFeeRates.length
        ));
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(intermediateTokens, poolFeeRates);
    }
    
    function testOnlyOwnerCanSetPurchasePath() public onlyDexSwaps {
        // Create test data
        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = makeAddr("token");
        
        uint24[] memory poolFeeRates = new uint24[](2);
        poolFeeRates[0] = 100;
        poolFeeRates[1] = 300;
        
        // Try to set path as non-owner
        vm.expectRevert(ownableUnauthorized(USER));
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(intermediateTokens, poolFeeRates);
    }

    function testSwapPathStartsWithPurchaseToken() public onlyDexSwaps {
        bytes memory initialPath = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        assertEq(_firstTokenInPath(initialPath), address(stablecoin), "initial path must start with _purchaseToken()");

        address[] memory intermediateTokens = new address[](1);
        intermediateTokens[0] = makeAddr("r31Intermediate");
        uint24[] memory poolFeeRates = new uint24[](2);
        poolFeeRates[0] = 100;
        poolFeeRates[1] = 300;

        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(intermediateTokens, poolFeeRates);

        bytes memory updatedPath = IPurchaseUniswap(address(stablecoinHandler)).getSwapPath();
        assertEq(_firstTokenInPath(updatedPath), address(stablecoin), "updated path must start with _purchaseToken()");
    }

    function _firstTokenInPath(bytes memory path) private pure returns (address token) {
        require(path.length >= 20, "path too short");
        uint256 packed;
        for (uint256 i; i < 20; ++i) {
            packed = (packed << 8) | uint8(path[i]);
        }
        return address(uint160(packed));
    }
}

/**
 * @notice Proves a reversed `is PurchaseUniswap, LendingErc20Handler` (or Idle) list cannot deploy:
 *         `_purchaseToken()` is still `address(0)` when the Uniswap constructor builds the path.
 */
contract ZeroTokenPurchaseUniswap is PurchaseUniswap {
    constructor(
        address dcaManagerAddress,
        address feeCollector,
        IFeeHandler.FeeSettings memory feeSettings,
        UniswapSettings memory uniswapSettings,
        uint256 amountOutMinimumPercent,
        uint256 amountOutMinimumSafetyCheck
    )
        FeeHandler(feeCollector, feeSettings, msg.sender)
        DcaManagerAccessControl(dcaManagerAddress)
        PurchaseUniswap(uniswapSettings, amountOutMinimumPercent, amountOutMinimumSafetyCheck)
    {}

    function _purchaseToken() internal pure override returns (IERC20) {
        return IERC20(address(0));
    }

    function _retrieveStablecoin(address, uint256) internal pure override returns (uint256) {
        return 0;
    }

    function _batchRetrieveStablecoin(address[] memory, uint256[] memory, uint256)
        internal
        pure
        override
        returns (uint256)
    {
        return 0;
    }
}

contract PurchaseUniswapZeroTokenTest is Test {
    function testConstructorRevertsWhenPurchaseTokenIsZero() public {
        IFeeHandler.FeeSettings memory feeSettings = IFeeHandler.FeeSettings({
            minFeeRate: 100,
            maxFeeRate: 100,
            feePurchaseLowerBound: 1000 ether,
            feePurchaseUpperBound: 100_000 ether
        });
        address[] memory intermediateTokens = new address[](0);
        uint24[] memory poolFeeRates = new uint24[](1);
        poolFeeRates[0] = 3000;
        IPurchaseUniswap.UniswapSettings memory uniswapSettings = IPurchaseUniswap.UniswapSettings({
            wrBtcToken: IWRBTC(address(0x1)),
            swapRouter02: ISwapRouter02(address(0x2)),
            swapIntermediateTokens: intermediateTokens,
            swapPoolFeeRates: poolFeeRates,
            mocOracle: ICoinPairPrice(address(0x3))
        });

        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__ZeroPurchaseToken.selector);
        new ZeroTokenPurchaseUniswap(
            address(this), address(0xFEE), feeSettings, uniswapSettings, 0.997 ether, 0.99 ether
        );
    }
}
