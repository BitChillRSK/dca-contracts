// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";

interface ITropykusComptroller {
    function mintGuardianPaused(address cToken) external view returns (bool);
    function mintAllowed(address cToken, address minter, uint256 mintAmount) external returns (uint256);
}

/**
 * @title KusdrifMintPauseProbe
 * @notice Decision 3 of R36: kUSDRIF mint is paused on the live tip (kToken error `C2`), same as kDOC.
 * @dev Runs on `make fork-sovryn` (chain tip). Skips on Anvil and on the Tropykus pin
 *      (`FORK_BLOCK_TROPYKUS=8700000`), which is before the measured pause window.
 */
contract KusdrifMintPauseProbe is Test {
    address internal constant KUSDRIF = 0xDdf3CE45fcf080DF61ee61dac5Ddefef7ED4F46C;
    address internal constant COMPTROLLER = 0x962308fEf8edFaDD705384840e7701F8f39eD0c0;
    uint256 internal constant TROPYKUS_MINT_PAUSE_END = 8740674;

    function setUp() public {
        if (KUSDRIF.code.length == 0) vm.skip(true);
        if (block.number < TROPYKUS_MINT_PAUSE_END) vm.skip(true);
    }

    function test_kusdrif_mintIsPausedWithC2() public {
        assertTrue(ITropykusComptroller(COMPTROLLER).mintGuardianPaused(KUSDRIF), "kUSDRIF mintGuardianPaused");
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "C2"));
        ITropykusComptroller(COMPTROLLER).mintAllowed(KUSDRIF, address(1), 1);
    }
}
