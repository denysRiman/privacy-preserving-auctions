// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MillionairesProblem {
    address public alice; //Garbler
    address public bob; //Evaluator

    // Number of instances for Cut-and-Choose
    uint256 public constant N = 10;
    InstanceCommitment[N] public instanceCommitments;

    uint256 public m;
    uint256[] public sOpen;

    bytes32[] public garblerLabels;

    struct Deadlines {
        uint256 deposit;          // Phase 1: Alice & Bob must lock funds
        uint256 commit;          // Phase 2: Alice must submit GC
        uint256 choose;         // Phase 3: Bob must pick index m
        uint256 open;          // Phase 4: Alice must reveal n-1 seeds
        uint256 dispute;      // Phase 5: Off-chain verification + Dispute window
        uint256 settle;      // Phase 6 (Final result)
    }

    struct InstanceCommitment {
        bytes32 comSeed;   // H(seedG[i])
        bytes32 rootGC;    // Merkle root over garbled artifacts
        bytes32 rootXG;    // Merkle root over G's input labels
        bytes32 rootOT;    // Merkle root over OT transcript
        bytes32 h0;        // Result anchor for output 0: H(Lout0)
        bytes32 h1;        // Result anchor for output 1: H(Lout1)
    }

    enum Stage { Deposits, Commitments, Choose, Open, Dispute, Settle, Closed }
    Stage public currentStage;

    uint256 public constant DEPOSIT_GARBLER = 1 ether;
    uint256 public constant DEPOSIT_EVALUATOR = 1 ether;

    mapping(address => uint256) public vault;
    Deadlines public deadlines;

    // Mapping to store revealed seeds for verification (index => seed)
    mapping(uint256 => bytes32) public revealedSeeds;

    constructor(address _bob) {
        alice = msg.sender;
        bob = _bob;

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
        require(currentStage == Stage.Dispute, "Wrong stage");
        require(msg.sender == alice, "Only Garbler");
        require(block.timestamp <= deadlines.dispute, "Label reveal deadline missed");

        garblerLabels = _labels;

        currentStage = Stage.Settle;
        deadlines.settle = block.timestamp + 1 hours;
    }

    /**
     * @dev Phase 5 Timeout: If Alice fails to provide her input labels.
     * Bob claims the penalty because he cannot evaluate the circuit.
     */
    function abortPhase5() external {
        require(currentStage == Stage.Dispute, "Not in dispute stage");
        require(block.timestamp > deadlines.dispute, "Alice is not late yet");
        require(msg.sender == bob, "Only Bob can trigger this");

        uint256 total = vault[alice] + vault[bob];
        vault[alice] = 0;
        vault[bob] = 0;

        (bool success, ) = payable(bob).call{value: total}("");
        require(success, "Penalty transfer failed");

        currentStage = Stage.Closed;
    }

    function getSOpenLength() external view returns (uint256) {
        return sOpen.length;
    }
}