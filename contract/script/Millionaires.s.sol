// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {MillionairesProblem} from "../src/MillionairesProblem.sol";

contract MillionairesScript is Script {
    function run() public {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address bob = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

        vm.startBroadcast(pk);
        new MillionairesProblem(bob);
        vm.stopBroadcast();
    }
}