// SPDX-License-Identifier: MIT

pragma solidity 0.8.36;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/Test.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./Constants.sol";

contract DeployBase is Script {
    error DeployBase__BroadcastMustBeTestnetOwner(address sender, address expected);
    error DeployBase__DoNotBroadcastAsSafe(address safe);
    error DeployBase__OwnershipTransferPending(address pendingOwner);

    enum Environment {
        LOCAL,
        FORK,
        TESTNET,
        MAINNET
    }

    enum Protocol {
        NONE,
        LAYERBANK,
        SOVRYN,
        TROPYKUS
    }

    struct DeploymentConfig {
        address owner;
        address feeCollector;
        address admin;
        Protocol protocol;
        Environment environment;
    }

    mapping(Environment => address) internal adminAddresses;
    mapping(Environment => address) internal feeCollectorAddresses;
    Environment environment;
    Protocol protocol;
    /// @dev Set in `run()`: the EOA that broadcasts on live nets, `adminAddresses` locally.
    address internal deployOwner;

    constructor() {
        adminAddresses[Environment.LOCAL] = makeAddr(OWNER_STRING);
        adminAddresses[Environment.FORK] = makeAddr(OWNER_STRING);
        adminAddresses[Environment.TESTNET] = TESTNET_OWNER;
        adminAddresses[Environment.MAINNET] = MAINNET_OWNER;

        feeCollectorAddresses[Environment.LOCAL] = makeAddr(FEE_COLLECTOR_STRING);
        feeCollectorAddresses[Environment.FORK] = makeAddr(FEE_COLLECTOR_STRING);
        feeCollectorAddresses[Environment.TESTNET] = TESTNET_FEE_COLLECTOR;
        feeCollectorAddresses[Environment.MAINNET] = MAINNET_FEE_COLLECTOR;

        environment = getEnvironment();
        protocol = getProtocol();

        console.log("Environment:", uint256(environment)); // 0=LOCAL, 1=FORK, 2=TESTNET, 3=MAINNET
        console.log("Protocol:", uint256(protocol)); // 0=NONE, 1=LAYERBANK, 2=SOVRYN, 3=TROPYKUS
        console.log("Chain ID:", block.chainid);
    }

    function getFeeCollector(Environment deploymentEnvironment) internal view returns (address) {
        return feeCollectorAddresses[deploymentEnvironment];
    }

    function getEnvironment() internal view returns (Environment) {
        bool isRealDeployment = vm.envOr("REAL_DEPLOYMENT", false);

        if (isRealDeployment) {
            if (block.chainid == RSK_TESTNET_CHAIN_ID) return Environment.TESTNET;
            if (block.chainid == RSK_MAINNET_CHAIN_ID) return Environment.MAINNET;
            revert("Unsupported chain for deployment");
        }

        if (block.chainid == ANVIL_CHAIN_ID) return Environment.LOCAL;
        if (isFork()) return Environment.FORK;
        revert("Unsupported chain");
    }

    function getProtocol() internal view returns (Protocol) {
        string memory lendingProtocol = vm.envString("LENDING_PROTOCOL");
        if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(NONE_STRING))) {
            return Protocol.NONE;
        }
        if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(LAYERBANK_STRING))) {
            return Protocol.LAYERBANK;
        }
        if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(SOVRYN_STRING))) {
            return Protocol.SOVRYN;
        }
        if (keccak256(abi.encodePacked(lendingProtocol)) == keccak256(abi.encodePacked(TROPYKUS_STRING))) {
            return Protocol.TROPYKUS;
        }
        revert("Invalid lending protocol");
    }

    /**
     * @notice Get the appropriate maximum fee rate based on deployment type
     * @return maxFeeRate The maximum fee rate to use (production has flat 1% fee, test has variable 2% max fee)
     */
    function getMaxFeeRate() public view returns (uint16 maxFeeRate) {
        bool isRealDeployment = vm.envOr("REAL_DEPLOYMENT", false);
        return isRealDeployment ? MAX_FEE_RATE_PRODUCTION : MAX_FEE_RATE_TEST;
    }

    function _isLiveEnvironment() internal view returns (bool) {
        return environment == Environment.TESTNET || environment == Environment.MAINNET;
    }

    /// @dev Owner passed to constructors. Live: the Foundry broadcaster so `onlyOwner` setup
    ///      in the same script succeeds. Local/fork: the configured test owner.
    function _initialOwner() internal view returns (address) {
        return deployOwner != address(0) ? deployOwner : adminAddresses[environment];
    }

    /// @dev Call before `startBroadcast` so a wrong key cannot CREATE then revert on `registerRoute`.
    ///      Testnet requires the exact `TESTNET_OWNER` EOA because that address *is* the owner.
    ///      Mainnet only rejects the Safe: Foundry cannot sign as a Safe, and the deployer EOA is
    ///      not pinned (keystore, Ledger, or a one-off key). Any other EOA becomes owner-until-accept.
    function _assertLiveBroadcastSender(address broadcaster) internal view {
        if (!_isLiveEnvironment()) return;

        address intendedOwner = adminAddresses[environment];
        if (environment == Environment.TESTNET) {
            if (broadcaster != intendedOwner) {
                revert DeployBase__BroadcastMustBeTestnetOwner(broadcaster, intendedOwner);
            }
            return;
        }
        if (broadcaster == intendedOwner) {
            revert DeployBase__DoNotBroadcastAsSafe(intendedOwner);
        }
    }

    function _beginLiveAwareBroadcast(address broadcaster) internal {
        _assertLiveBroadcastSender(broadcaster);
        deployOwner = _isLiveEnvironment() ? broadcaster : adminAddresses[environment];
        // Pass the broadcaster so tests and `forge script --account` both send `onlyOwner`
        // setup from the same address that was used as `initialOwner`.
        if (_isLiveEnvironment()) {
            vm.startBroadcast(broadcaster);
        } else {
            vm.startBroadcast();
        }
    }

    function _requireNoPendingOwner(Ownable2Step governed) internal view {
        address pending = governed.pendingOwner();
        if (pending != address(0)) revert DeployBase__OwnershipTransferPending(pending);
    }

    /// @dev No-op when the broadcaster is already the intended owner (testnet / local).
    ///      On mainnet proposes the Safe; that address must `acceptOwnership`.
    function _proposeFinalOwner(address governed) internal {
        if (governed == address(0)) return;
        address intendedOwner = adminAddresses[environment];
        Ownable2Step ownable = Ownable2Step(governed);
        if (ownable.owner() == intendedOwner) return;
        if (ownable.pendingOwner() == intendedOwner) return;
        ownable.transferOwnership(intendedOwner);
        console.log("Proposed owner for", governed, "->", intendedOwner);
        console.log("Call acceptOwnership() from that address to complete the transfer");
    }
}
