// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/MillionairesProblem.sol";

contract MillionairesTest is Test {
    MillionairesProblem mp;
    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        vm.prank(alice);
        mp = new MillionairesProblem(bob);
    }

    function test_Deposit() public {
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        mp.deposit{value: 1 ether}();

        assertEq(mp.deposits(alice), 1 ether);
    }
}