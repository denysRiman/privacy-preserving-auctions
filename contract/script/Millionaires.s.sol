// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {MillionairesProblem} from "../src/MillionairesProblem.sol";

contract MillionairesScript is Script {
    function _canonicalLayoutRoot(bytes32 circuitId) internal pure returns (bytes32) {
        if (circuitId == hex"4b38f6018cce9cce241946cda9af3509db31d6ef0f4b17e25e4f589faa71da7e") {
            return hex"d15d9ca7dfc1e2a4c47eb4812eb9d08761688c436aad557449954b91df138521";
        }
        if (circuitId == hex"50c5a6de5fef89c8d930a3e3bf04578efff567e5c713693ba584c1c47d27eb9a") {
            return hex"35507759e0f8a618b62ca6fd10193e20c63ba04b5e3f520eff66af46b12c301d";
        }
        revert("Unsupported circuitId");
    }

    function run() public {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address bob = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        address receiver = bob;
        bytes32 ensNamehash = vm.envOr("ENS_NAMEHASH", bytes32(keccak256(abi.encodePacked("example.eth"))));
        address ensAdapter = vm.envOr("ENS_ADAPTER", address(0x1000000000000000000000000000000000000001));
        bytes32 circuitId = vm.envOr(
            "CIRCUIT_ID",
            bytes32(hex"4b38f6018cce9cce241946cda9af3509db31d6ef0f4b17e25e4f589faa71da7e")
        );
        uint16 bitWidth = 8;
        bytes32 layoutRoot = _canonicalLayoutRoot(circuitId);

        vm.startBroadcast(pk);
        new MillionairesProblem(bob, receiver, ensNamehash, ensAdapter, circuitId, layoutRoot, bitWidth);
        vm.stopBroadcast();
    }
}
