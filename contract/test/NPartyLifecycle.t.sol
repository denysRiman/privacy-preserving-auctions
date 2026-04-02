// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MillionairesProblem.sol";

contract NPartyMockEnsAuctionAdapter is IEnsAuctionAdapter {
    function assign(bytes32, address) external override {}
}

contract NPartyHarness is MillionairesProblem {
    constructor(
        address _bob,
        address _receiver,
        bytes32 _ensNamehash,
        address _ensAdapter,
        bytes32 _circuitId,
        bytes32 _circuitLayoutRoot,
        uint16 _bitWidth
    )
        MillionairesProblem(_bob, _receiver, _ensNamehash, _ensAdapter, _circuitId, _circuitLayoutRoot, _bitWidth)
    {}

    function computeOtRootForTest(bytes32 garblerSeed, bytes32 verifierSeedValue, address buyerAddr, uint256 instanceId)
        external
        view
        returns (bytes32)
    {
        return _recomputeOtRoot(garblerSeed, verifierSeedValue, buyerAddr, instanceId);
    }

    // Compatibility helper after removing choose stage from contract.
    function choose(uint256) external view {
        require(currentStage == Stage.Open, "Choose removed");
    }
}

contract NPartyLifecycleTest is Test {
    NPartyHarness mp;
    NPartyMockEnsAuctionAdapter adapter;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob1");
    address bob2 = makeAddr("bob2");
    address bob3 = makeAddr("bob3");
    address eve = makeAddr("eve");

    uint16 constant BIT_WIDTH = 8;
    uint256 constant GARBLER_DEPOSIT = 1.2 ether;
    uint256 constant EVALUATOR_DEPOSIT = 1.2 ether;
    bytes32 constant CIRCUIT_ID = hex"4b38f6018cce9cce241946cda9af3509db31d6ef0f4b17e25e4f589faa71da7e";
    bytes32 constant LAYOUT_ROOT = hex"d15d9ca7dfc1e2a4c47eb4812eb9d08761688c436aad557449954b91df138521";
    bytes32 constant ENS_NAMEHASH = keccak256(abi.encodePacked("auction-example.eth"));

    bytes32 constant VERIFIER_SEED = hex"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    bytes32 constant VERIFIER_SALT = hex"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    function _seedFor(address buyerAddr) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("seed", buyerAddr));
    }

    function _saltFor(address buyerAddr) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("salt", buyerAddr));
    }

    function setUp() public {
        adapter = new NPartyMockEnsAuctionAdapter();
        vm.prank(alice);
        mp = new NPartyHarness(
            bob,
            bob,
            ENS_NAMEHASH,
            address(adapter),
            CIRCUIT_ID,
            LAYOUT_ROOT,
            BIT_WIDTH
        );

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(bob2, 10 ether);
        vm.deal(bob3, 10 ether);
        vm.deal(eve, 10 ether);
    }

    function _validCoreCommitments() internal pure returns (MillionairesProblem.CoreInstanceCommitment[10] memory core) {
        for (uint256 i = 0; i < 10; i++) {
            bytes32 seed = keccak256(abi.encodePacked("open-seed", i));
            core[i] = MillionairesProblem.CoreInstanceCommitment({
                comSeed: keccak256(abi.encodePacked(seed)),
                rootGC: keccak256(abi.encodePacked("core-root-gc", i)),
                blobHashGC: keccak256(abi.encodePacked("core-blob-gc", i)),
                hOut: keccak256(abi.encodePacked("core-hOut", i))
            });
        }
    }

    function _validOtRoots() internal pure returns (bytes32[10] memory roots) {
        for (uint256 i = 0; i < 10; i++) {
            roots[i] = keccak256(abi.encodePacked("root-ot", i));
        }
    }

    function _matchingOtRoots(address buyerAddr) internal view returns (bytes32[10] memory roots) {
        bytes32 aggregateVerifierSeed = mp.verifierSeed();
        for (uint256 i = 0; i < 10; i++) {
            bytes32 seed = keccak256(abi.encodePacked("open-seed", i));
            roots[i] = mp.computeOtRootForTest(seed, aggregateVerifierSeed, buyerAddr, i);
        }
    }

    function _registerB2B3AndDepositAll() internal {
        address[] memory extra = new address[](2);
        address[] memory receivers = new address[](2);
        extra[0] = bob2;
        extra[1] = bob3;
        receivers[0] = bob2;
        receivers[1] = bob3;
        vm.prank(alice);
        mp.registerBuyers(extra, receivers);

        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();
        vm.prank(bob2);
        mp.deposit{value: EVALUATOR_DEPOSIT}();
        vm.prank(bob3);
        mp.deposit{value: EVALUATOR_DEPOSIT}();
    }

    function _commitAndRevealAllBuyerSeeds() internal {
        address[3] memory bs = [bob, bob2, bob3];
        for (uint256 i = 0; i < bs.length; i++) {
            address b = bs[i];
            bytes32 seed = _seedFor(b);
            bytes32 salt = _saltFor(b);
            vm.prank(b);
            mp.commitBuyerSeed(keccak256(abi.encodePacked(seed, salt)));
        }
        for (uint256 i = 0; i < bs.length; i++) {
            address b = bs[i];
            vm.prank(b);
            mp.revealBuyerSeed(_seedFor(b), _saltFor(b));
        }
    }

    function _toBuyerInputOtStage() internal {
        _registerB2B3AndDepositAll();
        _commitAndRevealAllBuyerSeeds();

        MillionairesProblem.CoreInstanceCommitment[10] memory core = _validCoreCommitments();
        vm.prank(alice);
        mp.submitCommitments(core);

        bytes32[10] memory roots = _validOtRoots();
        vm.prank(alice);
        mp.submitOtRootsForBuyer(bob, roots);
        vm.prank(alice);
        mp.submitOtRootsForBuyer(bob2, roots);
        vm.prank(alice);
        mp.submitOtRootsForBuyer(bob3, roots);
    }

    function _toCommitmentsOtStage() internal {
        _registerB2B3AndDepositAll();
        _commitAndRevealAllBuyerSeeds();
        MillionairesProblem.CoreInstanceCommitment[10] memory core = _validCoreCommitments();
        vm.prank(alice);
        mp.submitCommitments(core);
    }

    function _toDisputeStageWithMatchingRoots() internal {
        _registerB2B3AndDepositAll();
        _commitAndRevealAllBuyerSeeds();

        MillionairesProblem.CoreInstanceCommitment[10] memory core = _validCoreCommitments();
        vm.prank(alice);
        mp.submitCommitments(core);

        bytes32[10] memory rootsBob = _matchingOtRoots(bob);
        vm.prank(alice);
        mp.submitOtRootsForBuyer(bob, rootsBob);
        bytes32[10] memory rootsBob2 = _matchingOtRoots(bob2);
        vm.prank(alice);
        mp.submitOtRootsForBuyer(bob2, rootsBob2);
        bytes32[10] memory rootsBob3 = _matchingOtRoots(bob3);
        vm.prank(alice);
        mp.submitOtRootsForBuyer(bob3, rootsBob3);

        vm.prank(bob);
        mp.submitBuyerReady();
        vm.prank(bob2);
        mp.submitBuyerReady();
        vm.prank(bob3);
        mp.submitBuyerReady();

        uint256 chosenM = mp.m();

        uint256[] memory indices = new uint256[](9);
        bytes32[] memory seeds = new bytes32[](9);
        uint256 cursor = 0;
        for (uint256 i = 0; i < 10; i++) {
            if (i == chosenM) continue;
            indices[cursor] = i;
            seeds[cursor] = keccak256(abi.encodePacked("open-seed", i));
            cursor++;
        }
        vm.prank(alice);
        mp.revealOpenings(indices, seeds);
    }

    function _toDisputeStageWithDefaultedBuyer(address defaultedBuyer) internal {
        _registerB2B3AndDepositAll();
        _commitAndRevealAllBuyerSeeds();

        MillionairesProblem.CoreInstanceCommitment[10] memory core = _validCoreCommitments();
        vm.prank(alice);
        mp.submitCommitments(core);

        bytes32[10] memory rootsBob = _matchingOtRoots(bob);
        vm.prank(alice);
        mp.submitOtRootsForBuyer(bob, rootsBob);
        bytes32[10] memory rootsBob2 = _matchingOtRoots(bob2);
        vm.prank(alice);
        mp.submitOtRootsForBuyer(bob2, rootsBob2);
        bytes32[10] memory rootsBob3 = _matchingOtRoots(bob3);
        vm.prank(alice);
        mp.submitOtRootsForBuyer(bob3, rootsBob3);

        if (defaultedBuyer != bob) {
            vm.prank(bob);
            mp.submitBuyerReady();
        }
        if (defaultedBuyer != bob2) {
            vm.prank(bob2);
            mp.submitBuyerReady();
        }
        if (defaultedBuyer != bob3) {
            vm.prank(bob3);
            mp.submitBuyerReady();
        }

        (, , , uint256 buyerInputDeadline, , , , ) = mp.deadlines();
        vm.warp(buyerInputDeadline + 1);
        vm.prank(eve);
        mp.defaultBuyerInput(defaultedBuyer);

        uint256 chosenM = mp.m();

        uint256[] memory indices = new uint256[](9);
        bytes32[] memory seeds = new bytes32[](9);
        uint256 cursor = 0;
        for (uint256 i = 0; i < 10; i++) {
            if (i == chosenM) continue;
            indices[cursor] = i;
            seeds[cursor] = keccak256(abi.encodePacked("open-seed", i));
            cursor++;
        }
        vm.prank(alice);
        mp.revealOpenings(indices, seeds);
    }

    function test_MultiBuyer_DepositGate_RequiresAllRegisteredBuyers() public {
        address[] memory extra = new address[](2);
        address[] memory receivers = new address[](2);
        extra[0] = bob2;
        extra[1] = bob3;
        receivers[0] = bob2;
        receivers[1] = bob3;
        vm.prank(alice);
        mp.registerBuyers(extra, receivers);

        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();
        vm.prank(bob2);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.Deposits));

        vm.prank(bob3);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.BuyerSeedCommit));
        assertEq(mp.buyerCount(), 3);
    }

    function test_BuyerInputOt_BeforeDeadline_OnlyBuyerCanFinalize() public {
        _toBuyerInputOtStage();

        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.BuyerInputOT));
        assertEq(mp.unresolvedBuyers(), 3);

        vm.prank(eve);
        vm.expectRevert("Only buyer");
        mp.submitBuyerReady();

        vm.prank(bob2);
        mp.submitBuyerReady();
        assertEq(uint256(mp.buyerStatus(bob2)), uint256(MillionairesProblem.BuyerStatus.Ready));
        assertEq(mp.unresolvedBuyers(), 2);
        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.BuyerInputOT));
    }

    function test_BuyerInputOt_SubmitBuyerInputLabels_HonestPath() public {
        _toBuyerInputOtStage();

        vm.prank(eve);
        vm.expectRevert("Only buyer");
        mp.submitBuyerReady();

        vm.prank(bob3);
        mp.submitBuyerReady();

        assertEq(uint256(mp.buyerStatus(bob3)), uint256(MillionairesProblem.BuyerStatus.Ready));
        assertEq(mp.unresolvedBuyers(), 2);
        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.BuyerInputOT));
    }

    function test_BuyerInputOt_AfterDeadline_AnyoneCanDefaultToZeroAndSlash() public {
        _toBuyerInputOtStage();

        vm.prank(bob2);
        mp.submitBuyerReady();

        (, , , uint256 buyerInputDeadline, , , , ) = mp.deadlines();
        vm.warp(buyerInputDeadline + 1);

        vm.prank(eve);
        mp.defaultBuyerInput(bob);
        vm.prank(eve);
        mp.defaultBuyerInput(bob3);

        assertEq(uint256(mp.buyerStatus(bob)), uint256(MillionairesProblem.BuyerStatus.Defaulted));
        assertEq(uint256(mp.buyerStatus(bob3)), uint256(MillionairesProblem.BuyerStatus.Defaulted));
        assertEq(mp.vault(bob), 0);
        assertEq(mp.vault(bob3), 0);
        assertEq(
            mp.vault(alice),
            GARBLER_DEPOSIT + (2 * EVALUATOR_DEPOSIT)
        );
        assertEq(mp.unresolvedBuyers(), 0);
        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.Open));
    }

    function test_BuyerInputOt_FinalizeAfterDeadline_DefaultsPendingAndAdvances() public {
        _toBuyerInputOtStage();

        vm.prank(bob2);
        mp.submitBuyerReady();

        (, , , uint256 buyerInputDeadline, , , , ) = mp.deadlines();
        vm.warp(buyerInputDeadline + 1);

        vm.prank(alice);
        mp.finalizeBuyerInputAfterDeadline();

        assertEq(uint256(mp.buyerStatus(bob)), uint256(MillionairesProblem.BuyerStatus.Defaulted));
        assertEq(uint256(mp.buyerStatus(bob2)), uint256(MillionairesProblem.BuyerStatus.Ready));
        assertEq(uint256(mp.buyerStatus(bob3)), uint256(MillionairesProblem.BuyerStatus.Defaulted));
        assertEq(mp.vault(bob), 0);
        assertEq(mp.vault(bob3), 0);
        assertEq(mp.vault(bob2), EVALUATOR_DEPOSIT);
        assertEq(
            mp.vault(alice),
            GARBLER_DEPOSIT + (2 * EVALUATOR_DEPOSIT)
        );
        assertEq(mp.unresolvedBuyers(), 0);
        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.Open));
    }

    function test_CommitmentsOt_Timeout_AnyBuyerCanAbortWhenRootsMissingForSomeBuyers() public {
        _toCommitmentsOtStage();

        bytes32[10] memory rootsBob = _matchingOtRoots(bob);
        vm.prank(alice);
        mp.submitOtRootsForBuyer(bob, rootsBob);

        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.CommitmentsOT));

        (, , uint256 commitDeadline, , , , , ) = mp.deadlines();
        vm.warp(commitDeadline + 1);

        uint256 bob2Before = bob2.balance;
        vm.prank(bob2);
        mp.abortPhase2();

        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.Closed));
        assertEq(
            bob2.balance,
            bob2Before + GARBLER_DEPOSIT + EVALUATOR_DEPOSIT
        );
        assertEq(bob.balance, 10 ether);
        assertEq(bob3.balance, 10 ether);
        assertEq(alice.balance, 10 ether - GARBLER_DEPOSIT);
    }

    function test_CloseDispute_MultiBuyer_OneCloseDoesNotAdvanceUntilAllReadyBuyersClose() public {
        _toDisputeStageWithMatchingRoots();

        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.Dispute));
        assertEq(mp.pendingDisputeBuyerClosures(), 3);

        vm.prank(bob);
        mp.closeDispute();
        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.Dispute));
        assertTrue(mp.disputeClosedByBuyer(bob));
        assertEq(mp.pendingDisputeBuyerClosures(), 2);

        vm.prank(bob2);
        mp.closeDispute();
        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.Dispute));
        assertTrue(mp.disputeClosedByBuyer(bob2));
        assertEq(mp.pendingDisputeBuyerClosures(), 1);

        vm.prank(bob3);
        mp.closeDispute();
        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.Labels));
        assertTrue(mp.disputeClosedByBuyer(bob3));
        assertEq(mp.pendingDisputeBuyerClosures(), 0);
    }

    function test_CloseDispute_AfterDeadline_AnyParticipantCanFinalize() public {
        _toDisputeStageWithMatchingRoots();

        (, , , , , uint256 disputeDeadline, , ) = mp.deadlines();
        vm.warp(disputeDeadline + 1);

        vm.prank(alice);
        mp.closeDispute();

        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.Labels));
    }

    function test_CloseDispute_DefaultedBuyerCannotEarlyCloseBeforeDeadline() public {
        _toDisputeStageWithDefaultedBuyer(bob2);

        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.Dispute));
        assertEq(uint256(mp.buyerStatus(bob2)), uint256(MillionairesProblem.BuyerStatus.Defaulted));

        vm.prank(bob2);
        vm.expectRevert("Buyer not active in dispute");
        mp.closeDispute();
    }

    function test_DisputeOt_PerBuyer_FalseChallengeSlashesChallenger() public {
        _toDisputeStageWithMatchingRoots();

        uint256 bob2Before = bob2.balance;
        uint256 aliceBefore = alice.balance;

        vm.prank(bob2);
        mp.disputeObliviousTransferRootForBuyer(bob2, 1);

        assertEq(uint256(mp.currentStage()), uint256(MillionairesProblem.Stage.Closed));
        assertEq(bob2.balance, bob2Before);
        assertEq(alice.balance, aliceBefore + GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
    }

    function test_DisputeOt_PerBuyer_OnlyChallengedBuyer() public {
        _toDisputeStageWithMatchingRoots();

        vm.prank(eve);
        vm.expectRevert("Only challenged buyer");
        mp.disputeObliviousTransferRootForBuyer(bob2, 1);
    }

    function test_DisputeOt_PerBuyer_RevertsWhenChallengerNotDeposited() public {
        _toDisputeStageWithDefaultedBuyer(bob2);

        assertEq(mp.vault(bob2), 0);

        vm.prank(bob2);
        vm.expectRevert("Challenger not deposited");
        mp.disputeObliviousTransferRootForBuyer(bob2, 1);
    }
}
