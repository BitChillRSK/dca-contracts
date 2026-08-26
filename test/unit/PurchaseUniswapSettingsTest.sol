// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {DcaDappTest} from "./DcaDappTest.t.sol";
import {IPurchaseUniswap} from "../../src/interfaces/IPurchaseUniswap.sol";
import {IPurchaseRbtc} from "../../src/interfaces/IPurchaseRbtc.sol";
import {ICoinPairPrice} from "../../src/interfaces/ICoinPairPrice.sol";
import {MockMocOracle} from "../mocks/MockMocOracle.sol";
import "../../script/Constants.sol";

contract PurchaseUniswapSettingsTest is DcaDappTest {

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
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).setAmountOutMinimumPercent(0.98e18);
        
        // Try to set safety check as non-owner
        vm.expectRevert("Ownable: caller is not the owner");
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
        vm.expectRevert("Ownable: caller is not the owner");
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
        bytes32 scheduleId = dcaManager.getMyScheduleId(address(stablecoin), SCHEDULE_INDEX);
        dcaManager.setPurchaseAmount(address(stablecoin), SCHEDULE_INDEX, scheduleId, AMOUNT_TO_SPEND);
        vm.stopPrank();
        
        // Create a mock oracle that returns invalid prices
        MockMocOracle invalidOracle = new MockMocOracle();
        invalidOracle.setInvalidPrice();
        
        // Update the oracle to use our invalid one
        vm.prank(OWNER);
        IPurchaseUniswap(address(stablecoinHandler)).updateMocOracle(address(invalidOracle));
        
        
        // Try to make a purchase, which should revert due to invalid price
        vm.expectRevert(IPurchaseUniswap.PurchaseUniswap__OutdatedPrice.selector);
        vm.prank(SWAPPER);
        dcaManager.buyRbtc(USER, address(stablecoin), SCHEDULE_INDEX, scheduleId);
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
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(USER);
        IPurchaseUniswap(address(stablecoinHandler)).setPurchasePath(intermediateTokens, poolFeeRates);
    }
}
