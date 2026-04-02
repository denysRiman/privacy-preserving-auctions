// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/MillionairesProblem.sol";

contract MockEnsAuctionAdapter is IEnsAuctionAdapter {
    bytes32 public lastNamehash;
    address public lastReceiver;
    uint256 public assignCalls;
    bool public shouldRevert;

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function assign(bytes32 namehash, address to) external override {
        if (shouldRevert) {
            revert("adapter failed");
        }
        assignCalls += 1;
        lastNamehash = namehash;
        lastReceiver = to;
    }
}

contract MillionairesProblemHarness is MillionairesProblem {
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

    function computeLeaf(bytes32 seed, uint256 instanceId, uint256 gateIndex, GateDesc calldata g)
    external view returns (bytes memory)
    {
        return recomputeGateLeafBytes(seed, instanceId, gateIndex, g);
    }

    function computeOtPayloadHash(
        bytes32 garblerSeed,
        bytes32 verifierSeed,
        address buyerAddr,
        uint256 instanceId,
        uint16 inputBit,
        uint8 round
    )
    external view returns (bytes32)
    {
        return _computeOtPayloadHash(garblerSeed, verifierSeed, buyerAddr, instanceId, inputBit, round);
    }

    function computeOtLeafHash(uint16 inputBit, uint8 round, uint8 author, bytes32 payloadHash)
    external pure returns (bytes32)
    {
        return _otTranscriptLeafHash(inputBit, round, author, payloadHash);
    }

    function computeOtRootForTest(
        bytes32 garblerSeed,
        bytes32 verifierSeed,
        address buyerAddr,
        uint256 instanceId
    )
    external
    view
    returns (bytes32)
    {
        return _recomputeOtRoot(garblerSeed, verifierSeed, buyerAddr, instanceId);
    }

    function setSettleDeadlineForTest(uint256 newDeadline) external {
        deadlines.settle = newDeadline;
    }

    function setStageForTest(Stage newStage) external {
        currentStage = newStage;
    }

    // Compatibility helper after removing choose stage from contract.
    function choose(uint256) external view {
        require(currentStage == Stage.Open, "Wrong stage");
    }

    // Compatibility helper after removing choose-timeout branch.
    function abortPhase3() external pure {
        revert("Choose stage removed");
    }
}

