// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MillionairesProblem.sol";

contract MillionairesProblemHarness is MillionairesProblem {
    constructor(address _bob, bytes32 _circuitId, bytes32 _circuitLayoutRoot)
    MillionairesProblem(_bob, _circuitId, _circuitLayoutRoot)
    {}

    function computeLeaf(bytes32 seed, uint256 instanceId, uint256 gateIndex, GateDesc calldata g)
    external view returns (bytes memory)
    {
        return recomputeGateLeafBytes(seed, instanceId, gateIndex, g);
    }
}

contract MillionairesTest is Test {
    MillionairesProblemHarness mp;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        bytes32 layoutLeaf = keccak256(abi.encodePacked(
            uint256(0), // gateIndex
            uint8(0),    // GateType.AND
            uint16(1),   // wireA
            uint16(2),   // wireB
            uint16(3)    // wireC
        ));

        vm.prank(alice);
        mp = new MillionairesProblemHarness(bob, keccak256("millionaires-yao-v1"), layoutLeaf);

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
        assertEq(uint(mp.currentStage()), 7); // Stage.Closed (index 7)
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
        assertEq(uint(mp.currentStage()), 7); // Stage.Closed
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

        assertEq(bob.balance, bobBalanceBefore + 2 ether);
        assertEq(uint(mp.currentStage()), 7);
    }

    function test_RevealGarblerLabels_Success() public {
        test_RevealOpenings_Success();

        vm.prank(bob);
        mp.closeDispute();

        bytes32[] memory mockLabels = new bytes32[](32);
        for(uint i = 0; i < 32; i++) {
            mockLabels[i] = keccak256(abi.encodePacked("alice_label_", i));
        }

        vm.prank(alice);
        mp.revealGarblerLabels(mockLabels);

        assertEq(uint(mp.currentStage()), 6); // Stage.Settle
    }

    function test_AbortPhase5_AlicePenalty() public {
        test_RevealOpenings_Success();

        vm.prank(bob);
        mp.closeDispute();

        vm.warp(block.timestamp + 2 hours + 1 seconds);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        mp.abortPhase5();

        assertEq(bob.balance, bobBalanceBefore + 2 ether);
        assertEq(uint(mp.currentStage()), 7); // Stage.Closed
    }

    function test_FinalSettlement_AliceWins() public {
        // --- Phase 1: Deposits ---
        vm.prank(alice);
        mp.deposit{value: 1 ether}();
        vm.prank(bob);
        mp.deposit{value: 1 ether}();

        // --- Phase 2: Commitments ---
        bytes32 aliceWinningLabel = keccak256(abi.encodePacked("alice_is_richer_label"));
        MillionairesProblem.InstanceCommitment[10] memory commits;

        for (uint256 i = 0; i < 10; i++) {
            commits[i] = MillionairesProblem.InstanceCommitment({
                comSeed: keccak256(abi.encodePacked(keccak256(abi.encodePacked("seed", i)))),
                rootGC: bytes32(0),
                rootXG: bytes32(0),
                rootOT: bytes32(0),
                h0: keccak256(abi.encodePacked(aliceWinningLabel)),
                h1: keccak256(abi.encodePacked("bob_wins_label"))
            });
        }
        vm.prank(alice);
        mp.submitCommitments(commits);

        // --- Phase 3 & 4: Choose & Reveal ---
        vm.prank(bob);
        mp.choose(0);

        uint256[] memory indices = new uint256[](9);
        bytes32[] memory seeds = new bytes32[](9);
        for (uint256 i = 1; i < 10; i++) {
            indices[i-1] = i;
            seeds[i-1] = keccak256(abi.encodePacked("seed", i));
        }
        vm.prank(alice);
        mp.revealOpenings(indices, seeds);

        vm.prank(bob);
        mp.closeDispute();

        // --- Phase 5: Reveal Garbler Labels ---
        bytes32[] memory mockLabels = new bytes32[](32);
        vm.prank(alice);
        mp.revealGarblerLabels(mockLabels);

        // --- Phase 6: Settle ---
        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(bob);
        mp.settle(aliceWinningLabel);

        // --- Assertions ---
        assertEq(alice.balance, aliceBalanceBefore + 2 ether);
        assertEq(uint(mp.currentStage()), 7); // Stage.Closed
        assertTrue(mp.result());
    }

    function test_ChallengeGateLeaf_FalseChallenge_SlashesBob() public {
        bytes32 seed = keccak256("seed");
        uint256 instanceId = 0;
        uint256 gateIndex = 0;

        MillionairesProblem.GateDesc memory g = MillionairesProblem.GateDesc({
            gateType: MillionairesProblem.GateType.AND,
            wireA: 1,
            wireB: 2,
            wireC: 3
        });

        // leafBytes that contract itself would recompute
        bytes memory leaf = mp.computeLeaf(seed, instanceId, gateIndex, g);

        // 1-leaf Merkle tree
        bytes32 root = keccak256(leaf);
        _toDisputeWithRoot(seed, root, 9);

        bytes32[] memory proof = new bytes32[](0);
        bytes32[] memory layoutProof = new bytes32[](0);

        uint256 aliceBefore = alice.balance;

        vm.prank(bob);
        mp.challengeGateLeaf(instanceId, gateIndex, g, leaf, proof, layoutProof);

        // Bob loses, Alice receives both deposits
        assertEq(alice.balance, aliceBefore + 2 ether);
        assertEq(uint(mp.currentStage()), 7); // Closed
    }

    function test_ChallengeGateLeaf_DetectCheat_SlashesAlice() public {
        bytes32 seed = keccak256("seed");
        uint256 instanceId = 0;
        uint256 gateIndex = 0;

        MillionairesProblem.GateDesc memory g = MillionairesProblem.GateDesc({
            gateType: MillionairesProblem.GateType.AND,
            wireA: 1,
            wireB: 2,
            wireC: 3
        });

        bytes memory expectedLeaf = mp.computeLeaf(seed, instanceId, gateIndex, g);

        // Make committed leaf wrong (mutate one byte)
        bytes memory fakeLeaf = new bytes(expectedLeaf.length);
        for (uint256 i = 0; i < expectedLeaf.length; i++) fakeLeaf[i] = expectedLeaf[i];
        fakeLeaf[0] = bytes1(uint8(fakeLeaf[0]) ^ 1);

        bytes32 root = keccak256(fakeLeaf);
        _toDisputeWithRoot(seed, root, 9);

        bytes32[] memory proof = new bytes32[](0);
        bytes32[] memory layoutProof = new bytes32[](0);
        uint256 bobBefore = bob.balance;

        vm.prank(bob);
        mp.challengeGateLeaf(instanceId, gateIndex, g, fakeLeaf, proof, layoutProof);

        assertEq(bob.balance, bobBefore + 2 ether);
        assertEq(uint(mp.currentStage()), 7);
    }

    function test_ChallengeGateLeaf_BadMerkleProof_Reverts() public {
        bytes32 seed = keccak256("seed");

        MillionairesProblem.GateDesc memory g = MillionairesProblem.GateDesc({
            gateType: MillionairesProblem.GateType.AND,
            wireA: 1,
            wireB: 2,
            wireC: 3
        });

        bytes memory leaf = mp.computeLeaf(seed, 0, 0, g);

        // Commit wrong root
        bytes32 wrongRoot = keccak256("wrong");
        _toDisputeWithRoot(seed, wrongRoot, 9);

        bytes32[] memory proof = new bytes32[](0);
        bytes32[] memory layoutProof = new bytes32[](0);

        vm.prank(bob);
        vm.expectRevert("Bad Merkle proof");
        mp.challengeGateLeaf(0, 0, g, leaf, proof, layoutProof);
    }

    function _toDisputeWithRoot(bytes32 seed, bytes32 rootGC0, uint256 mChoice) internal {
        vm.prank(alice);
        mp.deposit{value: 1 ether}();
        vm.prank(bob);
        mp.deposit{value: 1 ether}();

        // Commitments
        MillionairesProblem.InstanceCommitment[10] memory commits;
        bytes32 com = keccak256(abi.encodePacked(seed));
        for (uint256 i = 0; i < 10; i++) {
            commits[i] = MillionairesProblem.InstanceCommitment({
                comSeed: com,
                rootGC: (i == 0) ? rootGC0 : bytes32(0),
                rootXG: bytes32(0),
                rootOT: bytes32(0),
                h0: bytes32(0),
                h1: bytes32(0)
            });
        }
        vm.prank(alice);
        mp.submitCommitments(commits);

        vm.prank(bob);
        mp.choose(mChoice);

        uint256[] memory indices = new uint256[](9);
        bytes32[] memory seeds = new bytes32[](9);
        uint256 p = 0;

        for (uint256 i = 0; i < 10; i++) {
            if (i == mChoice) continue;
            indices[p] = i;
            seeds[p] = seed;
            p++;
        }

        vm.prank(alice);
        mp.revealOpenings(indices, seeds);
    }
}