// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {DcaDappTest} from "../../unit/DcaDappTest.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IiSusdToken} from "../../../src/sovryn/IiSusdToken.sol";
import {BPS_DENOMINATOR, DOC_HOLDER} from "../../Constants.sol";

interface IExitFeeControllerView {
    function exitFeeEnabled() external view returns (bool);
    function feeReceiver() external view returns (address);
}

interface ISovrynProtocolExitFee {
    function exitFeeController() external view returns (address);
}

/// @dev Live Rootstock fork probe for SIP-0094's 0.1% Perimeter Fee.
/// Excluded from `make check` / `make fork-*` / CI (`test/mainnet-debug/**`).
/// Run: `make probe-sovryn-exit-fee` (see README.md in this folder).
///
/// Primary instrument: burn gross return vs DOC actually received. Do not trust
/// `exitFeeEnabled` / the historical ExitFeeVault alone - as of tip ~9,219,745 those
/// views were stale while burns still haircut ~10 bps to `LIVE_FEE_SINK`.
contract SovrynExitFeeDirectBurnProbe is Test {
    address constant DOC = 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db;
    address constant I_SUSD = 0xd8D25f03EBbA94E15Df2eD4d6D38276B595593c1;
    address constant EXIT_FEE_CONTROLLER = 0x8C1abf364Bf214E41221562693BD9Fb26D6Fa563;
    /// @dev Historical SIP-0094 vault from early Perimeter wiring. Tip burns no longer fund it.
    address constant LEGACY_EXIT_FEE_VAULT = 0x2ba389B021fA4A5F50cc1758EFD23Ca066d0Be08;
    /// @dev Observed live fee sink on tip (2026-09-07): DOC `Transfer` of ~10 bps on each iSUSD burn.
    address constant LIVE_FEE_SINK = 0xDDE75f75ff33Aa802f2316cCAe2bE77823fc6f9B;
    address constant SOVRYN_PROTOCOL = 0x5A0D867e0D70Fcc6Ade25C3F1B89d618b5B4Eaa7;
    uint256 constant DEPOSIT_AMOUNT = 1000 ether;

    function test_controllerFlagAndVault() external view {
        bool enabled = IExitFeeControllerView(EXIT_FEE_CONTROLLER).exitFeeEnabled();
        address receiver = IExitFeeControllerView(EXIT_FEE_CONTROLLER).feeReceiver();
        uint256 legacyVaultDoc = IERC20(DOC).balanceOf(LEGACY_EXIT_FEE_VAULT);
        uint256 liveSinkDoc = IERC20(DOC).balanceOf(LIVE_FEE_SINK);

        console2.log("block", block.number);
        console2.log("exitFeeEnabled (may be stale)", enabled);
        console2.log("controller.feeReceiver (may be stale)", receiver);
        console2.log("legacy ExitFeeVault DOC balance", legacyVaultDoc);
        console2.log("live fee sink DOC balance", liveSinkDoc);
        console2.log("live fee sink", LIVE_FEE_SINK);

        try ISovrynProtocolExitFee(SOVRYN_PROTOCOL).exitFeeController() returns (address ctrl) {
            console2.log("sovrynProtocol.exitFeeController", ctrl);
        } catch {
            console2.log("sovrynProtocol.exitFeeController: reverted (selector not active)");
        }
    }

    function testDirectIsusdBurn_printFeeSplit() external {
        vm.startPrank(DOC_HOLDER);
        IERC20(DOC).approve(I_SUSD, DEPOSIT_AMOUNT);
        IiSusdToken(I_SUSD).mint(DOC_HOLDER, DEPOSIT_AMOUNT);
        uint256 shares = IERC20(I_SUSD).balanceOf(DOC_HOLDER);

        uint256 userDocBefore = IERC20(DOC).balanceOf(DOC_HOLDER);
        uint256 legacyVaultBefore = IERC20(DOC).balanceOf(LEGACY_EXIT_FEE_VAULT);
        uint256 liveSinkBefore = IERC20(DOC).balanceOf(LIVE_FEE_SINK);
        address controllerReceiver = IExitFeeControllerView(EXIT_FEE_CONTROLLER).feeReceiver();
        uint256 controllerReceiverBefore = IERC20(DOC).balanceOf(controllerReceiver);

        uint256 returned = IiSusdToken(I_SUSD).burn(DOC_HOLDER, shares);
        uint256 received = IERC20(DOC).balanceOf(DOC_HOLDER) - userDocBefore;
        uint256 legacyVaultDelta = IERC20(DOC).balanceOf(LEGACY_EXIT_FEE_VAULT) - legacyVaultBefore;
        uint256 liveSinkDelta = IERC20(DOC).balanceOf(LIVE_FEE_SINK) - liveSinkBefore;
        uint256 controllerReceiverDelta = IERC20(DOC).balanceOf(controllerReceiver) - controllerReceiverBefore;
        vm.stopPrank();

        uint256 haircut = returned > received ? returned - received : 0;
        uint256 haircutBps = returned > 0 ? (haircut * BPS_DENOMINATOR) / returned : 0;

        console2.log("burn returned (gross)", returned);
        console2.log("DOC received (net)", received);
        console2.log("haircut DOC", haircut);
        console2.log("haircut bps (approx)", haircutBps);
        console2.log("10 bps of gross would be", returned / 1000);
        console2.log("legacy ExitFeeVault DOC delta", legacyVaultDelta);
        console2.log("live fee sink DOC delta", liveSinkDelta);
        console2.log("controller.feeReceiver DOC delta", controllerReceiverDelta);

        // Primary canary: measured cash, not the controller flag.
        if (haircutBps >= 9 && haircutBps <= 11) {
            console2.log("FEE LIVE at ~10 bps (gross vs net)");
            assertGt(liveSinkDelta, 0, "10 bps haircut with zero live-sink delta; update LIVE_FEE_SINK");
        } else if (haircut == 0 || haircut <= 2) {
            console2.log("FEE OFF (gross ~= net within wei dust)");
        } else {
            console2.log("UNEXPECTED haircut - investigate before trusting this probe");
        }
    }
}

