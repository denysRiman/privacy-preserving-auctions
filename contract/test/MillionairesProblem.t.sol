// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MillionairesProblem.sol";

contract MillionairesTest is Test {
    MillionairesProblem mp;
    address alice = address(0x1);
    address bob = address(0x2);

    function setUp() public {
        vm.prank(alice);
        mp = new MillionairesProblem(bob);

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function test_SuccessfulDeposits() public {
        vm.prank(alice);
        mp.deposit{value: 1 ether}();
        assertEq(mp.vault(alice), 1 ether);

        vm.prank(bob);
        mp.deposit{value: 1 ether}();
        assertEq(mp.vault(bob), 1 ether);

        assertEq(uint(mp.currentStage()), 2);
    }

    function test_Fail_DoubleDeposit() public {
        vm.startPrank(alice);

        mp.deposit{value: 1 ether}();

        vm.expectRevert("Deposit already exists");
        mp.deposit{value: 1 ether}();

        vm.stopPrank();
    }

    function test_Fail_WrongAmount() public {
        vm.prank(alice);
        vm.expectRevert("Wrong amount");
        mp.deposit{value: 0.5 ether}();
    }

    function test_Fail_Unauthorized() public {
        address hacker = address(0x666);
        vm.deal(hacker, 1 ether);

        vm.prank(hacker);
        vm.expectRevert("Not authorized");
        mp.deposit{value: 1 ether}();
    }
}