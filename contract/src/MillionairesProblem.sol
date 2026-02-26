pragma solidity ^0.8.24;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract MillionairesProblem {
    address public alice; //Garbler
    address public bob; //Evaluator
    bool public result;

    // Number of instances for Cut-and-Choose
    uint256 public constant N = 10;
    InstanceCommitment[N] public instanceCommitments;

    uint256 public m;
    uint256[] public sOpen;

    bytes32 public evaluationTableBlobHash;
    bytes32 public circuitLayoutRoot;

    bytes32[] public garblerLabels;

    struct Deadlines {
        uint256 deposit;          // Phase 1: Alice & Bob must lock funds
        uint256 commit;          // Phase 2: Alice must submit GC
        uint256 choose;         // Phase 3: Bob must pick index m
        uint256 open;          // Phase 4: Alice must reveal n-1 seeds
        uint256 dispute;      // Phase 5: Off-chain verification + Dispute window
        uint256 labels;       // Phase 6: Alice must reveal garbler input labels
        uint256 settle;       // Phase 7: Bob must submit final output label (Final result)
    }

    struct InstanceCommitment {
        bytes32 comSeed;   // H(seedG[i])
        bytes32 rootGC;    // Terminal incremental-hash state over garbling artifacts for disputes
        bytes32 blobHashGC; // EIP-4844 versioned hash for evaluation payload blob (instance i)
        bytes32 rootXG;    // Merkle root over G's input labels
        bytes32 rootOT;    // Merkle root over OT transcript
        bytes32 h0;        // Result anchor for output 0: H(Lout0)
        bytes32 h1;        // Result anchor for output 1: H(Lout1)
    }

    enum Stage { Deposits, Commitments, Choose, Open, Dispute, Labels, Settle, Closed }
    Stage public currentStage;

    uint256 public constant DEPOSIT_GARBLER = 1 ether;
    uint256 public constant DEPOSIT_EVALUATOR = 1 ether;

    mapping(address => uint256) public vault;
    Deadlines public deadlines;

    // Mapping to store revealed seeds for verification (index => seed)
    mapping(uint256 => bytes32) public revealedSeeds;

    constructor(address _bob, bytes32 _circuitId, bytes32 _circuitLayoutRoot) {
        alice = msg.sender;
        bob = _bob;
        circuitId = _circuitId;
        circuitLayoutRoot = _circuitLayoutRoot;

        currentStage = Stage.Deposits;
        deadlines.deposit = block.timestamp + 1 hours;
    }

    function deposit() external payable {
        require(currentStage == Stage.Deposits, "Wrong stage");
        require(block.timestamp <= deadlines.deposit, "Deposit deadline missed");
        require(msg.sender == alice || msg.sender == bob, "Not authorized");
        require(vault[msg.sender] == 0, "Deposit already exists");
        require(msg.value == (msg.sender == alice ?
            DEPOSIT_GARBLER : DEPOSIT_EVALUATOR), "Wrong amount");

        vault[msg.sender] += msg.value;
        if (vault[alice] == DEPOSIT_GARBLER && vault[bob] == DEPOSIT_EVALUATOR) {
            currentStage = Stage.Commitments;
            deadlines.commit = block.timestamp + 1 hours;
        }
    }

    /**
     * @dev Timeout logic for Phase 1.
     * Allows refund if the other party fails to deposit by the deadline.
     */
    function refund() external {
        require(currentStage == Stage.Deposits, "Too late for refund");
        require(block.timestamp > deadlines.deposit, "Deadline not reached");
        require(vault[msg.sender] > 0, "Nothing to refund");

        uint256 amount = vault[msg.sender];
        vault[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }

    /**
     * @dev Phase 2: Garbler submits commitments for all N instances.
     */
    function submitCommitments(InstanceCommitment[N] calldata _commitments) external {
        require(currentStage == Stage.Commitments, "Wrong stage");
        require(msg.sender == alice, "Only Garbler");
        require(block.timestamp <= deadlines.commit, "Commitment deadline missed");

        for (uint256 i = 0; i < N; i++) {
            instanceCommitments[i] = _commitments[i];
        }

        currentStage = Stage.Choose;
        deadlines.choose = block.timestamp + 1 hours;
    }

    /**
     * @dev Phase 2 Timeout: If Alice fails to submit GC by the deadline.
     * Bob can call this to reclaim his funds and Alice's collateral.
     */
    function abortPhase2() external {
        require(currentStage == Stage.Commitments, "Not in commitment stage");
        require(block.timestamp > deadlines.commit, "Alice is not late yet");
        require(msg.sender == bob, "Only Bob can trigger this abort");

        uint256 amountBob = vault[bob];
        uint256 amountAlice = vault[alice];

        vault[bob] = 0;
        vault[alice] = 0;

        uint256 totalPayout = amountBob + amountAlice;

        (bool success, ) = payable(bob).call{value: totalPayout}("");
        require(success, "Refund to Bob failed");
        // Optional: Send a small amount to address(0)

        currentStage = Stage.Closed;
    }

    /**
     * @dev Phase 3: Bob chooses which instance to evaluate.
     */
    function choose(uint256 _m) external {
        require(currentStage == Stage.Choose, "Wrong stage");
        require(msg.sender == bob, "Only Evaluator");
        require(block.timestamp <= deadlines.choose, "Choice deadline missed");
        require(_m < N, "Index out of bounds");

        m = _m;
        for (uint256 i = 0; i < N; i++) {
            if (i != m) { sOpen.push(i); }
        }

        currentStage = Stage.Open;
        deadlines.open = block.timestamp + 1 hours;
    }

    /**
     * @dev Phase 3 Timeout: If Bob fails to choose index m by the deadline.
     * Alice can call this to reclaim her funds and Bob's collateral.
     */
    function abortPhase3() external {
        require(currentStage == Stage.Choose, "Not in choose stage");
        require(block.timestamp > deadlines.choose, "Bob is not late yet");
        require(msg.sender == alice, "Only Alice can trigger this abort");

        uint256 amountAlice = vault[alice];
        uint256 amountBob = vault[bob];

        vault[alice] = 0;
        vault[bob] = 0;
        uint256 totalPayout = amountAlice + amountBob;

        (bool success, ) = payable(alice).call{value: totalPayout}("");
        require(success, "Refund to Alice failed");
        currentStage = Stage.Closed;
    }

    /**
     * @dev Phase 4: Alice reveals seeds for n-1 instances.
     * @param _indices Array of indices being opened (must match sOpen).
     * @param _seeds Array of seeds corresponding to those indices.
     */
    function revealOpenings(uint256[] calldata _indices, bytes32[] calldata _seeds) external {
        require(currentStage == Stage.Open, "Wrong stage");
        require(msg.sender == alice, "Only Garbler");
        require(block.timestamp <= deadlines.open, "Reveal deadline missed");
        require(_indices.length == N - 1, "Must reveal N-1 seeds");

        for (uint256 i = 0; i < _indices.length; i++) {
            uint256 idx = _indices[i];

            require(idx != m, "Cannot reveal evaluation index");

            // Verify the seed matches the commitment from Phase 2
            // H(seed) == instanceCommitments[idx].comSeed
            require(
                keccak256(abi.encodePacked(_seeds[i])) == instanceCommitments[idx].comSeed,
                "Invalid seed reveal"
            );

            revealedSeeds[idx] = _seeds[i];
        }

        currentStage = Stage.Dispute;
        deadlines.dispute = block.timestamp + 1 hours;
        deadlines.labels  = deadlines.dispute + 1 hours;
    }

    /**
     * @dev Phase 4 Timeout: If Alice fails to reveal seeds by the deadline.
     * Bob can claim the penalty.
     */
    function abortPhase4() external {
        require(currentStage == Stage.Open, "Not in open stage");
        require(block.timestamp > deadlines.open, "Alice is not late yet");
        require(msg.sender == bob, "Only Bob can trigger this");

        uint256 amountAlice = vault[alice];
        uint256 amountBob = vault[bob];

        vault[alice] = 0;
        vault[bob] = 0;

        // Bob gets everything as compensation
        (bool success, ) = payable(bob).call{value: amountAlice + amountBob}("");
        require(success, "Penalty transfer failed");

        currentStage = Stage.Closed;
    }

    /**
     * @dev Phase 5: Alice reveals her input labels for the evaluation circuit m.
     * These labels correspond to her private input x.
     * @param _labels The set of wire labels for Alice's input.
     */
    function revealGarblerLabels(bytes32[] calldata _labels) external {
        require(currentStage == Stage.Labels, "Wrong stage");
        require(msg.sender == alice, "Only Garbler");
        require(block.timestamp <= deadlines.labels, "Label reveal deadline missed");

        bytes32 bHash = blobhash(0);

        // test network only
        if (block.chainid != 31337) {
            require(bHash != bytes32(0), "Garbled Table Blob missing");
            require(bHash == instanceCommitments[m].blobHashGC, "Blob does not match Phase 2 commitment");
        } else {
            bHash = instanceCommitments[m].blobHashGC;
        }

        evaluationTableBlobHash = bHash;
        garblerLabels = _labels;

        currentStage = Stage.Settle;
        deadlines.settle = block.timestamp + 1 hours;
    }

    /**
     * @dev Phase 5 Timeout: If Alice fails to provide her input labels.
     * Bob claims the penalty because he cannot evaluate the circuit.
     */
    function abortPhase5() external {
        require(currentStage == Stage.Labels, "Not in labels stage");
        require(block.timestamp > deadlines.labels, "Alice is not late yet");
        require(msg.sender == bob, "Only Bob can trigger this");

        uint256 total = vault[alice] + vault[bob];
        vault[alice] = 0;
        vault[bob] = 0;

        (bool success, ) = payable(bob).call{value: total}("");
        require(success, "Penalty transfer failed");

        currentStage = Stage.Closed;
    }

/**
     * @dev Phase 5 (Dispute): Bob challenges one gate from one opened check-circuit.
     * Delegates to `challengeGateLeaf` after explicit seed checks.
     * @param _idx Index of the opened circuit to challenge (must be in sOpen).
     * @param _seed Revealed seed for `_idx`, must match commitment.
     * @param gateIndex Gate index in circuit layout.
     * @param g Gate descriptor (type + wires) for `gateIndex`.
     * @param leafBytes Claimed gate leaf bytes.
     * @param ihProof Incremental-hash proof path for the challenged gate block.
     * @param layoutProof Proof that `(gateIndex, g)` is in `circuitLayoutRoot`.
     */
    function disputeGarbledTable(uint256 _idx, bytes32 _seed, uint256 gateIndex, GateDesc calldata g, bytes calldata leafBytes,
        bytes32[] calldata ihProof, bytes32[] calldata layoutProof) external {
        require(currentStage == Stage.Dispute, "Not in Dispute stage");
        require(msg.sender == bob, "Only Evaluator can dispute");
        require(_idx != m, "Cannot dispute evaluation circuit m");
        require(keccak256(abi.encodePacked(_seed)) == instanceCommitments[_idx].comSeed, "Invalid seed");
        require(revealedSeeds[_idx] == _seed, "Seed mismatch");

        challengeGateLeaf(_idx, gateIndex, g, leafBytes, ihProof, layoutProof);
    }




    /**
     * @dev Phase 6: Bob (Evaluator) submits the final output label.
     * The contract verifies it against Alice's anchors (h0, h1).
     * @param _outputLabel The label resulting from Ev(F, X).
     */
    function settle(bytes32 _outputLabel) external {
        require(currentStage == Stage.Settle, "Wrong stage");
        require(msg.sender == bob, "Only Evaluator");
        require(block.timestamp <= deadlines.settle, "Settlement deadline missed");

        InstanceCommitment storage evalInstance = instanceCommitments[m];

        // Verify if the label matches H(Lout0) or H(Lout1)
        if (keccak256(abi.encodePacked(_outputLabel)) == evalInstance.h0) {
            result = true;
        } else if (keccak256(abi.encodePacked(_outputLabel)) == evalInstance.h1) {
            result = false;
        } else {
            revert("Invalid output label");
        }

        uint256 payoutAlice = vault[alice];
        uint256 payoutBob = vault[bob];
        vault[alice] = 0;
        vault[bob] = 0;
        (bool s1, ) = payable(alice).call{value: payoutAlice}("");
        require(s1, "Payout to Alice failed");
        (bool s2, ) = payable(bob).call{value: payoutBob}("");
        require(s2, "Payout to Bob failed");

        currentStage = Stage.Closed;
    }

    /**
     * @dev Phase 6 Timeout: If Bob fails to settle the result.
     * Alice can claim the funds after the deadline.
     */
    function abortPhase6() external {
        require(currentStage == Stage.Settle, "Not in settle stage");
        require(block.timestamp > deadlines.settle, "Bob is not late yet");
        require(msg.sender == alice, "Only Alice can trigger this");

        uint256 total = vault[alice] + vault[bob];
        vault[alice] = 0;
        vault[bob] = 0;

        (bool success, ) = payable(alice).call{value: total}("");
        require(success, "Refund to Alice failed");

        currentStage = Stage.Closed;
    }

    function getSOpenLength() external view returns (uint256) {
        return sOpen.length;
    }

    /**
     * @dev Private helper to transfer all funds to the winner and close the contract.
     */
    function _slash(address _winner, address _loser) private {
        uint256 prize = vault[_winner] + vault[_loser];
        vault[_winner] = 0;
        vault[_loser] = 0;

        (bool success, ) = payable(_winner).call{value: prize}("");
        require(success, "Slashed transfer failed");

        currentStage = Stage.Closed;
    }

    function closeDispute() external {
        require(currentStage == Stage.Dispute, "Wrong stage");

        // Bob can close anytime (early close)
        if (msg.sender == bob) {
            currentStage = Stage.Labels;
            return;
        }

        require(msg.sender == alice, "Only Alice can close after deadline");
        require(block.timestamp > deadlines.dispute, "Dispute window still open");
        currentStage = Stage.Labels;
    }

    // ------ GC part ------
    //  Spec primitives

    // setting primitives
    uint256 private constant LABEL_BYTES = 16;
    bytes32 public circuitId;

    function computeWireFlipBit(bytes32 seed, uint256 instanceId, uint16 wireId) internal view returns (uint8) {
        // Returns 0/1. Used to define point and permute bits for this wire.
        bytes32 h = keccak256(abi.encodePacked("P", circuitId, instanceId, wireId, seed));
        return uint8(h[31]) & 1;
    }

    function setFirstByteLsb(bytes16 value, uint8 bit) internal pure returns (bytes16) {
        // Sets the LSB of the first byte to bit (0/1).
        bytes memory tmp = abi.encodePacked(value);
        tmp[0] = bytes1((uint8(tmp[0]) & 0xFE) | (bit & 1));

        bytes16 out;
        assembly {
            out := mload(add(tmp, 32))
        }
        return out;
    }

    function deriveWireLabel(bytes32 seed, uint256 instanceId, uint16 wireId, uint8 semanticBit)
    internal view returns (bytes16) {
        // Deterministically derives label(wireId, semanticBit) from seed.
        bytes32 h = keccak256(abi.encodePacked("L", circuitId, instanceId, wireId, semanticBit, seed));
        bytes16 label = bytes16(h);

        // Point-and-permute bit: p = flipBit XOR semanticBit
        uint8 flipBit = computeWireFlipBit(seed, instanceId, wireId);
        uint8 permuteBit = flipBit ^ (semanticBit & 1);

        return setFirstByteLsb(label, permuteBit);
    }

    function getPermutationBit(bytes16 label) internal pure returns (uint8) {
        // Reads the point-and-permute bit (LSB of first byte).
        return uint8(label[0]) & 1;
    }

    function xorLabel(bytes16 a, bytes16 b) internal pure returns (bytes16) {
        // XOR for 16-byte labels/pads.
        return bytes16(uint128(a) ^ uint128(b));
    }

    function expandPad(bytes32 rowKey) internal pure returns (bytes16) {
        // Expands a 32-byte key into a 16-byte pad.
        return bytes16(keccak256(abi.encodePacked("PAD", rowKey)));
    }

    function computeRowKey(bytes16 labelA, bytes16 labelB, uint256 instanceId,
        uint256 gateIndex, uint8 permA, uint8 permB) internal view returns (bytes32) {
        // Row key bound to circuitId, instance, gate, row selector bits, and input labels.
        return keccak256(abi.encodePacked("K", circuitId, instanceId, gateIndex, permA, permB, labelA, labelB));
    }

    // Gate description + per-gate leaf recomputation

    enum GateType { AND, XOR, NOT }

    struct GateDesc {
        GateType gateType;
        uint16 wireA;
        uint16 wireB; // for NOT can be 0
        uint16 wireC;
    }

    function recomputeGateLeafBytes(bytes32 seed, uint256 instanceId, uint256 gateIndex, GateDesc memory g) internal view returns (bytes memory leafBytes) {
        // Leaf encoding:
        // gateType (1 byte) || wireA (2) || wireB (2) || wireC (2) || row0(16) || row1(16) || row2(16) || row3(16)

        bytes16 row0;
        bytes16 row1;
        bytes16 row2;
        bytes16 row3;

        if (g.gateType == GateType.NOT) {
            // Canonical: NOT has no garbled table (rows = 0). Semantics handled by circuit layout.
            // Keep rows zeroed.
        } else {
            // Wire flip bits (point-and-permute seeds)
            uint8 flipA = computeWireFlipBit(seed, instanceId, g.wireA);
            uint8 flipB = computeWireFlipBit(seed, instanceId, g.wireB);

            // Iterate over permutation-bit pairs (permA, permB) in {0,1}x{0,1}
            for (uint8 permA = 0; permA <= 1; permA++) {
                for (uint8 permB = 0; permB <= 1; permB++) {
                    // Map permutation bits back to semantic bits:
                    // permBit = flipBit XOR semanticBit  => semanticBit = permBit XOR flipBit
                    uint8 bitA = permA ^ flipA;
                    uint8 bitB = permB ^ flipB;

                    uint8 outBit;
                    if (g.gateType == GateType.AND) {
                        outBit = bitA & bitB;
                    } else {
                        // XOR
                        outBit = bitA ^ bitB;
                    }

                    // Input wire labels for this semantic choice
                    bytes16 labelA = deriveWireLabel(seed, instanceId, g.wireA, bitA);
                    bytes16 labelB = deriveWireLabel(seed, instanceId, g.wireB, bitB);

                    // Output wire label
                    bytes16 outLabel = deriveWireLabel(seed, instanceId, g.wireC, outBit);

                    // Row encryption: ct = outLabel XOR pad(rowKey(...))
                    bytes32 rowKey = computeRowKey(labelA, labelB, instanceId, gateIndex, permA, permB);
                    bytes16 pad = expandPad(rowKey);
                    bytes16 ct = xorLabel(outLabel, pad);

                    uint8 rowIndex = uint8(2 * permA + permB);
                    if (rowIndex == 0) row0 = ct;
                    else if (rowIndex == 1) row1 = ct;
                    else if (rowIndex == 2) row2 = ct;
                    else row3 = ct;
                }
            }
        }

        leafBytes = abi.encodePacked(
            uint8(g.gateType),
            g.wireA,
            g.wireB,
            g.wireC,
            row0,
            row1,
            row2,
            row3
        );
    }

    // ===== Step 3: Merkle proof + dispute =====


        /**
     * @dev Leaf encoding length for abi.encodePacked:
     * - gateType (uint8):  1 byte
     * - wireA    (uint16): 2 bytes
     * - wireB    (uint16): 2 bytes
     * - wireC    (uint16): 2 bytes
     * - row0-3 (bytes16): 64 bytes (4 * 16)
     * Total: 71 bytes
     */
    uint256 private constant LEAF_BYTES_LEN = 71;

    event GateLeafChallenged(uint256 indexed instanceId, uint256 indexed gateIndex, bool mismatch);
    event CheaterSlashed(address indexed cheater, address indexed beneficiary);

    function _isOpenInstance(uint256 instanceId) internal view returns (bool) {
        if (instanceId == m) return false;

        for (uint256 i = 0; i < sOpen.length; i++) {
            if (sOpen[i] == instanceId) return true;
        }
        return false;
    }

    function _assertValidLayoutProof(
        uint256 gateIndex,
        GateDesc calldata g,
        bytes32[] calldata layoutProof
    ) internal view {
        bytes32 layoutLeaf = _layoutLeafHash(gateIndex, g);
        require(
            MerkleProof.verify(layoutProof, circuitLayoutRoot, layoutLeaf),
            "Bad circuit layout proof"
        );
    }

    function _requireRevealedSeedForOpenedInstance(uint256 instanceId) internal view returns (bytes32 seed) {
        require(_isOpenInstance(instanceId), "Not an opened instance");
        seed = revealedSeeds[instanceId];
        require(seed != bytes32(0), "Seed not revealed");
    }

    function _gateLeafHash(uint256 gateIndex, bytes memory leafBytes) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(gateIndex, leafBytes));
    }

    /**
     * Dispute a single gate leaf for an opened instance.
     *
     * Inputs:
     * - instanceId: must be in S_open (i != m)
     * - gateIndex: index in circuit layout (off-chain agreed)
     * - g: gate description (type + wires)
     * - leafBytes: committed gate leaf bytes (gate header + 4 rows)
     * - ihProof: incremental-hash proof path for the challenged gate block
     *
     * Outcome:
     * - If mismatch => Alice cheated => slash Alice to Bob
     * - If match    => false challenge => slash Bob to Alice (optional but recommended)
     */
    function challengeGateLeaf(uint256 instanceId, uint256 gateIndex, GateDesc calldata g, bytes calldata leafBytes,
        bytes32[] calldata ihProof, bytes32[] calldata layoutProof) public {
        require(currentStage == Stage.Dispute, "Wrong stage");
        require(block.timestamp <= deadlines.dispute, "Dispute deadline missed");
        require(msg.sender == bob, "Only Bob for MVP");

        _assertValidLayoutProof(gateIndex, g, layoutProof);
        bytes32 seed = _requireRevealedSeedForOpenedInstance(instanceId);

        require(leafBytes.length == LEAF_BYTES_LEN, "Bad leaf length");

        // 1) Verify index-bound leaf inclusion via section-5.2-style incremental hashing.
        bytes32 leafHash = _gateLeafHash(gateIndex, leafBytes);
        bytes32 root = instanceCommitments[instanceId].rootGC;
        require(_processIncrementalProof(leafHash, ihProof) == root, "Bad IH proof");

        // 2) Recompute expected leaf from seed here
        bytes memory expected = recomputeGateLeafBytes(seed, instanceId, gateIndex, g);
        bool matchLeaf = (_gateLeafHash(gateIndex, expected) == leafHash);

        // 3) Slash depending on result
        if (!matchLeaf) {
            emit GateLeafChallenged(instanceId, gateIndex, true);
            emit CheaterSlashed(alice, bob);
            _slash(bob, alice);
        } else {
            emit GateLeafChallenged(instanceId, gateIndex, false);
            emit CheaterSlashed(bob, alice);
            _slash(alice, bob);
        }
    }

    // leaf = H(gateIndex || gateType || wireA || wireB || wireC)
    function _layoutLeafHash(uint256 gateIndex, GateDesc calldata g) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(gateIndex, uint8(g.gateType), g.wireA, g.wireB, g.wireC));
    }

    // Proof format:
    // - ihProof[0] (optional): IH_{i-1} prefix state before challenged gate i.
    // - ihProof[1..]: ordered suffix block hashes after challenged gate i.
    // - empty proof means single-block chain rooted at H(0x00..00 || leafHash).
    function _processIncrementalProof(bytes32 leafHash, bytes32[] calldata ihProof) internal pure returns (bytes32) {
        bytes32 state;
        uint256 i;

        if (ihProof.length == 0) {
            state = keccak256(abi.encodePacked(bytes32(0), leafHash));
            return state;
        }

        state = keccak256(abi.encodePacked(ihProof[0], leafHash));
        for (i = 1; i < ihProof.length; i++) {
            state = keccak256(abi.encodePacked(state, ihProof[i]));
        }
        return state;
    }
    // ------ gc part end ------
}