contract MillionairesTest is Test {
    MillionairesProblemHarness mp;
    MockEnsAuctionAdapter adapter;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint16 constant BIT_WIDTH = 8;
    uint256 constant GARBLER_DEPOSIT = 1.2 ether;
    uint256 constant EVALUATOR_DEPOSIT = 1.2 ether;
    bytes32 constant ENS_NAMEHASH = keccak256(abi.encodePacked("auction-example.eth"));

    struct LegacyInstanceCommitment {
        bytes32 comSeed;
        bytes32 rootGC;
        bytes32 blobHashGC;
        bytes32 rootOT;
        bytes32 h0;
        bytes32 h1;
    }

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

    function _supportedCircuitId(uint8 variant) internal pure returns (bytes32) {
        if (variant == 0) {
            return hex"4b38f6018cce9cce241946cda9af3509db31d6ef0f4b17e25e4f589faa71da7e";
        }
        if (variant == 1) {
            return hex"50c5a6de5fef89c8d930a3e3bf04578efff567e5c713693ba584c1c47d27eb9a";
        }
        return bytes32(0);
    }

    function _canonicalLayoutRoot(uint8 variant) internal pure returns (bytes32) {
        if (variant == 0) {
            return hex"d15d9ca7dfc1e2a4c47eb4812eb9d08761688c436aad557449954b91df138521";
        }
        if (variant == 1) {
            return hex"35507759e0f8a618b62ca6fd10193e20c63ba04b5e3f520eff66af46b12c301d";
        }
        return bytes32(0);
    }

    function setUp() public {
        bytes32 circuitId_ = _supportedCircuitId(0);
        adapter = new MockEnsAuctionAdapter();
        vm.prank(alice);
        mp = new MillionairesProblemHarness(
            bob,
            bob,
            ENS_NAMEHASH,
            address(adapter),
            circuitId_,
            _canonicalLayoutRoot(0),
            BIT_WIDTH
        );

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _deployHarnessWithCircuit(uint8 variant) internal {
        bytes32 circuitId_ = _supportedCircuitId(variant);
        vm.prank(alice);
        mp = new MillionairesProblemHarness(
            bob,
            bob,
            ENS_NAMEHASH,
            address(adapter),
            circuitId_,
            _canonicalLayoutRoot(variant),
            BIT_WIDTH
        );
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

    function _defaultVerifierSeed() internal pure returns (bytes32) {
        return keccak256("verifier-seed");
    }

    function _defaultVerifierSalt() internal pure returns (bytes32) {
        return keccak256("verifier-salt");
    }

    function _defaultVerifierCommitment() internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_defaultVerifierSeed(), _defaultVerifierSalt()));
    }

    function _seedMaterialForChosenM(uint256 chosenM)
        internal
        view
        returns (bytes32 seed, bytes32 salt, bytes32 commitment)
    {
        require(chosenM < 10, "chosenM out of range");
        for (uint256 nonce = 1; nonce <= 5000; nonce++) {
            seed = keccak256(abi.encodePacked("chosen-m-seed", chosenM, nonce));
            uint256 candidate = uint256(
                keccak256(abi.encodePacked("M", seed, mp.circuitId(), address(mp)))
            ) % 10;
            if (candidate == chosenM) {
                salt = keccak256(abi.encodePacked("chosen-m-salt", chosenM, nonce));
                commitment = keccak256(abi.encodePacked(seed, salt));
                return (seed, salt, commitment);
            }
        }
        revert("seed for chosenM not found");
    }

    function _commitAndRevealForChosenM(uint256 chosenM) internal {
        (bytes32 seed, bytes32 salt, bytes32 commitment) = _seedMaterialForChosenM(chosenM);
        vm.prank(bob);
        mp.commitBuyerSeed(commitment);
        vm.prank(bob);
        mp.revealBuyerSeed(seed, salt);
        assertEq(mp.m(), chosenM);
    }

    function _commitDefaultVerifierSeed() internal {
        if (uint(mp.currentStage()) != uint(MillionairesProblem.Stage.BuyerSeedCommit)) {
            return;
        }
        vm.prank(bob);
        mp.commitBuyerSeed(_defaultVerifierCommitment());
    }

    function _revealDefaultVerifierSeed() internal {
        if (uint(mp.currentStage()) != uint(MillionairesProblem.Stage.BuyerSeedReveal)) {
            return;
        }
        vm.prank(bob);
        mp.revealBuyerSeed(_defaultVerifierSeed(), _defaultVerifierSalt());
    }

    function _submitLegacyCommitments(
        LegacyInstanceCommitment[10] memory commits
    ) internal {
        MillionairesProblem.CoreInstanceCommitment[10] memory core;
        bytes32[10] memory otRoots;

        for (uint256 i = 0; i < 10; i++) {
            bytes32 comSeed = commits[i].comSeed;
            if (comSeed == bytes32(0)) {
                comSeed = keccak256(abi.encodePacked("default-com-seed", i));
            }
            bytes32 rootGC = commits[i].rootGC;
            if (rootGC == bytes32(0)) {
                rootGC = keccak256(abi.encodePacked("default-root-gc", i));
            }
            bytes32 blobHashGC = commits[i].blobHashGC;
            if (blobHashGC == bytes32(0)) {
                blobHashGC = keccak256(abi.encodePacked("default-blob-gc", i));
            }
            bytes32 hOut = commits[i].h0;
            if (hOut == bytes32(0)) {
                hOut = keccak256(abi.encodePacked("default-hOut", i));
            }
            core[i] = MillionairesProblem.CoreInstanceCommitment({
                comSeed: comSeed,
                rootGC: rootGC,
                blobHashGC: blobHashGC,
                hOut: hOut
            });
            if (commits[i].rootOT == bytes32(0)) {
                otRoots[i] = keccak256(abi.encodePacked("default-root-ot", i));
            } else {
                otRoots[i] = commits[i].rootOT;
            }
        }

        _revealDefaultVerifierSeed();
        vm.prank(alice);
        mp.submitCommitments(core);
        vm.prank(alice);
        mp.submitOtRootsForBuyer(bob, otRoots);

        // Legacy helper keeps historical flow tests at Open by resolving buyer input liveness.
        vm.prank(bob);
        mp.submitBuyerReady();
    }

    function _toCommitmentsCoreStage() internal {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();
        _commitDefaultVerifierSeed();
        _revealDefaultVerifierSeed();
    }

    function _validCoreCommitments() internal pure returns (MillionairesProblem.CoreInstanceCommitment[10] memory core) {
        for (uint256 i = 0; i < 10; i++) {
            core[i] = MillionairesProblem.CoreInstanceCommitment({
                comSeed: keccak256(abi.encodePacked("core-com-seed", i)),
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

    function _toBuyerInputOtStage() internal {
        _toCommitmentsCoreStage();
        MillionairesProblem.CoreInstanceCommitment[10] memory core = _validCoreCommitments();
        vm.prank(alice);
        mp.submitCommitments(core);
        bytes32[10] memory roots = _validOtRoots();
        vm.prank(alice);
        mp.submitOtRootsForBuyer(bob, roots);
    }

    function _toOpenStageWithRealSeeds(uint256 chosenM) internal returns (bytes32[] memory realSeeds) {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        realSeeds = new bytes32[](10);
        LegacyInstanceCommitment[10] memory commits;
        for (uint256 i = 0; i < 10; i++) {
            realSeeds[i] = keccak256(abi.encodePacked("open-seed-", i));
            commits[i] = LegacyInstanceCommitment({
                comSeed: keccak256(abi.encodePacked(realSeeds[i])),
                rootGC: keccak256(abi.encodePacked("open-root-gc-", i)),
                blobHashGC: bytes32(0),
                rootOT: keccak256(abi.encodePacked("open-root-ot-", i)),
                h0: keccak256(abi.encodePacked("open-h0-", i)),
                h1: keccak256(abi.encodePacked("open-h1-", i))
            });
        }

        _commitAndRevealForChosenM(chosenM);
        _submitLegacyCommitments(commits);
        assertEq(mp.m(), chosenM);
    }

    function _commutativeNodeHash(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _toSettleStage(bytes32 hOut, bytes32) internal {
        _toCommitmentsCoreStage();
        uint256 chosenM = mp.m();

        LegacyInstanceCommitment[10] memory commits;
        bytes32 evalBlobHash = keccak256("eval-blob-hash-to-settle-stage");
        for (uint256 i = 0; i < 10; i++) {
            commits[i] = LegacyInstanceCommitment({
                comSeed: keccak256(abi.encodePacked(keccak256(abi.encodePacked("seed", i)))),
                rootGC: bytes32(0),
                blobHashGC: i == chosenM ? evalBlobHash : bytes32(0),
                rootOT: bytes32(0),
                h0: hOut,
                h1: bytes32(0)
            });
        }

        _submitLegacyCommitments(commits);

        uint256[] memory indices = new uint256[](9);
        bytes32[] memory seeds = new bytes32[](9);
        uint256 cursor = 0;
        for (uint256 i = 0; i < 10; i++) {
            if (i == chosenM) continue;
            indices[cursor] = i;
            seeds[cursor] = keccak256(abi.encodePacked("seed", i));
            cursor++;
        }

        vm.prank(alice);
        mp.revealOpenings(indices, seeds);

        vm.prank(bob);
        mp.closeDispute();

        bytes32[] memory mockLabels = new bytes32[](uint256(BIT_WIDTH));
        bytes32[] memory txBlobHashes = new bytes32[](1);
        txBlobHashes[0] = evalBlobHash;
        vm.blobhashes(txBlobHashes);
        vm.prank(alice);
        mp.revealGarblerLabels(mockLabels);
    }

    function _encodeOutput(uint16 outWinnerId, uint64 outWinningBid) internal pure returns (bytes memory) {
        return abi.encodePacked(outWinnerId, outWinningBid);
    }

    function _circuitBoundAnchor(bytes32 circuitId_, uint256 instanceId, bytes memory outputBytes)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked("OUT", circuitId_, instanceId, outputBytes));
    }

    function test_Constructor_AllowsArbitraryCircuitIdAndLayoutRoot() public {
        bytes32 arbitraryCircuitId = keccak256(abi.encodePacked("unsupported-circuit-id"));
        bytes32 arbitraryLayoutRoot = keccak256(abi.encodePacked("arbitrary-layout-root"));

        vm.prank(alice);
        MillionairesProblemHarness deployed = new MillionairesProblemHarness(
            bob,
            bob,
            ENS_NAMEHASH,
            address(adapter),
            arbitraryCircuitId,
            arbitraryLayoutRoot,
            BIT_WIDTH
        );

        assertEq(deployed.circuitId(), arbitraryCircuitId);
        assertEq(deployed.circuitLayoutRoot(), arbitraryLayoutRoot);
        assertEq(uint256(deployed.bitWidth()), BIT_WIDTH);
    }

    function test_Constructor_SucceedsWithCanonicalLayoutRoots_ForSupportedCircuitIds() public {
        bytes32 rootVariant0 = hex"d15d9ca7dfc1e2a4c47eb4812eb9d08761688c436aad557449954b91df138521";
        bytes32 rootVariant1 = hex"35507759e0f8a618b62ca6fd10193e20c63ba04b5e3f520eff66af46b12c301d";

        vm.prank(alice);
        MillionairesProblemHarness variant0 = new MillionairesProblemHarness(
            bob,
            bob,
            ENS_NAMEHASH,
            address(adapter),
            _supportedCircuitId(0),
            rootVariant0,
            8
        );
        assertEq(uint256(variant0.bitWidth()), 8);
        assertEq(variant0.circuitLayoutRoot(), rootVariant0);

        vm.prank(alice);
        MillionairesProblemHarness variant1 = new MillionairesProblemHarness(
            bob,
            bob,
            ENS_NAMEHASH,
            address(adapter),
            _supportedCircuitId(1),
            rootVariant1,
            8
        );
        assertEq(uint256(variant1.bitWidth()), 8);
        assertEq(variant1.circuitLayoutRoot(), rootVariant1);
    }

    function test_Constructor_AllowsMismatchedLayoutRootForKnownCircuitId() public {
        vm.prank(alice);
        MillionairesProblemHarness deployed = new MillionairesProblemHarness(
            bob,
            bob,
            ENS_NAMEHASH,
            address(adapter),
            _supportedCircuitId(0),
            hex"35507759e0f8a618b62ca6fd10193e20c63ba04b5e3f520eff66af46b12c301d", // formula=1 root
            8
        );

        assertEq(deployed.circuitId(), _supportedCircuitId(0));
        assertEq(
            deployed.circuitLayoutRoot(),
            hex"35507759e0f8a618b62ca6fd10193e20c63ba04b5e3f520eff66af46b12c301d"
        );
        assertEq(uint256(deployed.bitWidth()), 8);
    }

    function test_SuccessfulDeposits() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        assertEq(mp.vault(alice), GARBLER_DEPOSIT);

        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();
        assertEq(mp.vault(bob), EVALUATOR_DEPOSIT);

        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.BuyerSeedCommit));
    }

    function test_Fail_DoubleDeposit() public {
        vm.startPrank(alice);

        mp.deposit{value: GARBLER_DEPOSIT}();

        vm.expectRevert("Deposit already exists");
        mp.deposit{value: GARBLER_DEPOSIT}();

        vm.stopPrank();
    }

    function test_Fail_WrongAmount() public {
        vm.prank(alice);
        vm.expectRevert("Wrong amount");
        mp.deposit{value: 0.5 ether}();
    }

    function test_Fail_Unauthorized() public {
        address hacker = makeAddr("hacker");
        vm.deal(hacker, GARBLER_DEPOSIT);

        vm.prank(hacker);
        vm.expectRevert("Not authorized");
        mp.deposit{value: GARBLER_DEPOSIT}();
    }

    function test_RefundAfterTimeout() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();

        vm.warp(block.timestamp + 1 hours + 1);

        uint256 balanceBefore = alice.balance;
        vm.prank(alice);
        mp.refund();

        assertEq(alice.balance, balanceBefore + GARBLER_DEPOSIT);
        assertEq(mp.vault(alice), 0);
    }

    function test_SubmitCommitments() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        // 2. Prepare mock commitments for N=10 instances
        LegacyInstanceCommitment[10] memory commits;
        for (uint256 i = 0; i < 10; i++) {
            commits[i] = LegacyInstanceCommitment({
                comSeed: keccak256(abi.encode(i, "seed")),
                rootGC: keccak256(abi.encode(i, "gc")),
                blobHashGC: keccak256(abi.encode(i, "blob-gc")),
                rootOT: keccak256(abi.encode(i, "ot")),
                h0: keccak256(abi.encode(i, "h0")),
                h1: keccak256(abi.encode(i, "h1"))
            });
        }

        // 3. Alice submits commitments
        _commitDefaultVerifierSeed();
        _submitLegacyCommitments(commits);

        // 4. Verify stage transition to Choose
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Open));
    }

    function test_SubmitCommitments_RevertsOnZeroComSeed() public {
        _toCommitmentsCoreStage();
        MillionairesProblem.CoreInstanceCommitment[10] memory core = _validCoreCommitments();
        core[0].comSeed = bytes32(0);

        vm.prank(alice);
        vm.expectRevert("Empty comSeed");
        mp.submitCommitments(core);
    }

    function test_SubmitCommitments_RevertsOnZeroRootGC() public {
        _toCommitmentsCoreStage();
        MillionairesProblem.CoreInstanceCommitment[10] memory core = _validCoreCommitments();
        core[0].rootGC = bytes32(0);

        vm.prank(alice);
        vm.expectRevert("Empty rootGC");
        mp.submitCommitments(core);
    }

    function test_SubmitCommitments_RevertsOnZeroBlobHashGC() public {
        _toCommitmentsCoreStage();
        MillionairesProblem.CoreInstanceCommitment[10] memory core = _validCoreCommitments();
        core[0].blobHashGC = bytes32(0);

        vm.prank(alice);
        vm.expectRevert("Empty blobHashGC");
        mp.submitCommitments(core);
    }

    function test_SubmitCommitments_RevertsOnZeroHOut() public {
        _toCommitmentsCoreStage();
        MillionairesProblem.CoreInstanceCommitment[10] memory core = _validCoreCommitments();
        core[0].hOut = bytes32(0);

        vm.prank(alice);
        vm.expectRevert("Empty hOut");
        mp.submitCommitments(core);
    }

    function test_SubmitOtRoots_RevertsWhenAnyRootZero() public {
        _toCommitmentsCoreStage();
        MillionairesProblem.CoreInstanceCommitment[10] memory core = _validCoreCommitments();
        vm.prank(alice);
        mp.submitCommitments(core);
        _revealDefaultVerifierSeed();

        bytes32[10] memory roots = _validOtRoots();
        roots[3] = bytes32(0);

        vm.prank(alice);
        vm.expectRevert("Empty rootOT");
        mp.submitOtRootsForBuyer(bob, roots);
    }

    function test_SubmitOtRoots_SucceedsWhenAllRootsNonZero() public {
        _toCommitmentsCoreStage();
        MillionairesProblem.CoreInstanceCommitment[10] memory core = _validCoreCommitments();
        vm.prank(alice);
        mp.submitCommitments(core);
        _revealDefaultVerifierSeed();

        bytes32[10] memory roots = _validOtRoots();
        vm.prank(alice);
        mp.submitOtRootsForBuyer(bob, roots);

        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.BuyerInputOT));
        assertEq(mp.unresolvedBuyers(), 1);
        assertEq(uint(mp.buyerStatus(bob)), uint(MillionairesProblem.BuyerStatus.Pending));
        bytes32 rootOT0 = mp.buyerRootOTCommitment(bob, 0);
        bytes32 rootOT9 = mp.buyerRootOTCommitment(bob, 9);
        assertEq(rootOT0, roots[0]);
        assertEq(rootOT9, roots[9]);
    }

    function test_BuyerInputOt_UsesSingleGlobalDeadline() public {
        _toBuyerInputOtStage();

        (, , , uint256 buyerInputDeadline, , , , ) = mp.deadlines();
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.BuyerInputOT));

        vm.prank(alice);
        vm.expectRevert("Buyer input phase still active");
        mp.defaultBuyerInput(bob);

        vm.warp(buyerInputDeadline);
        vm.prank(bob);
        mp.submitBuyerReady();

        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Open));
    }

    function test_BuyerInputOt_BeforeDeadline_OnlyBuyerCanFinalize() public {
        _toBuyerInputOtStage();

        address eve = makeAddr("eve");
        vm.prank(eve);
        vm.expectRevert("Only buyer");
        mp.submitBuyerReady();

        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.BuyerInputOT));
        assertEq(mp.unresolvedBuyers(), 1);
    }

    function test_BuyerInputOt_AfterDeadline_AnyoneCanDefaultAndSlashBuyer() public {
        _toBuyerInputOtStage();

        (, , , uint256 buyerInputDeadline, , , , ) = mp.deadlines();
        vm.warp(buyerInputDeadline + 1);

        address eve = makeAddr("eve");
        vm.prank(eve);
        mp.defaultBuyerInput(bob);

        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Open));
        assertEq(mp.unresolvedBuyers(), 0);
        assertEq(uint(mp.buyerStatus(bob)), uint(MillionairesProblem.BuyerStatus.Defaulted));
        assertEq(mp.vault(bob), 0);
        assertEq(mp.vault(alice), GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
    }

    function test_BuyerInputOt_DoesNotAdvanceUntilBuyerResolved() public {
        _toBuyerInputOtStage();

        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.BuyerInputOT));
        assertEq(mp.unresolvedBuyers(), 1);

        vm.prank(bob);
        vm.expectRevert("Wrong stage");
        mp.choose(0);

        vm.prank(bob);
        mp.submitBuyerReady();
        assertEq(mp.unresolvedBuyers(), 0);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Open));
    }

    function test_RevealVerifierSeed_Success() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        vm.prank(bob);
        mp.commitBuyerSeed(_defaultVerifierCommitment());
        vm.prank(bob);
        mp.revealBuyerSeed(_defaultVerifierSeed(), _defaultVerifierSalt());

        assertEq(mp.verifierSeed(), _defaultVerifierSeed());
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.CommitmentsCore));
    }

    function test_RevealVerifierSeed_Twice_Reverts() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        vm.prank(bob);
        mp.commitBuyerSeed(_defaultVerifierCommitment());
        vm.prank(bob);
        mp.revealBuyerSeed(_defaultVerifierSeed(), _defaultVerifierSalt());

        vm.prank(bob);
        vm.expectRevert("Wrong stage");
        mp.revealBuyerSeed(_defaultVerifierSeed(), _defaultVerifierSalt());
    }

    function test_RevealVerifierSeed_WrongSalt_Reverts() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        vm.prank(bob);
        mp.commitBuyerSeed(_defaultVerifierCommitment());

        vm.prank(bob);
        vm.expectRevert("Invalid buyer seed reveal");
        mp.revealBuyerSeed(_defaultVerifierSeed(), keccak256("wrong-salt"));
    }

    function test_RevealVerifierSeed_EmptySeed_Reverts() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        vm.prank(bob);
        mp.commitBuyerSeed(_defaultVerifierCommitment());

        vm.prank(bob);
        vm.expectRevert("Invalid buyer seed reveal");
        mp.revealBuyerSeed(bytes32(0), _defaultVerifierSalt());
    }

    function test_FinalizeBuyerSeedCommitAfterDeadline_AlicePenalty() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        vm.warp(block.timestamp + 1 hours + 1 seconds);

        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        mp.finalizeBuyerSeedCommitAfterDeadline();

        assertEq(alice.balance, aliceBalanceBefore);
        assertEq(mp.vault(alice), GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.CommitmentsCore));
    }

    function test_AbortPhase2_BobPenalty() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();
        _commitDefaultVerifierSeed();
        _revealDefaultVerifierSeed();

        vm.warp(block.timestamp + 1 hours + 1 seconds);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        mp.abortPhase2();

        // Bob should have his 1 ETH back + Alice's 1 ETH penalty
        assertEq(bob.balance, bobBalanceBefore + GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Closed));
    }

    function test_Fail_AliceLateCommitment() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();
        _commitDefaultVerifierSeed();
        _revealDefaultVerifierSeed();

        vm.warp(block.timestamp + 1 hours + 1 seconds);

        MillionairesProblem.CoreInstanceCommitment[10] memory commits;
        vm.prank(alice);
        vm.expectRevert("Commitment deadline missed");
        mp.submitCommitments(commits);
    }

    function test_BobChoice() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        LegacyInstanceCommitment[10] memory commits;
        _commitAndRevealForChosenM(5);
        _submitLegacyCommitments(commits);

        assertEq(mp.m(), 5);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Open));

        assertEq(mp.getSOpenLength(), 9);
    }

    function test_Choose_BeforeSubmitCommitments_Reverts() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        vm.prank(bob);
        vm.expectRevert("Wrong stage");
        mp.choose(0);
    }

    function test_SubmitOtRoots_BeforeSeedReveal_Reverts() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();
        _commitDefaultVerifierSeed();
        MillionairesProblem.CoreInstanceCommitment[10] memory core = _validCoreCommitments();
        vm.prank(alice);
        vm.expectRevert("Wrong stage");
        mp.submitCommitments(core);

        bytes32[10] memory roots;
        vm.prank(alice);
        vm.expectRevert("Wrong stage");
        mp.submitOtRootsForBuyer(bob, roots);
    }

    function test_Choose_BeforeOtRootsSubmitted_Reverts() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();
        _commitDefaultVerifierSeed();
        _revealDefaultVerifierSeed();

        MillionairesProblem.CoreInstanceCommitment[10] memory core = _validCoreCommitments();
        vm.prank(alice);
        mp.submitCommitments(core);

        vm.prank(bob);
        vm.expectRevert("Wrong stage");
        mp.choose(0);
    }

    function test_Choose_Cleanup_DoesNotLeakOldSOpen() public {
        uint256 firstM = 3;
        bytes32[] memory realSeeds = _toOpenStageWithRealSeeds(firstM);

        assertEq(mp.getSOpenLength(), 9);
        bool containsFirstM = false;
        for (uint256 i = 0; i < mp.getSOpenLength(); i++) {
            uint256 idx = mp.sOpen(i);
            if (idx == firstM) containsFirstM = true;
            if (idx != firstM) {
                assertEq(mp.revealedSeeds(idx), bytes32(0));
                assertEq(realSeeds[idx] != bytes32(0), true);
            }
        }
        assertFalse(containsFirstM);
        assertEq(mp.m(), firstM);
    }

    function test_RevealSubmitChoose_SuccessPath() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        _commitAndRevealForChosenM(3);

        LegacyInstanceCommitment[10] memory commits;
        for (uint256 i = 0; i < 10; i++) {
            commits[i] = LegacyInstanceCommitment({
                comSeed: keccak256(abi.encode(i, "seed")),
                rootGC: keccak256(abi.encode(i, "gc")),
                blobHashGC: keccak256(abi.encode(i, "blob-gc")),
                rootOT: keccak256(abi.encode(i, "ot")),
                h0: keccak256(abi.encode(i, "h0")),
                h1: keccak256(abi.encode(i, "h1"))
            });
        }

        _submitLegacyCommitments(commits);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Open));
        assertEq(mp.m(), 3);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Open));
    }

    function test_AbortPhase3_AlicePenalty() public {
        vm.prank(alice);
        vm.expectRevert("Choose stage removed");
        mp.abortPhase3();
    }

    function test_RevealOpenings_Success() public {
        uint256 chosenM = 5;
        bytes32[] memory realSeeds = _toOpenStageWithRealSeeds(chosenM);

        uint256[] memory indices = new uint256[](9);
        bytes32[] memory seedsToReveal = new bytes32[](9);
        uint256 counter = 0;
        for (uint256 i = 0; i < 10; i++) {
            if (i == chosenM) continue;
            indices[counter] = i;
            seedsToReveal[counter] = realSeeds[i];
            counter++;
        }

        vm.prank(alice);
        mp.revealOpenings(indices, seedsToReveal);

        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Dispute));
        assertEq(mp.revealedSeeds(0), realSeeds[0]);
        assertEq(mp.revealedSeeds(chosenM), bytes32(0));
    }

    function test_RevealOpenings_RevertsOnSeedsLengthMismatch() public {
        bytes32[] memory realSeeds = _toOpenStageWithRealSeeds(5);

        uint256[] memory indices = new uint256[](9);
        bytes32[] memory seedsToReveal = new bytes32[](8);
        uint256 counter = 0;
        for (uint256 i = 0; i < 10; i++) {
            if (i == 5) continue;
            indices[counter] = i;
            if (counter < 8) {
                seedsToReveal[counter] = realSeeds[i];
            }
            counter++;
        }

        vm.prank(alice);
        vm.expectRevert("Must provide N-1 seeds");
        mp.revealOpenings(indices, seedsToReveal);
    }

    function test_RevealOpenings_RevertsOnDuplicateIndices() public {
        bytes32[] memory realSeeds = _toOpenStageWithRealSeeds(9);

        uint256[] memory indices = new uint256[](9);
        bytes32[] memory seedsToReveal = new bytes32[](9);
        for (uint256 i = 0; i < 9; i++) {
            indices[i] = i;
            seedsToReveal[i] = realSeeds[i];
        }
        indices[1] = 0;
        seedsToReveal[1] = realSeeds[0];

        vm.prank(alice);
        vm.expectRevert("Duplicate index");
        mp.revealOpenings(indices, seedsToReveal);
    }

    function test_RevealOpenings_RevertsWhenIndicesNotSOpen() public {
        bytes32[] memory realSeeds = _toOpenStageWithRealSeeds(9);

        uint256[] memory indices = new uint256[](9);
        bytes32[] memory seedsToReveal = new bytes32[](9);
        indices[0] = 0;
        seedsToReveal[0] = realSeeds[0];
        indices[1] = 2;
        seedsToReveal[1] = realSeeds[2];
        indices[2] = 3;
        seedsToReveal[2] = realSeeds[3];
        indices[3] = 4;
        seedsToReveal[3] = realSeeds[4];
        indices[4] = 5;
        seedsToReveal[4] = realSeeds[5];
        indices[5] = 6;
        seedsToReveal[5] = realSeeds[6];
        indices[6] = 7;
        seedsToReveal[6] = realSeeds[7];
        indices[7] = 8;
        seedsToReveal[7] = realSeeds[8];
        indices[8] = 9;
        seedsToReveal[8] = realSeeds[9];

        vm.prank(alice);
        vm.expectRevert("Index not in sOpen");
        mp.revealOpenings(indices, seedsToReveal);
    }

    function test_AbortPhase4_AlicePenalty() public {
        // Setup to Stage.Open
        test_BobChoice();
        vm.warp(block.timestamp + 1 hours + 1 seconds);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        mp.abortPhase4();

        assertEq(bob.balance, bobBalanceBefore + GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Closed));
    }

    function test_RevealGarblerLabels_Success() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        uint256 chosenM = 5;
        bytes32 evalRootGc = keccak256("eval-root-gc");
        bytes32 evalBlobHash = keccak256("eval-blob-hash");
        bytes32[] memory realSeeds = new bytes32[](10);
        LegacyInstanceCommitment[10] memory commits;

        for (uint256 i = 0; i < 10; i++) {
            realSeeds[i] = keccak256(abi.encodePacked("secret_seed_", i));
            commits[i] = LegacyInstanceCommitment({
                comSeed: keccak256(abi.encodePacked(realSeeds[i])),
                rootGC: i == chosenM ? evalRootGc : bytes32(0),
                blobHashGC: i == chosenM ? evalBlobHash : bytes32(0),
                rootOT: bytes32(0),
                h0: bytes32(0),
                h1: bytes32(0)
            });
        }

        _commitAndRevealForChosenM(chosenM);
        _submitLegacyCommitments(commits);

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

        bytes32[] memory mockLabels = new bytes32[](uint256(BIT_WIDTH));
        for(uint256 i = 0; i < uint256(BIT_WIDTH); i++) {
            mockLabels[i] = keccak256(abi.encodePacked("alice_label_", i));
        }

        bytes32[] memory txBlobHashes = new bytes32[](1);
        txBlobHashes[0] = evalBlobHash;
        vm.blobhashes(txBlobHashes);
        vm.prank(alice);
        mp.revealGarblerLabels(mockLabels);

        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Settle));
    }

    function test_RevealGarblerLabels_RevertsWhenLabelsLengthMismatch() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        uint256 chosenM = 5;
        bytes32 evalRootGc = keccak256("eval-root-gc");
        bytes32 evalBlobHash = keccak256("eval-blob-hash");
        bytes32[] memory realSeeds = new bytes32[](10);
        LegacyInstanceCommitment[10] memory commits;

        for (uint256 i = 0; i < 10; i++) {
            realSeeds[i] = keccak256(abi.encodePacked("secret_seed_", i));
            commits[i] = LegacyInstanceCommitment({
                comSeed: keccak256(abi.encodePacked(realSeeds[i])),
                rootGC: i == chosenM ? evalRootGc : bytes32(0),
                blobHashGC: i == chosenM ? evalBlobHash : bytes32(0),
                rootOT: bytes32(0),
                h0: bytes32(0),
                h1: bytes32(0)
            });
        }

        _commitAndRevealForChosenM(chosenM);
        _submitLegacyCommitments(commits);

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

        bytes32[] memory wrongLabels = new bytes32[](uint256(BIT_WIDTH) + 1);
        for (uint256 i = 0; i < wrongLabels.length; i++) {
            wrongLabels[i] = keccak256(abi.encodePacked("bad_len_label_", i));
        }

        bytes32[] memory txBlobHashes = new bytes32[](1);
        txBlobHashes[0] = evalBlobHash;
        vm.blobhashes(txBlobHashes);
        vm.prank(alice);
        vm.expectRevert("Bad labels length");
        mp.revealGarblerLabels(wrongLabels);
    }

    function test_Fail_RevealGarblerLabels_WhenBlobMissing() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        uint256 chosenM = 5;
        bytes32 evalRootGc = keccak256("eval-root-gc");
        bytes32 evalBlobHash = keccak256("eval-blob-hash");
        bytes32[] memory realSeeds = new bytes32[](10);
        LegacyInstanceCommitment[10] memory commits;

        for (uint256 i = 0; i < 10; i++) {
            realSeeds[i] = keccak256(abi.encodePacked("secret_seed_", i));
            commits[i] = LegacyInstanceCommitment({
                comSeed: keccak256(abi.encodePacked(realSeeds[i])),
                rootGC: i == chosenM ? evalRootGc : bytes32(0),
                blobHashGC: i == chosenM ? evalBlobHash : bytes32(0),
                rootOT: bytes32(0),
                h0: bytes32(0),
                h1: bytes32(0)
            });
        }

        _commitAndRevealForChosenM(chosenM);
        _submitLegacyCommitments(commits);

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

        bytes32[] memory mockLabels = new bytes32[](uint256(BIT_WIDTH));
        vm.prank(alice);
        vm.expectRevert("Garbled Table Blob missing");
        mp.revealGarblerLabels(mockLabels);
    }

    function test_Fail_RevealGarblerLabels_WhenBlobHashMismatchesCommitment() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        uint256 chosenM = 5;
        bytes32 evalRootGc = keccak256("eval-root-gc");
        bytes32 evalBlobHash = keccak256("eval-blob-hash");
        bytes32[] memory realSeeds = new bytes32[](10);
        LegacyInstanceCommitment[10] memory commits;

        for (uint256 i = 0; i < 10; i++) {
            realSeeds[i] = keccak256(abi.encodePacked("secret_seed_", i));
            commits[i] = LegacyInstanceCommitment({
                comSeed: keccak256(abi.encodePacked(realSeeds[i])),
                rootGC: i == chosenM ? evalRootGc : bytes32(0),
                blobHashGC: i == chosenM ? evalBlobHash : bytes32(0),
                rootOT: bytes32(0),
                h0: bytes32(0),
                h1: bytes32(0)
            });
        }

        _commitAndRevealForChosenM(chosenM);
        _submitLegacyCommitments(commits);

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

        bytes32[] memory mockLabels = new bytes32[](uint256(BIT_WIDTH));
        bytes32[] memory txBlobHashes = new bytes32[](1);
        txBlobHashes[0] = bytes32(uint256(evalBlobHash) ^ 1);
        vm.blobhashes(txBlobHashes);

        vm.prank(alice);
        vm.expectRevert("Blob does not match Phase 2 commitment");
        mp.revealGarblerLabels(mockLabels);
    }

    function test_AbortPhase5_AlicePenalty() public {
        test_RevealOpenings_Success();

        vm.prank(bob);
        mp.closeDispute();

        vm.warp(block.timestamp + 2 hours + 1 seconds);

        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        mp.abortPhase5();

        assertEq(bob.balance, bobBalanceBefore + GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Closed));
    }

    function test_FinalSettlement_ValidOutput_MovesToAssignmentThenFinalizes() public {
        bytes memory output = _encodeOutput(0, 77);
        bytes32 circuitId_ = mp.circuitId();
        uint256 expectedM = uint256(
            keccak256(abi.encodePacked("M", _defaultVerifierSeed(), circuitId_, address(mp)))
        ) % 10;
        _toSettleStage(
            _circuitBoundAnchor(circuitId_, expectedM, output),
            bytes32(0)
        );

        uint256 aliceBalanceBefore = alice.balance;
        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        mp.settle(output);

        assertEq(alice.balance, aliceBalanceBefore);
        assertEq(bob.balance, bobBalanceBefore);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Assignment));
        assertEq(mp.winnerId(), 0);
        assertEq(mp.winningBid(), 77);
        assertEq(mp.winnerBuyer(), bob);
        assertEq(mp.winnerReceiver(), bob);
        assertEq(adapter.assignCalls(), 0);

        vm.prank(alice);
        mp.finalizeAssignment();

        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Closed));
        assertEq(alice.balance, aliceBalanceBefore + GARBLER_DEPOSIT + 77);
        assertEq(bob.balance, bobBalanceBefore + EVALUATOR_DEPOSIT - 77);
        assertEq(adapter.assignCalls(), 1);
        assertEq(adapter.lastNamehash(), ENS_NAMEHASH);
        assertEq(adapter.lastReceiver(), bob);
    }

    function test_FinalSettlement_AnotherBid_FinalizeAssignmentPaysOut() public {
        bytes memory output = _encodeOutput(0, 5);
        bytes32 circuitId_ = mp.circuitId();
        uint256 expectedM = uint256(
            keccak256(abi.encodePacked("M", _defaultVerifierSeed(), circuitId_, address(mp)))
        ) % 10;
        _toSettleStage(
            _circuitBoundAnchor(circuitId_, expectedM, output),
            bytes32(0)
        );

        uint256 aliceBalanceBefore = alice.balance;
        uint256 bobBalanceBefore = bob.balance;
        vm.prank(bob);
        mp.settle(output);

        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Assignment));
        assertEq(mp.winnerId(), 0);
        assertEq(mp.winningBid(), 5);

        vm.prank(bob);
        mp.finalizeAssignment();

        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Closed));
        assertEq(alice.balance, aliceBalanceBefore + GARBLER_DEPOSIT + 5);
        assertEq(bob.balance, bobBalanceBefore + EVALUATOR_DEPOSIT - 5);
    }

    function test_AbortPhase6_WorksInAssignmentStageAfterDeadline() public {
        bytes memory output = _encodeOutput(0, 33);
        bytes32 circuitId_ = mp.circuitId();
        uint256 expectedM = uint256(
            keccak256(abi.encodePacked("M", _defaultVerifierSeed(), circuitId_, address(mp)))
        ) % 10;
        _toSettleStage(
            _circuitBoundAnchor(circuitId_, expectedM, output),
            bytes32(0)
        );

        vm.prank(bob);
        mp.settle(output);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Assignment));

        (, , , , , , , uint256 settleDeadline) = mp.deadlines();
        vm.warp(settleDeadline + 1);

        uint256 aliceBalanceBefore = alice.balance;
        vm.prank(alice);
        mp.abortPhase6();

        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Closed));
        assertEq(alice.balance, aliceBalanceBefore + GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
    }

    function test_FinalSettlement_LowerCircuit_ValidOutput() public {
        _deployHarnessWithCircuit(1);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        bytes memory output = _encodeOutput(0, 9);
        bytes32 circuitId_ = mp.circuitId();
        uint256 expectedM = uint256(
            keccak256(abi.encodePacked("M", _defaultVerifierSeed(), circuitId_, address(mp)))
        ) % 10;
        _toSettleStage(
            _circuitBoundAnchor(circuitId_, expectedM, output),
            bytes32(0)
        );

        vm.prank(bob);
        mp.settle(output);

        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Assignment));
        assertEq(mp.winnerId(), 0);
        assertEq(mp.winningBid(), 9);
    }

    function test_FinalizeAssignment_RevertsBeforeSettle() public {
        vm.expectRevert("Wrong stage");
        mp.finalizeAssignment();
    }

    function test_FinalizeAssignment_RevertsWhenCalledTwice() public {
        bytes memory output = _encodeOutput(0, 12);
        bytes32 circuitId_ = mp.circuitId();
        uint256 expectedM = uint256(
            keccak256(abi.encodePacked("M", _defaultVerifierSeed(), circuitId_, address(mp)))
        ) % 10;
        _toSettleStage(
            _circuitBoundAnchor(circuitId_, expectedM, output),
            bytes32(0)
        );

        vm.prank(bob);
        mp.settle(output);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Assignment));

        vm.prank(bob);
        mp.finalizeAssignment();
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Closed));

        mp.setStageForTest(MillionairesProblem.Stage.Assignment);

        vm.expectRevert("Assignment already finalized");
        mp.finalizeAssignment();
    }

    function test_FinalSettlement_CrossCircuitAnchors_RevertInvalidOutputCommitment() public {
        _deployHarnessWithCircuit(1);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);

        bytes memory output = _encodeOutput(0, 11);
        _toSettleStage(
            _circuitBoundAnchor(_supportedCircuitId(0), 0, output), // Anchors committed for circuit variant 0
            bytes32(0)
        );

        vm.prank(bob);
        vm.expectRevert("Invalid output commitment");
        mp.settle(output); // Decoding runs with circuit variant 1 and must not match variant-0 anchor
    }

    function test_FinalSettlement_InstanceMismatchAnchors_RevertInvalidOutputCommitment() public {
        bytes memory output = _encodeOutput(0, 22);
        bytes32 circuitId_ = mp.circuitId();
        _toSettleStage(
            _circuitBoundAnchor(circuitId_, 1, output), // Wrong instance; settle runs on m=0
            bytes32(0)
        );

        vm.prank(bob);
        vm.expectRevert("Invalid output commitment");
        mp.settle(output);
    }

    function test_ChallengeGateLeaf_FalseChallenge_SlashesBob() public {
        bytes32 seed = keccak256("seed");
        RustGateChallengeVector memory v = _rustVectorDefaultAndGate();
        uint256 instanceId = v.challengeInstanceId;
        uint256 gateIndex = v.gateIndex;
        MillionairesProblem.GateDesc memory g = MillionairesProblem.GateDesc({
            gateType: MillionairesProblem.GateType(v.gateType),
            wireA: v.wireA,
            wireB: v.wireB,
            wireC: v.wireC
        });

        // leafBytes that contract itself would recompute
        bytes memory leaf = mp.computeLeaf(seed, instanceId, gateIndex, g);

        bytes32[] memory proof = new bytes32[](0);
        // Single-block incremental chain root: IH_1 = H(0 || block_1).
        bytes32 root = _processIncrementalProof(_gateLeafHash(gateIndex, leaf), proof);
        _toDisputeWithRoot(seed, root, 9);

        bytes32[] memory layoutProof = v.layoutProof;

        uint256 aliceBefore = alice.balance;

        vm.prank(bob);
        mp.challengeGateLeaf(instanceId, gateIndex, g, leaf, proof, layoutProof);

        // Bob loses, Alice receives both deposits
        assertEq(alice.balance, aliceBefore + GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Closed));
    }

    function test_ChallengeGateLeaf_DetectCheat_SlashesAlice() public {
        bytes32 seed = keccak256("seed");
        RustGateChallengeVector memory v = _rustVectorDefaultAndGate();
        uint256 instanceId = v.challengeInstanceId;
        uint256 gateIndex = v.gateIndex;
        MillionairesProblem.GateDesc memory g = MillionairesProblem.GateDesc({
            gateType: MillionairesProblem.GateType(v.gateType),
            wireA: v.wireA,
            wireB: v.wireB,
            wireC: v.wireC
        });

        bytes memory expectedLeaf = mp.computeLeaf(seed, instanceId, gateIndex, g);
        bytes memory fakeLeaf = _mutateFirstByte(expectedLeaf);

        bytes32[] memory proof = new bytes32[](0);
        bytes32 root = _processIncrementalProof(_gateLeafHash(gateIndex, fakeLeaf), proof);
        _toDisputeWithRoot(seed, root, 9);

        bytes32[] memory layoutProof = v.layoutProof;
        uint256 bobBefore = bob.balance;

        vm.prank(bob);
        mp.challengeGateLeaf(instanceId, gateIndex, g, fakeLeaf, proof, layoutProof);

        assertEq(bob.balance, bobBefore + GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Closed));
    }

    function test_ChallengeGateLeaf_BadIHProof_Reverts() public {
        bytes32 seed = keccak256("seed");
        RustGateChallengeVector memory v = _rustVectorDefaultAndGate();
        uint256 instanceId = v.challengeInstanceId;
        uint256 gateIndex = v.gateIndex;
        MillionairesProblem.GateDesc memory g = MillionairesProblem.GateDesc({
            gateType: MillionairesProblem.GateType(v.gateType),
            wireA: v.wireA,
            wireB: v.wireB,
            wireC: v.wireC
        });

        bytes memory leaf = mp.computeLeaf(seed, instanceId, gateIndex, g);

        // Commit wrong root
        bytes32 wrongRoot = keccak256("wrong");
        _toDisputeWithRoot(seed, wrongRoot, 9);

        bytes32[] memory proof = new bytes32[](0);
        bytes32[] memory layoutProof = v.layoutProof;

        vm.prank(bob);
        vm.expectRevert("Bad IH proof");
        mp.challengeGateLeaf(instanceId, gateIndex, g, leaf, proof, layoutProof);
    }

    function test_ChallengeGateLeaf_BadLayoutProof_Reverts() public {
        bytes32 seed = keccak256("seed");
        RustGateChallengeVector memory v = _rustVectorDefaultAndGate();
        uint256 instanceId = v.challengeInstanceId;
        uint256 gateIndex = v.gateIndex;
        MillionairesProblem.GateDesc memory g = MillionairesProblem.GateDesc({
            gateType: MillionairesProblem.GateType(v.gateType),
            wireA: v.wireA,
            wireB: v.wireB,
            wireC: v.wireC
        });
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
        RustGateChallengeVector memory v = _rustVectorDefaultAndGate();
        uint256 instanceId = v.challengeInstanceId;
        uint256 gateIndex = v.gateIndex;
        MillionairesProblem.GateDesc memory g = MillionairesProblem.GateDesc({
            gateType: MillionairesProblem.GateType(v.gateType),
            wireA: v.wireA,
            wireB: v.wireB,
            wireC: v.wireC
        });

        bytes32[] memory proof = new bytes32[](0);
        // Correct committed leaf.
        bytes memory leaf = mp.computeLeaf(seed, instanceId, gateIndex, g);
        bytes32 root = _processIncrementalProof(_gateLeafHash(gateIndex, leaf), proof);
        _toDisputeWithRoot(seed, root, 9);

        bytes32[] memory layoutProof = v.layoutProof;

        uint256 aliceBefore = alice.balance;

        vm.prank(bob);
        mp.disputeGarbledTable(instanceId, seed, gateIndex, g, leaf, proof, layoutProof);

        // Same result as challengeGateLeaf on matching leaf: Bob false-challenged.
        assertEq(alice.balance, aliceBefore + GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Closed));
    }

    function test_DisputeGarbledTable_DelegatesToChallenge_SlashesAliceOnMismatch() public {
        bytes32 seed = keccak256("seed");
        RustGateChallengeVector memory v = _rustVectorDefaultAndGate();
        uint256 instanceId = v.challengeInstanceId;
        uint256 gateIndex = v.gateIndex;
        MillionairesProblem.GateDesc memory g = MillionairesProblem.GateDesc({
            gateType: MillionairesProblem.GateType(v.gateType),
            wireA: v.wireA,
            wireB: v.wireB,
            wireC: v.wireC
        });

        bytes memory expectedLeaf = mp.computeLeaf(seed, instanceId, gateIndex, g);
        bytes memory fakeLeaf = _mutateFirstByte(expectedLeaf);

        bytes32[] memory proof = new bytes32[](0);
        bytes32 root = _processIncrementalProof(_gateLeafHash(gateIndex, fakeLeaf), proof);
        _toDisputeWithRoot(seed, root, 9);

        bytes32[] memory layoutProof = v.layoutProof;
        uint256 bobBefore = bob.balance;

        vm.prank(bob);
        mp.disputeGarbledTable(instanceId, seed, gateIndex, g, fakeLeaf, proof, layoutProof);

        // Same result as challengeGateLeaf on mismatch: Alice cheated.
        assertEq(bob.balance, bobBefore + GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Closed));
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
        vm.expectRevert("Seed mismatch");
        mp.disputeGarbledTable(0, wrongSeed, 0, g, leaf, proof, layoutProof);
    }

    function test_DisputeGarbledTable_IndexOutOfBounds_Reverts() public {
        bytes32 seed = keccak256("seed");
        MillionairesProblem.GateDesc memory g = _defaultAndGate();

        bytes32[] memory proof = new bytes32[](0);
        bytes memory leaf = mp.computeLeaf(seed, 0, 0, g);
        bytes32 root = _processIncrementalProof(_gateLeafHash(0, leaf), proof);
        _toDisputeWithRoot(seed, root, 9);

        bytes32[] memory layoutProof = new bytes32[](0);

        vm.prank(bob);
        vm.expectRevert("Index out of bounds");
        mp.disputeGarbledTable(10, seed, 0, g, leaf, proof, layoutProof);
    }

    function test_DisputeGarbledTable_NotOpenedInstance_Reverts() public {
        bytes32 seed = keccak256("seed");
        RustGateChallengeVector memory v = _rustVectorDefaultAndGate();
        uint256 gateIndex = v.gateIndex;
        MillionairesProblem.GateDesc memory g = MillionairesProblem.GateDesc({
            gateType: MillionairesProblem.GateType(v.gateType),
            wireA: v.wireA,
            wireB: v.wireB,
            wireC: v.wireC
        });

        bytes32[] memory proof = new bytes32[](0);
        bytes memory leaf = mp.computeLeaf(seed, 9, gateIndex, g);
        bytes32 root = _processIncrementalProof(_gateLeafHash(gateIndex, leaf), proof);
        _toDisputeWithRoot(seed, root, 9); // instance 9 is m, hence not opened

        bytes32[] memory layoutProof = v.layoutProof;

        vm.prank(bob);
        vm.expectRevert("Not an opened instance");
        mp.disputeGarbledTable(9, bytes32(0), gateIndex, g, leaf, proof, layoutProof);
    }

    function test_CloseDispute_NoOtPayloadRequirement() public {
        bytes32 garblerSeed = keccak256("garbler-seed");
        bytes32 verifierSeed = _defaultVerifierSeed();
        bytes32 rootOT = mp.computeOtRootForTest(garblerSeed, verifierSeed, bob, 0);

        _toDisputeWithRoots(
            garblerSeed,
            bytes32(0),
            rootOT,
            9
        );

        vm.prank(bob);
        mp.closeDispute();
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Labels));
    }

    function test_DisputeObliviousTransferRoot_SlashesAliceOnMismatch() public {
        bytes32 garblerSeed = keccak256("garbler-seed");
        bytes32 verifierSeed = _defaultVerifierSeed();
        bytes32 badRootOT = bytes32(uint256(mp.computeOtRootForTest(garblerSeed, verifierSeed, bob, 0)) ^ 1);

        _toDisputeWithRoots(
            garblerSeed,
            bytes32(0),
            badRootOT,
            9
        );

        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        mp.disputeObliviousTransferRoot(0);
        assertEq(bob.balance, bobBefore + GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Closed));
    }

    function test_DisputeObliviousTransferRoot_SlashesBobOnFalseChallenge() public {
        bytes32 garblerSeed = keccak256("garbler-seed");
        bytes32 verifierSeed = _defaultVerifierSeed();
        bytes32 rootOT = mp.computeOtRootForTest(garblerSeed, verifierSeed, bob, 0);

        _toDisputeWithRoots(
            garblerSeed,
            bytes32(0),
            rootOT,
            9
        );

        uint256 aliceBefore = alice.balance;
        vm.prank(bob);
        mp.disputeObliviousTransferRoot(0);
        assertEq(alice.balance, aliceBefore + GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Closed));
    }

    function test_DisputeObliviousTransferRoot_OnlyBuyer_RevertsForAlice() public {
        bytes32 garblerSeed = keccak256("garbler-seed");
        bytes32 verifierSeed = _defaultVerifierSeed();
        bytes32 rootOT = mp.computeOtRootForTest(garblerSeed, verifierSeed, bob, 0);

        _toDisputeWithRoots(
            garblerSeed,
            bytes32(0),
            rootOT,
            9
        );

        vm.prank(alice);
        vm.expectRevert("Only buyer");
        mp.disputeObliviousTransferRoot(0);
    }

    function test_DisputeObliviousTransferRoot_IndexOutOfBounds_Reverts() public {
        bytes32 garblerSeed = keccak256("garbler-seed");
        bytes32 verifierSeed = _defaultVerifierSeed();
        bytes32 rootOT = mp.computeOtRootForTest(garblerSeed, verifierSeed, bob, 0);

        _toDisputeWithRoots(
            garblerSeed,
            bytes32(0),
            rootOT,
            9
        );

        vm.prank(bob);
        vm.expectRevert("Index out of bounds");
        mp.disputeObliviousTransferRoot(10);
    }

    function test_SubmitCommitments_BeforeVerifierSeed_Reverts() public {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        MillionairesProblem.CoreInstanceCommitment[10] memory commits;
        vm.prank(alice);
        vm.expectRevert("Wrong stage");
        mp.submitCommitments(commits);
    }

    //Main test for checking if the implementation on Rust works
    function test_ChallengeGateLeaf_RustVector_Editable() public {
        RustGateChallengeVector memory v = _rustVectorDefaultAndGate();
        // Section-5.2 update: rootGC is the terminal state of an incremental-hash chain.
        v.rootGCs[v.challengeInstanceId] =
            _processIncrementalProof(_gateLeafHash(v.gateIndex, v.leafBytes), v.ihProof);

        // Deploy fresh contract with Rust vector identifiers.
        vm.prank(alice);
        mp = new MillionairesProblemHarness(
            bob,
            bob,
            ENS_NAMEHASH,
            address(adapter),
            v.circuitId,
            v.circuitLayoutRoot,
            BIT_WIDTH
        );

        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        require(v.comSeeds.length == 10, "comSeeds must have 10 values");
        require(v.rootGCs.length == 10, "rootGCs must have 10 values");
        require(v.openIndices.length == 9, "openIndices must have 9 values");
        require(v.openSeeds.length == 9, "openSeeds must have 9 values");
        require(v.challengeInstanceId != v.mChoice, "challenge instance cannot be m");

        LegacyInstanceCommitment[10] memory commits;
        for (uint256 i = 0; i < 10; i++) {
            commits[i] = LegacyInstanceCommitment({
                comSeed: v.comSeeds[i],
                rootGC: v.rootGCs[i],
                blobHashGC: bytes32(0),
                rootOT: bytes32(0),
                h0: bytes32(0),
                h1: bytes32(0)
            });
        }

        _commitAndRevealForChosenM(v.mChoice);
        _submitLegacyCommitments(commits);
        assertEq(mp.m(), v.mChoice);

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
            assertEq(alice.balance, aliceBefore + GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
            assertEq(bob.balance, bobBefore);
        } else {
            // Real mismatch -> Alice slashed to Bob
            assertEq(bob.balance, bobBefore + GARBLER_DEPOSIT + EVALUATOR_DEPOSIT);
            assertEq(alice.balance, aliceBefore);
        }

        assertEq(uint(mp.currentStage()), uint(MillionairesProblem.Stage.Closed));
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

    function _rootFromLeaves(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "empty leaves");

        uint256 width = leaves.length;
        bytes32[] memory level = new bytes32[](width);
        for (uint256 i = 0; i < width; i++) {
            level[i] = leaves[i];
        }

        while (width > 1) {
            uint256 nextWidth = (width + 1) / 2;
            for (uint256 i = 0; i < nextWidth; i++) {
                uint256 leftIndex = 2 * i;
                uint256 rightIndex = leftIndex + 1;
                bytes32 left = level[leftIndex];
                bytes32 right = rightIndex < width ? level[rightIndex] : left;
                level[i] = _commutativeNodeHash(left, right);
            }
            width = nextWidth;
        }

        return level[0];
    }

    function _otLeaves(bytes32 garblerSeed, bytes32 verifierSeed, uint256 instanceId)
        internal
        view
        returns (bytes32[] memory leaves)
    {
        leaves = new bytes32[](uint256(BIT_WIDTH) * 3);
        uint256 cursor = 0;
        for (uint16 inputBit = 0; inputBit < BIT_WIDTH; inputBit++) {
            for (uint8 round = 0; round < 3; round++) {
                uint8 author = round == 1 ? 1 : 0;
                bytes32 payloadHash = mp.computeOtPayloadHash(
                    garblerSeed,
                    verifierSeed,
                    bob,
                    instanceId,
                    inputBit,
                    round
                );
                leaves[cursor] = mp.computeOtLeafHash(inputBit, round, author, payloadHash);
                cursor++;
            }
        }
    }

    function _otPayloadHashes(bytes32 garblerSeed, bytes32 verifierSeed, uint256 instanceId)
        internal
        view
        returns (bytes32[] memory payloads)
    {
        payloads = new bytes32[](uint256(BIT_WIDTH) * 3);
        uint256 cursor = 0;
        for (uint16 inputBit = 0; inputBit < BIT_WIDTH; inputBit++) {
            for (uint8 round = 0; round < 3; round++) {
                payloads[cursor] = mp.computeOtPayloadHash(
                    garblerSeed,
                    verifierSeed,
                    bob,
                    instanceId,
                    inputBit,
                    round
                );
                cursor++;
            }
        }
    }

    function _toDisputeWithRoot(bytes32 seed, bytes32 rootGC0, uint256 mChoice) internal {
        _toDisputeWithRoots(seed, rootGC0, bytes32(0), mChoice);
    }

    function _toDisputeWithRoots(
        bytes32 seed,
        bytes32 rootGC0,
        bytes32 rootOT0,
        uint256 mChoice
    ) internal {
        vm.prank(alice);
        mp.deposit{value: GARBLER_DEPOSIT}();
        vm.prank(bob);
        mp.deposit{value: EVALUATOR_DEPOSIT}();

        vm.prank(bob);
        mp.commitBuyerSeed(_defaultVerifierCommitment());

        // Commitments
        LegacyInstanceCommitment[10] memory commits;
        bytes32 com = keccak256(abi.encodePacked(seed));
        for (uint256 i = 0; i < 10; i++) {
            commits[i] = LegacyInstanceCommitment({
                comSeed: com,
                rootGC: (i == 0) ? rootGC0 : bytes32(0),
                blobHashGC: bytes32(0),
                rootOT: (i == 0) ? rootOT0 : bytes32(0),
                h0: bytes32(0),
                h1: bytes32(0)
            });
        }
        _submitLegacyCommitments(commits);

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
        v.circuitId = _supportedCircuitId(0);
        v.circuitLayoutRoot = hex"d15d9ca7dfc1e2a4c47eb4812eb9d08761688c436aad557449954b91df138521";

        v.mChoice = 7;
        v.challengeInstanceId = 0;
        v.gateIndex = 3;
        v.gateType = 0; // AND
        v.wireA = 7;
        v.wireB = 18;
        v.wireC = 19;
        v.expectMatch = true;

        v.leafBytes = hex"000007001200131d1a343a2b5b83197ecb03153560fd19f4f3b976981661f94e097180d55dd6412753449f071e423ba90fa9370e2cfc6bcb7b3a185c18da218a640d239cdd0380";

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
        v.layoutProof[0] = hex"777d6c12d3c250d868b0e4181c8ed581875e79649b051e958df6bd510360921d";
        v.layoutProof[1] = hex"ce0b488465342067190f5612c5fabd5943df01a0f6bfa3b0b20048b02e6149d5";
        v.layoutProof[2] = hex"b7bc4e1d4ab6d317e3e879ebb52fa7fab2b9c47442f28538214dbcf3f2dced3c";
        v.layoutProof[3] = hex"c2a43fa48469735a6eb4270f570cd839e92a7b48590842fd90c14c8b7203adef";
        v.layoutProof[4] = hex"a260422b0d1747e2e5f05ffa9137638828a94d5657d5bf32edfd4920b431a702";
        v.layoutProof[5] = hex"ad7fe54a89d8432f399df6095828722871f3ef39531b91ab1eb93130b8342436";
        v.layoutProof[6] = hex"3db1f86570b388480271c6b1dae614e90d0960a688fa76cffb922f9979a11cd1";
    }
}