/// @dev Same withdrawal the unit suite runs (`dcaManager.withdrawToken` → handler `burn`).
/// DcaDappTest.setUp reads the MoC oracle, which currently reverts
/// `Wrong lastPublicationBlock` on Anvil, so that one view is mocked.
contract SovrynExitFeeWithdrawalProbe is DcaDappTest {
    address constant LEGACY_EXIT_FEE_VAULT = 0x2ba389B021fA4A5F50cc1758EFD23Ca066d0Be08;
    address constant LIVE_FEE_SINK = 0xDDE75f75ff33Aa802f2316cCAe2bE77823fc6f9B;

    function setUp() public override {
        vm.mockCall(MOC_ORACLE_MAINNET, abi.encodeWithSignature("getPrice()"), abi.encode(uint256(50_000e18)));
        super.setUp();
    }

    function testStablecoinWithdrawal_printSovrynFeeSplit() external {
        address doc = address(stablecoin);
        address iSusd = address(shareToken);
        address handler = address(stablecoinHandler);

        uint256 legacyVaultBefore = IERC20(doc).balanceOf(LEGACY_EXIT_FEE_VAULT);
        uint256 liveSinkBefore = IERC20(doc).balanceOf(LIVE_FEE_SINK);
        uint256 userDocBefore = IERC20(doc).balanceOf(USER);
        uint256 iSusdBefore = IERC20(iSusd).balanceOf(handler);

        super.withdrawStablecoin();

        uint256 paid = IERC20(doc).balanceOf(USER) - userDocBefore;
        console2.log("iSUSD burned (handler)", iSusdBefore - IERC20(iSusd).balanceOf(handler));
        console2.log("DOC paid to user", paid);
        console2.log("legacy ExitFeeVault DOC delta", IERC20(doc).balanceOf(LEGACY_EXIT_FEE_VAULT) - legacyVaultBefore);
        console2.log("live fee sink DOC delta", IERC20(doc).balanceOf(LIVE_FEE_SINK) - liveSinkBefore);
        console2.log("requested withdrawal", AMOUNT_TO_DEPOSIT);
        console2.log("10 bps of requested would be", AMOUNT_TO_DEPOSIT / 1000);
        if (AMOUNT_TO_DEPOSIT > paid) {
            console2.log("haircut DOC", AMOUNT_TO_DEPOSIT - paid);
            console2.log(
                "haircut bps (approx)",
                ((AMOUNT_TO_DEPOSIT - paid) * BPS_DENOMINATOR) / AMOUNT_TO_DEPOSIT
            );
        }
    }
}
