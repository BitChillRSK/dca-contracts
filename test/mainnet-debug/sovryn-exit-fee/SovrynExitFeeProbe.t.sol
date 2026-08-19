// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test, console2} from "forge-std/Test.sol";
import {DcaDappTest} from "../../unit/DcaDappTest.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IiSusdToken} from "../../../src/sovryn/IiSusdToken.sol";
import {DOC_HOLDER} from "../../../script/Constants.sol";

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
contract SovrynExitFeeDirectBurnProbe is Test {
    address constant DOC = 0xe700691dA7b9851F2F35f8b8182c69c53CcaD9Db;
    address constant I_SUSD = 0xd8D25f03EBbA94E15Df2eD4d6D38276B595593c1;
    address constant EXIT_FEE_CONTROLLER = 0x8C1abf364Bf214E41221562693BD9Fb26D6Fa563;
    address constant EXIT_FEE_VAULT = 0x2ba389B021fA4A5F50cc1758EFD23Ca066d0Be08;
    address constant SOVRYN_PROTOCOL = 0x5A0D867e0D70Fcc6Ade25C3F1B89d618b5B4Eaa7;
    uint256 constant DEPOSIT_AMOUNT = 1000 ether;

    function test_controllerFlagAndVault() external view {
        bool enabled = IExitFeeControllerView(EXIT_FEE_CONTROLLER).exitFeeEnabled();
        address receiver = IExitFeeControllerView(EXIT_FEE_CONTROLLER).feeReceiver();
        uint256 vaultDoc = IERC20(DOC).balanceOf(EXIT_FEE_VAULT);

        console2.log("block", block.number);
        console2.log("exitFeeEnabled", enabled);
        console2.log("feeReceiver", receiver);
        console2.log("ExitFeeVault DOC balance", vaultDoc);

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
        uint256 vaultDocBefore = IERC20(DOC).balanceOf(EXIT_FEE_VAULT);
        uint256 returned = IiSusdToken(I_SUSD).burn(DOC_HOLDER, shares);
        uint256 received = IERC20(DOC).balanceOf(DOC_HOLDER) - userDocBefore;
        uint256 vaultDelta = IERC20(DOC).balanceOf(EXIT_FEE_VAULT) - vaultDocBefore;
        vm.stopPrank();

        uint256 haircutBps = returned > received ? ((returned - received) * 10_000) / returned : 0;
        console2.log("burn returned (gross)", returned);
        console2.log("DOC received (net)", received);
        console2.log("ExitFeeVault DOC delta", vaultDelta);
        console2.log("haircut bps (approx)", haircutBps);
        console2.log("10 bps of gross would be", returned / 1000);
    }
}

/// @dev Same withdrawal the unit suite runs (`dcaManager.withdrawToken` → handler `burn`).
/// DcaDappTest.setUp reads the MoC oracle, which currently reverts
/// `Wrong lastPublicationBlock` on Anvil, so that one view is mocked.
contract SovrynExitFeeWithdrawalProbe is DcaDappTest {
    address constant EXIT_FEE_VAULT = 0x2ba389B021fA4A5F50cc1758EFD23Ca066d0Be08;

    function setUp() public override {
        vm.mockCall(MOC_ORACLE_MAINNET, abi.encodeWithSignature("getPrice()"), abi.encode(uint256(50_000e18)));
        super.setUp();
    }

    function testStablecoinWithdrawal_printSovrynFeeSplit() external {
        address doc = address(stablecoin);
        address iSusd = address(lendingToken);
        address handler = address(stablecoinHandler);

        uint256 vaultDocBefore = IERC20(doc).balanceOf(EXIT_FEE_VAULT);
        uint256 userDocBefore = IERC20(doc).balanceOf(USER);
        uint256 iSusdBefore = IERC20(iSusd).balanceOf(handler);

        super.withdrawStablecoin();

        console2.log("iSUSD burned (handler)", iSusdBefore - IERC20(iSusd).balanceOf(handler));
        console2.log("DOC paid to user", IERC20(doc).balanceOf(USER) - userDocBefore);
        console2.log("ExitFeeVault DOC delta", IERC20(doc).balanceOf(EXIT_FEE_VAULT) - vaultDocBefore);
        console2.log("requested withdrawal", AMOUNT_TO_DEPOSIT);
        console2.log("10 bps of requested would be", AMOUNT_TO_DEPOSIT / 1000);
    }
}
