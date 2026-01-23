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

    function test_RevealOpenings_Success() public {
        // --- Phase 1: Deposits ---
        vm.prank(alice);
        mp.deposit{value: 1 ether}();
        vm.prank(bob);
        mp.deposit{value: 1 ether}();

        // --- Phase 2: Commitments ---
        // Generate specific seeds to verify them later
        bytes32[] memory realSeeds = new bytes32[](10);
        MillionairesProblem.InstanceCommitment[10] memory commits;

        for (uint256 i = 0; i < 10; i++) {
            realSeeds[i] = keccak256(abi.encodePacked("secret_seed_", i));
            commits[i] = MillionairesProblem.InstanceCommitment({
                comSeed: keccak256(abi.encodePacked(realSeeds[i])),
                rootGC: bytes32(0),
                rootXG: bytes32(0),
                rootOT: bytes32(0),
                h0: bytes32(0),
                h1: bytes32(0)
            });
        }
        vm.prank(alice);
        mp.submitCommitments(commits);

        // --- Phase 3: Choose ---
        uint256 chosenM = 5;
        vm.prank(bob);
        mp.choose(chosenM);

        // --- Phase 4: Reveal ---
        // Prepare arrays for 9 instances (N-1)
        uint256[] memory indices = new uint256[](9);
        bytes32[] memory seedsToReveal = new bytes32[](9);
        uint256 counter = 0;

        for (uint256 i = 0; i < 10; i++) {
            if (i != chosenM) {
                indices[counter] = i;
                seedsToReveal[counter] = realSeeds[i];
                counter++;
            }
        }

        vm.prank(alice);
        mp.revealOpenings(indices, seedsToReveal);

        assertEq(uint(mp.currentStage()), 4); // Stage.Dispute
        assertEq(mp.revealedSeeds(0), realSeeds[0]);
        assertEq(mp.revealedSeeds(chosenM), bytes32(0)); // Evaluation seed must remain hidden
    }

    function test_AbortPhase4_AlicePenalty() public {
        // Setup to Stage.Open
        test_BobChoice();
        vm.warp(block.timestamp + 1 hours + 1 seconds);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        mp.abortPhase4();

        // Bob gets both deposits (2 ETH) for Alice's silence
        assertEq(bob.balance, bobBalanceBefore + 2 ether);
        assertEq(uint(mp.currentStage()), 6);
    }

    function test_RevealGarblerLabels_Success() public {
        test_RevealOpenings_Success();

        bytes32[] memory mockLabels = new bytes32[](32);
        for(uint i = 0; i < 32; i++) {
            mockLabels[i] = keccak256(abi.encodePacked("alice_label_", i));
        }

        vm.prank(alice);
        mp.revealGarblerLabels(mockLabels);

        assertEq(uint(mp.currentStage()), 5); // Stage.Settle
    }

    function test_AbortPhase5_AlicePenalty() public {
        test_RevealOpenings_Success();

        vm.warp(block.timestamp + 1 hours + 1 seconds);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        mp.abortPhase5();

        assertEq(bob.balance, bobBalanceBefore + 2 ether);
        assertEq(uint(mp.currentStage()), 6); // Stage.Closed
    }
}