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

    struct RustGateChallengeVector {
        bytes32 circuitId;
        bytes32 circuitLayoutRoot;
        uint256 mChoice;
        uint256 challengeInstanceId;
        uint256 gateIndex;
        uint8 gateType;
        uint16 wireA;
        uint16 wireB;
        uint16 wireC;
        bytes leafBytes;
        bytes32[] comSeeds;
        bytes32[] rootGCs;
        uint256[] openIndices;
        bytes32[] openSeeds;
        bytes32[] ihProof;
        bytes32[] layoutProof;
        bool expectMatch;
    }

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

    function _defaultAndGate() internal pure returns (MillionairesProblem.GateDesc memory) {
        return MillionairesProblem.GateDesc({
            gateType: MillionairesProblem.GateType.AND,
            wireA: 1,
            wireB: 2,
            wireC: 3
        });
    }

    function _mutateFirstByte(bytes memory value) internal pure returns (bytes memory mutated) {
        mutated = new bytes(value.length);
        for (uint256 i = 0; i < value.length; i++) {
            mutated[i] = value[i];
        }
        mutated[0] = bytes1(uint8(mutated[0]) ^ 1);
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
                blobHashGC: keccak256(abi.encode(i, "blob-gc")),
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
                blobHashGC: bytes32(0),
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
        vm.prank(alice);
        mp.deposit{value: 1 ether}();
        vm.prank(bob);
        mp.deposit{value: 1 ether}();

        uint256 chosenM = 5;
        bytes32 evalRootGc = keccak256("eval-root-gc");
        bytes32 evalBlobHash = keccak256("eval-blob-hash");
        bytes32[] memory realSeeds = new bytes32[](10);
        MillionairesProblem.InstanceCommitment[10] memory commits;

        for (uint256 i = 0; i < 10; i++) {
            realSeeds[i] = keccak256(abi.encodePacked("secret_seed_", i));
            commits[i] = MillionairesProblem.InstanceCommitment({
                comSeed: keccak256(abi.encodePacked(realSeeds[i])),
                rootGC: i == chosenM ? evalRootGc : bytes32(0),
                blobHashGC: i == chosenM ? evalBlobHash : bytes32(0),
                rootXG: bytes32(0),
                rootOT: bytes32(0),
                h0: bytes32(0),
                h1: bytes32(0)
            });
        }

        vm.prank(alice);
        mp.submitCommitments(commits);

        vm.prank(bob);
        mp.choose(chosenM);

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

        vm.prank(bob);
        mp.closeDispute();

        bytes32[] memory mockLabels = new bytes32[](32);
        for(uint i = 0; i < 32; i++) {
            mockLabels[i] = keccak256(abi.encodePacked("alice_label_", i));
        }

        vm.prank(alice);
        mp.revealGarblerLabels(mockLabels);

        assertEq(uint(mp.currentStage()), 6); // Stage.Settle
        assertEq(mp.evaluationTableBlobHash(), evalBlobHash);
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

    function test_FinalSettlement_AliceWins_RefundsBothDeposits() public {
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
                blobHashGC: bytes32(0),
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
        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        mp.settle(aliceWinningLabel);

        // --- Assertions ---
        assertEq(alice.balance, aliceBalanceBefore + 1 ether);
        assertEq(bob.balance, bobBalanceBefore + 1 ether);
        assertEq(uint(mp.currentStage()), 7); // Stage.Closed
        assertTrue(mp.result());
    }

    function test_FinalSettlement_BobWins_RefundsBothDeposits() public {
        // --- Phase 1: Deposits ---
        vm.prank(alice);
        mp.deposit{value: 1 ether}();
        vm.prank(bob);
        mp.deposit{value: 1 ether}();

        // --- Phase 2: Commitments ---
        bytes32 bobWinningLabel = keccak256(abi.encodePacked("bob_wins_label"));
        MillionairesProblem.InstanceCommitment[10] memory commits;

        for (uint256 i = 0; i < 10; i++) {
            commits[i] = MillionairesProblem.InstanceCommitment({
                comSeed: keccak256(abi.encodePacked(keccak256(abi.encodePacked("seed", i)))),
                rootGC: bytes32(0),
                blobHashGC: bytes32(0),
                rootXG: bytes32(0),
                rootOT: bytes32(0),
                h0: keccak256(abi.encodePacked("alice_wins_label")),
                h1: keccak256(abi.encodePacked(bobWinningLabel))
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
            indices[i - 1] = i;
            seeds[i - 1] = keccak256(abi.encodePacked("seed", i));
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
        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        mp.settle(bobWinningLabel);

        // --- Assertions ---
        assertEq(alice.balance, aliceBalanceBefore + 1 ether);
        assertEq(bob.balance, bobBalanceBefore + 1 ether);
        assertEq(uint(mp.currentStage()), 7); // Stage.Closed
        assertFalse(mp.result());
    }

    function test_ChallengeGateLeaf_FalseChallenge_SlashesBob() public {
        bytes32 seed = keccak256("seed");
        uint256 instanceId = 0;
        uint256 gateIndex = 0;

        MillionairesProblem.GateDesc memory g = _defaultAndGate();

        // leafBytes that contract itself would recompute
        bytes memory leaf = mp.computeLeaf(seed, instanceId, gateIndex, g);

        bytes32[] memory proof = new bytes32[](0);
        // Single-block incremental chain root: IH_1 = H(0 || block_1).
        bytes32 root = _processIncrementalProof(_gateLeafHash(gateIndex, leaf), proof);
        _toDisputeWithRoot(seed, root, 9);

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

        MillionairesProblem.GateDesc memory g = _defaultAndGate();

        bytes memory expectedLeaf = mp.computeLeaf(seed, instanceId, gateIndex, g);
        bytes memory fakeLeaf = _mutateFirstByte(expectedLeaf);

        bytes32[] memory proof = new bytes32[](0);
        bytes32 root = _processIncrementalProof(_gateLeafHash(gateIndex, fakeLeaf), proof);
        _toDisputeWithRoot(seed, root, 9);

        bytes32[] memory layoutProof = new bytes32[](0);
        uint256 bobBefore = bob.balance;

        vm.prank(bob);
        mp.challengeGateLeaf(instanceId, gateIndex, g, fakeLeaf, proof, layoutProof);

        assertEq(bob.balance, bobBefore + 2 ether);
        assertEq(uint(mp.currentStage()), 7);
    }

    function test_ChallengeGateLeaf_BadIHProof_Reverts() public {
        bytes32 seed = keccak256("seed");
        MillionairesProblem.GateDesc memory g = _defaultAndGate();

        bytes memory leaf = mp.computeLeaf(seed, 0, 0, g);

        // Commit wrong root
        bytes32 wrongRoot = keccak256("wrong");
        _toDisputeWithRoot(seed, wrongRoot, 9);

        bytes32[] memory proof = new bytes32[](0);
        bytes32[] memory layoutProof = new bytes32[](0);

        vm.prank(bob);
        vm.expectRevert("Bad IH proof");
        mp.challengeGateLeaf(0, 0, g, leaf, proof, layoutProof);
    }

    function test_ChallengeGateLeaf_BadLayoutProof_Reverts() public {
        bytes32 seed = keccak256("seed");
        uint256 instanceId = 0;
        uint256 gateIndex = 0;

        MillionairesProblem.GateDesc memory g = _defaultAndGate();
        bytes memory leaf = mp.computeLeaf(seed, instanceId, gateIndex, g);

        bytes32[] memory proof = new bytes32[](0);
        bytes32 root = _processIncrementalProof(_gateLeafHash(gateIndex, leaf), proof);
        _toDisputeWithRoot(seed, root, 9);

        bytes32[] memory badLayoutProof = new bytes32[](1);
        badLayoutProof[0] = keccak256("bad-layout-proof");

        vm.prank(bob);
        vm.expectRevert("Bad circuit layout proof");
        mp.challengeGateLeaf(instanceId, gateIndex, g, leaf, proof, badLayoutProof);
    }

    function test_DisputeGarbledTable_DelegatesToChallenge_SlashesBobOnMatch() public {
        bytes32 seed = keccak256("seed");
        uint256 instanceId = 0;
        uint256 gateIndex = 0;

        MillionairesProblem.GateDesc memory g = _defaultAndGate();

        bytes32[] memory proof = new bytes32[](0);
        // Correct committed leaf.
        bytes memory leaf = mp.computeLeaf(seed, instanceId, gateIndex, g);
        bytes32 root = _processIncrementalProof(_gateLeafHash(gateIndex, leaf), proof);
        _toDisputeWithRoot(seed, root, 9);

        bytes32[] memory layoutProof = new bytes32[](0);

        uint256 aliceBefore = alice.balance;

        vm.prank(bob);
        mp.disputeGarbledTable(instanceId, seed, gateIndex, g, leaf, proof, layoutProof);

        // Same result as challengeGateLeaf on matching leaf: Bob false-challenged.
        assertEq(alice.balance, aliceBefore + 2 ether);
        assertEq(uint(mp.currentStage()), 7);
    }

    function test_DisputeGarbledTable_DelegatesToChallenge_SlashesAliceOnMismatch() public {
        bytes32 seed = keccak256("seed");
        uint256 instanceId = 0;
        uint256 gateIndex = 0;

        MillionairesProblem.GateDesc memory g = _defaultAndGate();

        bytes memory expectedLeaf = mp.computeLeaf(seed, instanceId, gateIndex, g);
        bytes memory fakeLeaf = _mutateFirstByte(expectedLeaf);

        bytes32[] memory proof = new bytes32[](0);
        bytes32 root = _processIncrementalProof(_gateLeafHash(gateIndex, fakeLeaf), proof);
        _toDisputeWithRoot(seed, root, 9);

        bytes32[] memory layoutProof = new bytes32[](0);
        uint256 bobBefore = bob.balance;

        vm.prank(bob);
        mp.disputeGarbledTable(instanceId, seed, gateIndex, g, fakeLeaf, proof, layoutProof);

        // Same result as challengeGateLeaf on mismatch: Alice cheated.
        assertEq(bob.balance, bobBefore + 2 ether);
        assertEq(uint(mp.currentStage()), 7);
    }

    function test_DisputeGarbledTable_InvalidSeed_Reverts() public {
        bytes32 seed = keccak256("seed");
        bytes32 wrongSeed = keccak256("wrong-seed");

        MillionairesProblem.GateDesc memory g = _defaultAndGate();

        bytes32[] memory proof = new bytes32[](0);
        bytes memory leaf = mp.computeLeaf(seed, 0, 0, g);
        bytes32 root = _processIncrementalProof(_gateLeafHash(0, leaf), proof);
        _toDisputeWithRoot(seed, root, 9);

        bytes32[] memory layoutProof = new bytes32[](0);

        vm.prank(bob);
        vm.expectRevert("Invalid seed");
        mp.disputeGarbledTable(0, wrongSeed, 0, g, leaf, proof, layoutProof);
    }

    //Main test for checking if the implementation on Rust works
    function test_ChallengeGateLeaf_RustVector_Editable() public {
        RustGateChallengeVector memory v = _rustVectorDefaultAndGate();
        // Section-5.2 update: rootGC is the terminal state of an incremental-hash chain.
        v.rootGCs[v.challengeInstanceId] =
            _processIncrementalProof(_gateLeafHash(v.gateIndex, v.leafBytes), v.ihProof);

        // Deploy fresh contract with Rust vector identifiers.
        vm.prank(alice);
        mp = new MillionairesProblemHarness(bob, v.circuitId, v.circuitLayoutRoot);

        vm.prank(alice);
        mp.deposit{value: 1 ether}();
        vm.prank(bob);
        mp.deposit{value: 1 ether}();

        require(v.comSeeds.length == 10, "comSeeds must have 10 values");
        require(v.rootGCs.length == 10, "rootGCs must have 10 values");
        require(v.openIndices.length == 9, "openIndices must have 9 values");
        require(v.openSeeds.length == 9, "openSeeds must have 9 values");
        require(v.challengeInstanceId != v.mChoice, "challenge instance cannot be m");

        MillionairesProblem.InstanceCommitment[10] memory commits;
        for (uint256 i = 0; i < 10; i++) {
            commits[i] = MillionairesProblem.InstanceCommitment({
                comSeed: v.comSeeds[i],
                rootGC: v.rootGCs[i],
                blobHashGC: bytes32(0),
                rootXG: bytes32(0),
                rootOT: bytes32(0),
                h0: bytes32(0),
                h1: bytes32(0)
            });
        }

        vm.prank(alice);
        mp.submitCommitments(commits);

        vm.prank(bob);
        mp.choose(v.mChoice);

        vm.prank(alice);
        mp.revealOpenings(v.openIndices, v.openSeeds);

        MillionairesProblem.GateDesc memory g = MillionairesProblem.GateDesc({
            gateType: MillionairesProblem.GateType(v.gateType),
            wireA: v.wireA,
            wireB: v.wireB,
            wireC: v.wireC
        });

        // Helpful parity check before challenge call.
        bytes32 challengeSeed = bytes32(0);
        for (uint256 i = 0; i < v.openIndices.length; i++) {
            if (v.openIndices[i] == v.challengeInstanceId) {
                challengeSeed = v.openSeeds[i];
                break;
            }
        }
        require(challengeSeed != bytes32(0), "missing opened seed for challenge instance");
        bytes memory expected = mp.computeLeaf(challengeSeed, v.challengeInstanceId, v.gateIndex, g);
        emit log_named_string("input_leaf_bytes", vm.toString(v.leafBytes));
        emit log_named_string("generated_leaf_bytes", vm.toString(expected));
        if (v.expectMatch) {
            assertEq(keccak256(expected), keccak256(v.leafBytes), "Rust leaf != Solidity recompute");
        }

        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;

        vm.prank(bob);
        mp.challengeGateLeaf(
            v.challengeInstanceId,
            v.gateIndex,
            g,
            v.leafBytes,
            v.ihProof,
            v.layoutProof
        );

        if (v.expectMatch) {
            // False challenge -> Bob slashed to Alice
            assertEq(alice.balance, aliceBefore + 2 ether);
            assertEq(bob.balance, bobBefore);
        } else {
            // Real mismatch -> Alice slashed to Bob
            assertEq(bob.balance, bobBefore + 2 ether);
            assertEq(alice.balance, aliceBefore);
        }

        assertEq(uint(mp.currentStage()), 7); // Closed
    }

    function _gateLeafHash(uint256 gateIndex, bytes memory leafBytes) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(gateIndex, leafBytes));
    }

    function _processIncrementalProof(bytes32 leafHash, bytes32[] memory ihProof) internal pure returns (bytes32) {
        if (ihProof.length == 0) {
            return keccak256(abi.encodePacked(bytes32(0), leafHash));
        }

        bytes32 state = keccak256(abi.encodePacked(ihProof[0], leafHash));
        for (uint256 i = 1; i < ihProof.length; i++) {
            state = keccak256(abi.encodePacked(state, ihProof[i]));
        }
        return state;
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
                blobHashGC: bytes32(0),
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

    // Edit this single function to paste values from `cargo run` output.
    function _rustVectorDefaultAndGate() internal pure returns (RustGateChallengeVector memory v) {
        v.circuitId = hex"7d054ebfd92394e7d8b68c457a833f9083147ac4e616619c23cfa544159e8797";
        v.circuitLayoutRoot = hex"07f4a5ca9dea030d4dc113f2d52a09349808e157fc5095d654c1485f6db3f287";

        v.mChoice = 7;
        v.challengeInstanceId = 0;
        v.gateIndex = 3;
        v.gateType = 0; // AND
        v.wireA = 7;
        v.wireB = 18;
        v.wireC = 19;
        v.expectMatch = true;

        v.leafBytes = hex"00000700120013f3a970a4aca4195bb91139a403b12529c1b78544587cc4113ae7dfc3dd3e453ed253d5732b25084f641096d26c1e5786a67b4b471675e32cf1368473435a49cf";

        v.comSeeds = new bytes32[](10);
        v.comSeeds[0] = hex"50f3ed16d8a54ce7e35d99ef80346a5c441c2fb1a34de9fab199922070c890c6";
        v.comSeeds[1] = hex"cf8717986f73585bb0afa9a04533d17f05a7c8a1a1fcbe823aba7cea3b89a05c";
        v.comSeeds[2] = hex"62d4b87a1a375cf3aa79e8c6ecc10d18b533a3fa5094bb55eca278988f0539c0";
        v.comSeeds[3] = hex"56b6debff9bc913f2aadb8d081611e851b74e207dcd67dce44186f92ad7855fb";
        v.comSeeds[4] = hex"1c67db7772252c1f8ce817b9a2bbdcaf38ea17c15cfb44982261f0082cdcb5a0";
        v.comSeeds[5] = hex"c208b4d8c951239d62c1eb58fe657cc68ee1355f0f4916a59eb4040b1c1a4343";
        v.comSeeds[6] = hex"476075973e64ac217ba7070d5324d52c9d56015b621701c2052df9b02ff9ffb0";
        v.comSeeds[7] = hex"4a1297917deab8051b727a486e2849463cc825f48f237d04501c5c2cd8b07e8c";
        v.comSeeds[8] = hex"81f6124184e3e0981f6d04e79fb5caea335cd04ab7e0ff4b5688cee07e67af57";
        v.comSeeds[9] = hex"41fd7628b441cd1a931fa9dd84a32a03ac7bd9df032094a0af587f4030c83f87";

        v.rootGCs = new bytes32[](10);
        v.rootGCs[0] = hex"094978d23f06722be18d53d2ade96ae8c758a27f1da74b6e08c280f8e7bbfff9";
        v.rootGCs[1] = hex"da73caf28918e842706d2df840128353a5f584a48320b78c43f253348f5aefa5";
        v.rootGCs[2] = hex"52ea3c87846e210235ea2a32fb91c0890a7c4e52c8039a7dc29907e0270fc518";
        v.rootGCs[3] = hex"adc195861187284e7f3c8973f88ef1599b083e8d7cfd10f6c3d1598b4150a906";
        v.rootGCs[4] = hex"13e3ebb7bdfd6dbc7bbb46561b1438604213df5494075cdf1364fc46fc2a496c";
        v.rootGCs[5] = hex"eb44f1ec19bf3d6760e8b027f37cd507a437d24024e3bcf2785eac368489d808";
        v.rootGCs[6] = hex"8061b9bea7be787ed01b6b0267021a1c78e96620b73c57584d91f98103d1619c";
        v.rootGCs[7] = hex"8635fd188dd58a638351af039f9ef6239279e3b938ea66371304f09ec5964553";
        v.rootGCs[8] = hex"fe505d436c92fe4b089672d90e129e71d09ecfdd525e6f556773dd7468e90c20";
        v.rootGCs[9] = hex"cf1f5de3a925ff25a16b9c01303f7dddb1959b507d81b099bd0b9cfacbd54e63";

        v.openIndices = new uint256[](9);
        v.openIndices[0] = 0;
        v.openIndices[1] = 1;
        v.openIndices[2] = 2;
        v.openIndices[3] = 3;
        v.openIndices[4] = 4;
        v.openIndices[5] = 5;
        v.openIndices[6] = 6;
        v.openIndices[7] = 8;
        v.openIndices[8] = 9;

        v.openSeeds = new bytes32[](9);
        v.openSeeds[0] = hex"66d5e5349dc15a7a20ec66ab394f46e9ba0c2185504ebc750c1c3a014b4d589c";
        v.openSeeds[1] = hex"304d41b6cfd5a420da8cf6032c69e2491e010dd99e74b6ed99d64a912639f024";
        v.openSeeds[2] = hex"06cd55098e8d87c54bea302aade785be551d9f8feaec2fd39cd8702a7b9ad40e";
        v.openSeeds[3] = hex"0ce54cb4371944fe530a9a886aefb22d46c1d82f858627bf296d42a37dabae0d";
        v.openSeeds[4] = hex"fa22482e56a00853e14da59a8b5fc10c987f9ea72fd06f670340198cfad0ba24";
        v.openSeeds[5] = hex"4084f64b07620721a19cff068f1031d93bd2b084de6adbd50d0701bc449df02a";
        v.openSeeds[6] = hex"356efa1c850ccb193cbc86a1383e9f4f9dddfec51bd3c55962d947048b9281c2";
        v.openSeeds[7] = hex"b316a2db450aad027d2d79f56b5734aed75832704589c453c82e86e49e3c2059";
        v.openSeeds[8] = hex"399f75c7055ddcf78a4977eaad6ae17abe2905146f7f2d81d4640b41396910ab";

        v.ihProof = new bytes32[](7);
        v.ihProof[0] = hex"9953ddc764ebe6b87385bf84f53d619b9370bcc6e2a3fa5fba7c7d66b4e639d8";
        v.ihProof[1] = hex"c9d11e214c587a040cdf2a9f48cdb3d609b51390465b3dd84c153e048bcb168a";
        v.ihProof[2] = hex"894320ad446936475b1cc138f2370a04c65ca7b5a7a984b0c33036501e442394";
        v.ihProof[3] = hex"e5237e952203a3515cfe4a35a7e0ea25a64a647fa059a462a8e063068e719ddb";
        v.ihProof[4] = hex"a589be25467e22c2d205ff339de2b02ff1b880746cf97e34ca86cd7fc4aa7a9d";
        v.ihProof[5] = hex"6fe99c05e51cb1b607d0526b158605acf65a038455fe839038db38c703ea732a";
        v.ihProof[6] = hex"5c22aa67adf3cb1afa395aff96bc41c1e27abd5c90a6b0f0ea61977d18c07c7c";

        v.layoutProof = new bytes32[](7);
        v.layoutProof[0] = hex"4af035fa923878895db2ebdbd69dd9f28a7d3ca9704fa907614b8a301fdf8cc7";
        v.layoutProof[1] = hex"4f16c787aaf3c34a7cbeb88ac350364e9ec2dc0e054e5e232b4cf4b5532e1d14";
        v.layoutProof[2] = hex"4c3b91469df873c68aae516efc5f63ee6f23e2918db51b6ef827282c9f1968c7";
        v.layoutProof[3] = hex"6f891ed83a0b3acfee1c480badf60888ec11592d1e25594e827afdfa9aec680a";
        v.layoutProof[4] = hex"9d9629b078c14342b0b812fd5d771f5a2ecdab4a57cb1c96bdd6e860f5ab519e";
        v.layoutProof[5] = hex"5261f5438a3ddcf9c14b99c31a927770f9a5c413d53b681a8090cfc30f8d3d39";
        v.layoutProof[6] = hex"4b77870e636e81f46166bf774e81ebfb3c0551c0abf50673e609c789fa0aa901";
    }
}
