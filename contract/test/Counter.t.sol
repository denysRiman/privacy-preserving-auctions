// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {Counter} from "../src/Counter.sol";

contract CounterTest is Test {
    Counter public counter;

    address public garbler =  address(0x1);
    address public evaluator = address(0x2);

    function setUp() public {
        vm.startPrank(garbler);
        counter = new Counter();
        counter.setNumber(0);
        vm.stopPrank();
    }

    function test_OwnerCanSetNumber() public {
        vm.prank(garbler);
        counter.setNumber(10);
        assertEq(counter.number(), 10);
    }

    function test_NonOwnerCanNotSetNumber(uint256 x) public {
        uint256 numberBefore = counter.number();

        vm.prank(evaluator);
        vm.expectRevert("Not the owner!");
        counter.setNumber(x);

        assertEq(counter.number(), numberBefore);
    }
}
