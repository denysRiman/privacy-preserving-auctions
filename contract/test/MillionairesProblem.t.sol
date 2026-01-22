// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MillionairesProblem.sol";

contract MillionairesTest is Test {
    MillionairesProblem mp;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

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

        assertEq(uint(mp.currentStage()), 1);
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
        address hacker = makeAddr("hacker");
        vm.deal(hacker, 1 ether);

        vm.prank(hacker);
        vm.expectRevert("Not authorized");
        mp.deposit{value: 1 ether}();
    }

    function test_RefundAfterTimeout() public {
        vm.prank(alice);
        mp.deposit{value: 1 ether}();

        vm.warp(block.timestamp + 1 hours + 1);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        mp.refund();

        assertEq(alice.balance, balanceBefore + 1 ether);
        assertEq(mp.vault(alice), 0);
    }

    function test_SubmitCommitments() public {
        vm.prank(alice);
        mp.deposit{value: 1 ether}();
        vm.prank(bob);
        mp.deposit{value: 1 ether}();

        // 2. Prepare mock commitments for N=10 instances
        MillionairesProblem.InstanceCommitment[10] memory commits;
        for (uint256 i = 0; i < 10; i++) {
            commits[i] = MillionairesProblem.InstanceCommitment({
                comSeed: keccak256(abi.encode(i, "seed")),
                rootGC: keccak256(abi.encode(i, "gc")),
                rootXG: keccak256(abi.encode(i, "xg")),
                rootOT: keccak256(abi.encode(i, "ot")),
                h0: keccak256(abi.encode(i, "h0")),
                h1: keccak256(abi.encode(i, "h1"))
            });
        }

        // 3. Alice submits commitments
        vm.prank(alice);
        mp.submitCommitments(commits);

        // 4. Verify stage transition to Choose
        assertEq(uint(mp.currentStage()), 2);
    }

    function test_AbortPhase2_BobPenalty() public {
        vm.prank(alice);
        mp.deposit{value: 1 ether}();
        vm.prank(bob);
        mp.deposit{value: 1 ether}();

        vm.warp(block.timestamp + 1 hours + 1 seconds);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        mp.abortPhase2();

        // Bob should have his 1 ETH back + Alice's 1 ETH penalty
        assertEq(bob.balance, bobBalanceBefore + 2 ether);
        assertEq(uint(mp.currentStage()), 6); // Stage.Closed (index 6)
    }

    function test_Fail_AliceLateCommitment() public {
        vm.prank(alice);
        mp.deposit{value: 1 ether}();
        vm.prank(bob);
        mp.deposit{value: 1 ether}();

        vm.warp(block.timestamp + 1 hours + 1 seconds);

        MillionairesProblem.InstanceCommitment[10] memory commits;
        vm.prank(alice);
        vm.expectRevert("Commitment deadline missed");
        mp.submitCommitments(commits);
    }

    function test_BobChoice() public {
        vm.prank(alice);
        mp.deposit{value: 1 ether}();
        vm.prank(bob);
        mp.deposit{value: 1 ether}();

        MillionairesProblem.InstanceCommitment[10] memory commits;
        vm.prank(alice);
        mp.submitCommitments(commits);

        vm.prank(bob);
        mp.choose(5);

        assertEq(mp.m(), 5);
        assertEq(uint(mp.currentStage()), 3);

        assertEq(mp.getSOpenLength(), 9);
    }

    function test_AbortPhase3_AlicePenalty() public {
        vm.prank(alice);
        mp.deposit{value: 1 ether}();
        vm.prank(bob);
        mp.deposit{value: 1 ether}();

        MillionairesProblem.InstanceCommitment[10] memory commits;
        vm.prank(alice);
        mp.submitCommitments(commits);

        vm.warp(block.timestamp + 1 hours + 1 seconds);

        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        mp.abortPhase3();

        assertEq(alice.balance, aliceBalanceBefore + 2 ether);
        assertEq(uint(mp.currentStage()), 6); // Stage.Closed
    }
}