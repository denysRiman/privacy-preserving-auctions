pragma solidity ^0.8.24;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

interface IEnsAuctionAdapter {
    function assign(bytes32 namehash, address to) external;
}

contract MillionairesProblem {
    address public alice; //Garbler
    uint16 public winnerId;
    uint64 public winningBid;
    address public winnerBuyer;
    address public winnerReceiver;
    bytes32 public ensNamehash;
    address public ensAdapter;
    bool public assigned;

    // Number of instances for Cut-and-Choose
    uint256 public constant N = 10;
    InstanceCommitment[N] public instanceCommitments;

    uint256 public m;
    uint256[] public sOpen;

    bytes32 public circuitLayoutRoot;

    bytes32[] public garblerLabels;

    struct Deadlines {
        uint256 deposit;          // Phase 1: Alice + buyers must lock funds
        uint256 verifierSeed;    // Phase 2: buyer seed commit/reveal windows
        uint256 commit;          // Phase 3: Alice submit core commitments, then OT roots
        uint256 buyerInputOt;    // Phase 4: Buyers finalize input/OT state or get defaulted
        uint256 open;            // Phase 5: Alice must reveal n-1 seeds
        uint256 dispute;         // Phase 6: Off-chain verification + Dispute window
        uint256 labels;          // Phase 7: Alice must reveal garbler input labels
        uint256 settle;          // Phase 8: participant submits final output label
    }

    struct InstanceCommitment {
        bytes32 comSeed;   // H(seedG[i])
        bytes32 rootGC;    // Terminal incremental-hash state over garbling artifacts for disputes
        bytes32 blobHashGC; // EIP-4844 versioned hash for evaluation payload blob (instance i)
        bytes32 hOut;      // H("OUT", circuitId, instanceId, outputBytes)
    }

    struct CoreInstanceCommitment {
        bytes32 comSeed;
        bytes32 rootGC;
        bytes32 blobHashGC;
        bytes32 hOut;
    }

    enum Stage {
        Deposits,
        BuyerSeedCommit,
        CommitmentsCore,
        BuyerSeedReveal,
        CommitmentsOT,
        BuyerInputOT,
        Open,
        Dispute,
        Labels,
        Settle,
        Assignment,
        Closed
    }

    enum BuyerStatus {
        Pending,
        Ready,
        Defaulted
    }
    Stage public currentStage;

    uint256 public constant DEPOSIT_GARBLER = 1.2 ether;
    uint256 public constant DEPOSIT_EVALUATOR = 1.2 ether;
    uint8 private constant OT_ROUNDS_PER_INPUT = 3;
    uint8 private constant OT_DUMMY_CHOICE = 0;

    mapping(address => uint256) public vault;
    Deadlines public deadlines;

    // Mapping to store revealed seeds for verification (index => seed)
    mapping(uint256 => bytes32) public revealedSeeds;
    bytes32 public verifierSeed;
    bool public verifierSeedFinalized;
    uint16 public bitWidth;
    address[] private buyers;
    mapping(address => bool) public isBuyer;
    mapping(address => address) public buyerReceiver;
    mapping(address => bytes32) public buyerSeedCommitment;
    mapping(address => bytes32) public buyerSeed;
    mapping(address => bool) public buyerSeedRevealed;
    uint256 public pendingSeedCommits;
    uint256 public pendingSeedReveals;
    mapping(address => BuyerStatus) public buyerStatus;
    mapping(address => mapping(uint256 => bytes32)) public buyerRootOTCommitment;
    mapping(address => bool) public buyerOtRootsSubmitted;
    uint256 public pendingBuyerOtRoots;
    uint256 public unresolvedBuyers;
    mapping(address => bool) public disputeClosedByBuyer;
    uint256 public pendingDisputeBuyerClosures;
    uint16 private constant OUTPUT_WINNER_ID_BYTES = 2;
    uint16 private constant OUTPUT_WINNING_BID_BYTES = 8;
    uint16 private constant OUTPUT_TOTAL_BYTES = OUTPUT_WINNER_ID_BYTES + OUTPUT_WINNING_BID_BYTES;

    event WinnerResolved(uint16 indexed winnerId, address indexed buyer, address indexed receiver, uint64 winningBid);
    event EnsAssigned(bytes32 indexed namehash, address indexed receiver);

    constructor(
        address _initialBuyer,
        address _initialReceiver,
        bytes32 _ensNamehash,
        address _ensAdapter,
        bytes32 _circuitId,
        bytes32 _circuitLayoutRoot,
        uint16 _bitWidth
    ) {
        require(_bitWidth > 0, "bitWidth must be > 0");
        require(_bitWidth <= 60, "bitWidth must be <= 60");
        require(_initialBuyer != address(0), "Zero buyer");
        require(_initialReceiver != address(0), "Zero receiver");
        require(_ensNamehash != bytes32(0), "Zero ENS namehash");
        require(_ensAdapter != address(0), "Zero ENS adapter");
        alice = msg.sender;
        ensNamehash = _ensNamehash;
        ensAdapter = _ensAdapter;
        circuitId = _circuitId;
        circuitLayoutRoot = _circuitLayoutRoot;
        bitWidth = _bitWidth;
        buyers.push(_initialBuyer);
        isBuyer[_initialBuyer] = true;
        buyerReceiver[_initialBuyer] = _initialReceiver;

        currentStage = Stage.Deposits;
        deadlines.deposit = block.timestamp + 1 hours;
    }

    /**
     * @dev Registers additional buyers before deposits begin.
     * Extends buyer set B1..Bn.
     */
    function registerBuyers(address[] calldata additionalBuyers, address[] calldata additionalReceivers) external {
        require(currentStage == Stage.Deposits, "Wrong stage");
        require(msg.sender == alice, "Only Alice");
        require(vault[alice] == 0, "Deposits already started");
        require(additionalBuyers.length == additionalReceivers.length, "Length mismatch");

        for (uint256 i = 0; i < additionalBuyers.length; i++) {
            address buyerAddr = additionalBuyers[i];
            address receiverAddr = additionalReceivers[i];
            require(buyerAddr != address(0), "Zero buyer");
            require(receiverAddr != address(0), "Zero receiver");
            require(buyerAddr != alice, "Alice cannot be buyer");
            require(!isBuyer[buyerAddr], "Buyer already registered");

            buyers.push(buyerAddr);
            isBuyer[buyerAddr] = true;
            buyerReceiver[buyerAddr] = receiverAddr;
        }
    }

    function buyerCount() external view returns (uint256) {
        return buyers.length;
    }

    function buyerAt(uint256 index) external view returns (address) {
        require(index < buyers.length, "Buyer index out of bounds");
        return buyers[index];
    }

    function _allBuyerDepositsPresent() internal view returns (bool) {
        for (uint256 i = 0; i < buyers.length; i++) {
            if (vault[buyers[i]] != DEPOSIT_EVALUATOR) {
                return false;
            }
        }
        return true;
    }

    function deposit() external payable {
        require(currentStage == Stage.Deposits, "Wrong stage");
        require(block.timestamp <= deadlines.deposit, "Deposit deadline missed");
        require(msg.sender == alice || isBuyer[msg.sender], "Not authorized");
        require(vault[msg.sender] == 0, "Deposit already exists");
        require(msg.value == (msg.sender == alice ?
            DEPOSIT_GARBLER : DEPOSIT_EVALUATOR), "Wrong amount");

        vault[msg.sender] += msg.value;
        if (vault[alice] == DEPOSIT_GARBLER && _allBuyerDepositsPresent()) {
            currentStage = Stage.BuyerSeedCommit;
            pendingSeedCommits = buyers.length;
            pendingSeedReveals = 0;
            deadlines.verifierSeed = block.timestamp + 1 hours;
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

    function _isParticipant(address actor) internal view returns (bool) {
        return actor == alice || isBuyer[actor];
    }

    function _enterBuyerSeedRevealStage() internal {
        currentStage = Stage.BuyerSeedReveal;
        deadlines.verifierSeed = block.timestamp + 1 hours;
        pendingSeedReveals = 0;

        for (uint256 i = 0; i < buyers.length; i++) {
            address buyerAddr = buyers[i];
            if (buyerSeedCommitment[buyerAddr] != bytes32(0)) {
                if (!buyerSeedRevealed[buyerAddr]) {
                    pendingSeedReveals += 1;
                }
            } else {
                buyerSeed[buyerAddr] = bytes32(0);
                buyerSeedRevealed[buyerAddr] = true;
            }
        }

        if (pendingSeedReveals == 0) {
            _finalizeBuyerSeedAndEnterCommitments();
        }
    }

    function _finalizeBuyerSeedAndEnterCommitments() internal {
        bytes32 aggregate = bytes32(0);
        for (uint256 i = 0; i < buyers.length; i++) {
            aggregate = bytes32(uint256(aggregate) ^ uint256(buyerSeed[buyers[i]]));
        }
        verifierSeed = aggregate;
        verifierSeedFinalized = true;
        m = uint256(keccak256(abi.encodePacked("M", verifierSeed, circuitId, address(this)))) % N;

        for (uint256 i = 0; i < sOpen.length; i++) {
            delete revealedSeeds[sOpen[i]];
        }
        delete sOpen;
        for (uint256 i = 0; i < N; i++) {
            if (i != m) {
                sOpen.push(i);
            }
        }

        currentStage = Stage.CommitmentsCore;
        deadlines.commit = block.timestamp + 1 hours;
    }

    /**
     * @dev Phase 2a: buyer commits seed-hash.
     */
    function commitBuyerSeed(bytes32 commitment) public {
        require(currentStage == Stage.BuyerSeedCommit, "Wrong stage");
        require(block.timestamp <= deadlines.verifierSeed, "Seed-commit deadline missed");
        require(isBuyer[msg.sender], "Only buyer");
        require(commitment != bytes32(0), "Empty buyer seed commitment");
        require(buyerSeedCommitment[msg.sender] == bytes32(0), "Buyer seed already committed");

        buyerSeedCommitment[msg.sender] = commitment;
        pendingSeedCommits -= 1;
        if (pendingSeedCommits == 0) {
            _enterBuyerSeedRevealStage();
        }
    }

    /**
     * @dev Phase 2a liveness: after deadline, anyone can finalize seed-commit stage.
     * Non-committed buyers are defaulted to seed=0 and slashed.
     */
    function finalizeBuyerSeedCommitAfterDeadline() public {
        require(currentStage == Stage.BuyerSeedCommit, "Wrong stage");
        require(block.timestamp > deadlines.verifierSeed, "Seed-commit phase still active");
        require(_isParticipant(msg.sender), "Only participant");

        for (uint256 i = 0; i < buyers.length; i++) {
            address buyerAddr = buyers[i];
            if (buyerSeedCommitment[buyerAddr] == bytes32(0)) {
                uint256 slashed = vault[buyerAddr];
                vault[buyerAddr] = 0;
                vault[alice] += slashed;
                buyerSeed[buyerAddr] = bytes32(0);
                buyerSeedRevealed[buyerAddr] = true;
            }
        }

        pendingSeedCommits = 0;
        _enterBuyerSeedRevealStage();
    }

    /**
     * @dev Phase 2b: buyer reveals seed and salt against prior commitment.
     */
    function revealBuyerSeed(bytes32 seed, bytes32 salt) public {
        require(currentStage == Stage.BuyerSeedReveal, "Wrong stage");
        require(block.timestamp <= deadlines.verifierSeed, "Seed-reveal deadline missed");
        require(isBuyer[msg.sender], "Only buyer");
        require(buyerSeedCommitment[msg.sender] != bytes32(0), "Buyer seed not committed");
        require(!buyerSeedRevealed[msg.sender], "Buyer seed already revealed");
        require(
            keccak256(abi.encodePacked(seed, salt)) == buyerSeedCommitment[msg.sender],
            "Invalid buyer seed reveal"
        );

        buyerSeed[msg.sender] = seed;
        buyerSeedRevealed[msg.sender] = true;
        pendingSeedReveals -= 1;
        if (pendingSeedReveals == 0) {
            _finalizeBuyerSeedAndEnterCommitments();
        }
    }

    /**
     * @dev Phase 2b liveness: after deadline, anyone can finalize seed-reveal stage.
     * Non-revealed committed buyers are defaulted to seed=0 and slashed.
     */
    function finalizeBuyerSeedRevealAfterDeadline() public {
        require(currentStage == Stage.BuyerSeedReveal, "Wrong stage");
        require(block.timestamp > deadlines.verifierSeed, "Seed-reveal phase still active");
        require(_isParticipant(msg.sender), "Only participant");

        for (uint256 i = 0; i < buyers.length; i++) {
            address buyerAddr = buyers[i];
            if (buyerSeedCommitment[buyerAddr] != bytes32(0) && !buyerSeedRevealed[buyerAddr]) {
                uint256 slashed = vault[buyerAddr];
                vault[buyerAddr] = 0;
                vault[alice] += slashed;
                buyerSeed[buyerAddr] = bytes32(0);
                buyerSeedRevealed[buyerAddr] = true;
            }
        }

        pendingSeedReveals = 0;
        _finalizeBuyerSeedAndEnterCommitments();
    }

    /**
     * @dev Phase 3a: Garbler submits core commitments for all N instances (without OT roots).
     */
    function submitCommitments(CoreInstanceCommitment[N] calldata commitments) external {
        require(currentStage == Stage.CommitmentsCore, "Wrong stage");
        require(msg.sender == alice, "Only Garbler");
        require(block.timestamp <= deadlines.commit, "Commitment deadline missed");
        require(verifierSeedFinalized, "Verifier seed not finalized");

        for (uint256 i = 0; i < N; i++) {
            require(commitments[i].comSeed != bytes32(0), "Empty comSeed");
            require(commitments[i].rootGC != bytes32(0), "Empty rootGC");
            require(commitments[i].blobHashGC != bytes32(0), "Empty blobHashGC");
            require(commitments[i].hOut != bytes32(0), "Empty hOut");

            instanceCommitments[i].comSeed = commitments[i].comSeed;
            instanceCommitments[i].rootGC = commitments[i].rootGC;
            instanceCommitments[i].blobHashGC = commitments[i].blobHashGC;
            instanceCommitments[i].hOut = commitments[i].hOut;
        }

        currentStage = Stage.CommitmentsOT;
        deadlines.commit = block.timestamp + 1 hours;
        pendingBuyerOtRoots = buyers.length;
        for (uint256 i = 0; i < buyers.length; i++) {
            buyerOtRootsSubmitted[buyers[i]] = false;
        }
    }

    /**
     * @dev Phase 3b: Alice (garbler) commits buyer-scoped OT roots for all N instances.
     * OT disputes verify this Alice commitment by recomputing expected buyer-bound roots.
     */
    function submitOtRootsForBuyer(address buyerAddr, bytes32[N] calldata rootOTs) public {
        require(currentStage == Stage.CommitmentsOT, "Wrong stage");
        require(msg.sender == alice, "Only Garbler");
        require(block.timestamp <= deadlines.commit, "OT root deadline missed");
        require(verifierSeedFinalized, "Verifier seed not finalized");
        require(isBuyer[buyerAddr], "Not buyer");
        require(!buyerOtRootsSubmitted[buyerAddr], "Buyer OT roots already submitted");

        for (uint256 i = 0; i < N; i++) {
            require(rootOTs[i] != bytes32(0), "Empty rootOT");
            buyerRootOTCommitment[buyerAddr][i] = rootOTs[i];
        }

        buyerOtRootsSubmitted[buyerAddr] = true;
        pendingBuyerOtRoots -= 1;

        if (pendingBuyerOtRoots == 0) {
            unresolvedBuyers = buyers.length;
            for (uint256 i = 0; i < buyers.length; i++) {
                address b = buyers[i];
                buyerStatus[b] = BuyerStatus.Pending;
            }

            currentStage = Stage.BuyerInputOT;
            deadlines.buyerInputOt = block.timestamp + 1 hours;
            _tryAdvanceFromBuyerInputPhase();
        }
    }

    /**
     * @dev Buyer-level liveness signal: buyer confirms readiness before deadline.
     */
    function submitBuyerReady() external {
        require(currentStage == Stage.BuyerInputOT, "Wrong stage");
        require(block.timestamp <= deadlines.buyerInputOt, "Buyer input deadline missed");
        require(isBuyer[msg.sender], "Only buyer");
        require(buyerStatus[msg.sender] == BuyerStatus.Pending, "Buyer already resolved");

        buyerStatus[msg.sender] = BuyerStatus.Ready;
        unresolvedBuyers -= 1;
        _tryAdvanceFromBuyerInputPhase();
    }

    function _defaultBuyerInput(address buyerAddr) internal {
        buyerStatus[buyerAddr] = BuyerStatus.Defaulted;
        unresolvedBuyers -= 1;

        uint256 slashed = vault[buyerAddr];
        vault[buyerAddr] = 0;
        vault[alice] += slashed;
    }

    function defaultBuyerInput(address buyerAddr) external {
        require(currentStage == Stage.BuyerInputOT, "Wrong stage");
        require(block.timestamp > deadlines.buyerInputOt, "Buyer input phase still active");
        require(isBuyer[buyerAddr], "Not buyer");
        require(buyerStatus[buyerAddr] == BuyerStatus.Pending, "Buyer already resolved");
        _defaultBuyerInput(buyerAddr);

        _tryAdvanceFromBuyerInputPhase();
    }

    function finalizeBuyerInputAfterDeadline() external {
        require(currentStage == Stage.BuyerInputOT, "Wrong stage");
        require(block.timestamp > deadlines.buyerInputOt, "Buyer input phase still active");

        for (uint256 i = 0; i < buyers.length; i++) {
            address buyerAddr = buyers[i];
            if (buyerStatus[buyerAddr] == BuyerStatus.Pending) {
                _defaultBuyerInput(buyerAddr);
            }
        }

        _tryAdvanceFromBuyerInputPhase();
    }

    function _tryAdvanceFromBuyerInputPhase() internal {
        if (currentStage != Stage.BuyerInputOT) {
            return;
        }
        if (unresolvedBuyers != 0) {
            return;
        }

        currentStage = Stage.Open;
        deadlines.open = block.timestamp + 1 hours;
    }

    /**
     * @dev Phase 3 Timeout: If Alice misses deadlines.commit in CommitmentsCore or CommitmentsOT.
     * This also covers missing per-buyer OT roots in CommitmentsOT.
     * Any deposited buyer can abort and reclaim own deposit plus Alice collateral.
     */
    function abortPhase2() external {
        require(
            currentStage == Stage.CommitmentsCore || currentStage == Stage.CommitmentsOT,
            "Not in commitment stage"
        );
        require(block.timestamp > deadlines.commit, "Alice is not late yet");
        require(isBuyer[msg.sender], "Only buyer can trigger this abort");

        uint256 amountBuyer = vault[msg.sender];
        uint256 amountAlice = vault[alice];

        vault[msg.sender] = 0;
        vault[alice] = 0;

        _refundPassiveBuyers(msg.sender, msg.sender);
        uint256 totalPayout = amountBuyer + amountAlice;

        (bool success, ) = payable(msg.sender).call{value: totalPayout}("");
        require(success, "Refund to buyer failed");
        // Optional: Send a small amount to address(0)

        currentStage = Stage.Closed;
    }

    /**
     * @dev Phase 5: Alice reveals seeds for n-1 instances.
     * @param _indices Array of indices being opened (must match sOpen).
     * @param _seeds Array of seeds corresponding to those indices.
     */
    function revealOpenings(uint256[] calldata _indices, bytes32[] calldata _seeds) external {
        require(currentStage == Stage.Open, "Wrong stage");
        require(msg.sender == alice, "Only Garbler");
        require(block.timestamp <= deadlines.open, "Reveal deadline missed");
        require(_indices.length == N - 1, "Must reveal N-1 seeds");
        require(_seeds.length == N - 1, "Must provide N-1 seeds");
        require(_indices.length == _seeds.length, "Length mismatch");

        bool[] memory seen = new bool[](N);

        for (uint256 i = 0; i < _indices.length; i++) {
            uint256 idx = _indices[i];
            require(idx < N, "Index out of bounds");
            require(!seen[idx], "Duplicate index");
            seen[idx] = true;

            bool inSOpen = false;
            for (uint256 j = 0; j < sOpen.length; j++) {
                if (sOpen[j] == idx) {
                    inSOpen = true;
                    break;
                }
            }
            require(inSOpen, "Index not in sOpen");

            // Verify the seed matches the commitment from Phase 2
            // H(seed) == instanceCommitments[idx].comSeed
            require(
                keccak256(abi.encodePacked(_seeds[i])) == instanceCommitments[idx].comSeed,
                "Invalid seed reveal"
            );

            revealedSeeds[idx] = _seeds[i];
        }

        for (uint256 i = 0; i < sOpen.length; i++) {
            require(seen[sOpen[i]], "Missing sOpen index");
        }

        pendingDisputeBuyerClosures = 0;
        for (uint256 i = 0; i < buyers.length; i++) {
            address buyerAddr = buyers[i];
            if (buyerStatus[buyerAddr] == BuyerStatus.Ready) {
                disputeClosedByBuyer[buyerAddr] = false;
                pendingDisputeBuyerClosures += 1;
            } else {
                disputeClosedByBuyer[buyerAddr] = true;
            }
        }

        currentStage = Stage.Dispute;
        deadlines.dispute = block.timestamp + 1 hours;
        deadlines.labels  = deadlines.dispute + 1 hours;
    }

    /**
     * @dev Phase 5 Timeout: If Alice fails to reveal seeds by the deadline.
     * Any buyer can claim the penalty.
     */
    function abortPhase4() external {
        require(currentStage == Stage.Open, "Not in open stage");
        require(block.timestamp > deadlines.open, "Alice is not late yet");
        require(isBuyer[msg.sender], "Only buyer can trigger this");

        uint256 amountAlice = vault[alice];
        uint256 amountBuyer = vault[msg.sender];

        vault[alice] = 0;
        vault[msg.sender] = 0;
        _refundPassiveBuyers(msg.sender, msg.sender);

        (bool success, ) = payable(msg.sender).call{value: amountAlice + amountBuyer}("");
        require(success, "Penalty transfer failed");

        currentStage = Stage.Closed;
    }

    /**
     * @dev Phase 7: Alice reveals her input labels for the evaluation circuit m.
     * These labels correspond to her private input x.
     * @param _labels The set of wire labels for Alice's input.
     */
    function revealGarblerLabels(bytes32[] calldata _labels) external {
        require(currentStage == Stage.Labels, "Wrong stage");
        require(msg.sender == alice, "Only Garbler");
        require(block.timestamp <= deadlines.labels, "Label reveal deadline missed");
        require(_labels.length == bitWidth, "Bad labels length");

        bytes32 bHash = blobhash(0);
        require(bHash != bytes32(0), "Garbled Table Blob missing");
        require(bHash == instanceCommitments[m].blobHashGC, "Blob does not match Phase 2 commitment");

        garblerLabels = _labels;

        currentStage = Stage.Settle;
        deadlines.settle = block.timestamp + 1 hours;
    }

    /**
     * @dev Phase 7 Timeout: If Alice fails to provide her input labels.
     * Any buyer can claim the penalty because they cannot evaluate the circuit.
     */
    function abortPhase5() external {
        require(currentStage == Stage.Labels, "Not in labels stage");
        require(block.timestamp > deadlines.labels, "Alice is not late yet");
        require(isBuyer[msg.sender], "Only buyer can trigger this");

        uint256 total = vault[alice] + vault[msg.sender];
        vault[alice] = 0;
        vault[msg.sender] = 0;
        _refundPassiveBuyers(msg.sender, msg.sender);

        (bool success, ) = payable(msg.sender).call{value: total}("");
        require(success, "Penalty transfer failed");

        currentStage = Stage.Closed;
    }

/**
     * @dev Phase 6 (Dispute): Buyer challenges one gate from one opened check-circuit.
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
        require(isBuyer[msg.sender], "Only buyer can dispute");
        require(buyerStatus[msg.sender] == BuyerStatus.Ready, "Buyer not active in dispute");
        require(_idx < N, "Index out of bounds");
        require(_isOpenInstance(_idx), "Not an opened instance");
        require(revealedSeeds[_idx] == _seed, "Seed mismatch");

        challengeGateLeaf(_idx, gateIndex, g, leafBytes, ihProof, layoutProof);
    }

    function _computeOutputAnchor(uint256 instanceId, bytes calldata outputBytes) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("OUT", circuitId, instanceId, outputBytes));
    }

    function _decodeOutput(bytes calldata outputBytes) internal pure returns (uint16 outWinnerId, uint64 outWinningBid) {
        require(outputBytes.length == OUTPUT_TOTAL_BYTES, "Bad output length");
        uint256 word;
        assembly {
            word := calldataload(outputBytes.offset)
        }
        outWinnerId = uint16(word >> 240);
        outWinningBid = uint64((word >> 176) & 0xFFFFFFFFFFFFFFFF);
    }

    /**
     * @dev Phase 8: participant submits the final output label.
     * Output bytes encoding is fixed-width packed:
     * abi.encodePacked(uint16 winnerId, uint64 winningBid).
     * Matching is done against circuit-bound output anchor committed in `hOut`.
     */
    function settle(bytes calldata outputBytes) external {
        require(currentStage == Stage.Settle, "Wrong stage");
        require(_isParticipant(msg.sender), "Only participant");
        require(block.timestamp <= deadlines.settle, "Settlement deadline missed");

        InstanceCommitment storage evalInstance = instanceCommitments[m];
        require(_computeOutputAnchor(m, outputBytes) == evalInstance.hOut, "Invalid output commitment");

        (uint16 outWinnerId, uint64 outWinningBid) = _decodeOutput(outputBytes);
        require(outWinnerId < buyers.length, "winnerId out of bounds");
        uint256 winningBidLimit = uint256(1) << uint256(bitWidth);
        require(uint256(outWinningBid) < winningBidLimit, "winningBid out of range");
        address outWinnerBuyer = buyers[outWinnerId];
        require(uint256(outWinningBid) <= DEPOSIT_EVALUATOR, "winningBid exceeds max deposit");
        require(uint256(outWinningBid) <= vault[outWinnerBuyer], "winningBid exceeds winner vault");

        // First-price auction transfer: winner pays own bid to Alice from winner collateral vault.
        vault[outWinnerBuyer] -= uint256(outWinningBid);
        vault[alice] += uint256(outWinningBid);

        winnerId = outWinnerId;
        winningBid = outWinningBid;
        winnerBuyer = outWinnerBuyer;
        winnerReceiver = buyerReceiver[winnerBuyer];

        emit WinnerResolved(winnerId, winnerBuyer, winnerReceiver, winningBid);
        currentStage = Stage.Assignment;
    }

    function finalizeAssignment() external {
        require(currentStage == Stage.Assignment, "Wrong stage");
        require(!assigned, "Assignment already finalized");
        require(winnerBuyer != address(0), "Winner buyer not set");
        require(winnerReceiver != address(0), "Winner receiver not set");

        assigned = true;
        IEnsAuctionAdapter(ensAdapter).assign(ensNamehash, winnerReceiver);
        emit EnsAssigned(ensNamehash, winnerReceiver);

        uint256 payoutAlice = vault[alice];
        vault[alice] = 0;
        (bool s1, ) = payable(alice).call{value: payoutAlice}("");
        require(s1, "Payout to Alice failed");

        for (uint256 i = 0; i < buyers.length; i++) {
            address buyerAddr = buyers[i];
            uint256 payoutBuyer = vault[buyerAddr];
            vault[buyerAddr] = 0;
            if (payoutBuyer == 0) {
                continue;
            }
            (bool sBuyer, ) = payable(buyerAddr).call{value: payoutBuyer}("");
            require(sBuyer, "Payout to buyer failed");
        }

        currentStage = Stage.Closed;
    }

    /**
     * @dev Phase 8 Timeout: If settlement is not submitted by deadline, Alice can claim funds.
     */
    function abortPhase6() external {
        require(
            currentStage == Stage.Settle || currentStage == Stage.Assignment,
            "Not in settle/assignment stage"
        );
        require(msg.sender == alice, "Only Alice can trigger this");
        require(block.timestamp > deadlines.settle, "Settle deadline not reached");

        uint256 total = vault[alice];
        vault[alice] = 0;
        for (uint256 i = 0; i < buyers.length; i++) {
            address buyerAddr = buyers[i];
            total += vault[buyerAddr];
            vault[buyerAddr] = 0;
        }

        (bool success, ) = payable(alice).call{value: total}("");
        require(success, "Refund to Alice failed");

        currentStage = Stage.Closed;
    }

    function getSOpenLength() external view returns (uint256) {
        return sOpen.length;
    }

    /**
     * @dev Refunds all registered buyers except the provided addresses.
     */
    function _refundPassiveBuyers(address skipA, address skipB) internal {
        for (uint256 i = 0; i < buyers.length; i++) {
            address buyerAddr = buyers[i];
            if (buyerAddr == skipA || buyerAddr == skipB) {
                continue;
            }
            uint256 amount = vault[buyerAddr];
            vault[buyerAddr] = 0;
            if (amount == 0) {
                continue;
            }
            (bool ok, ) = payable(buyerAddr).call{value: amount}("");
            require(ok, "Buyer refund failed");
        }
    }

    /**
     * @dev Private helper to transfer all funds to the winner and close the contract.
     */
    function _slashBuyerToAlice(address buyerAddr) private {
        uint256 prize = vault[alice] + vault[buyerAddr];
        vault[alice] = 0;
        vault[buyerAddr] = 0;
        _refundPassiveBuyers(alice, buyerAddr);

        (bool success, ) = payable(alice).call{value: prize}("");
        require(success, "Slashed transfer failed");
        currentStage = Stage.Closed;
    }

    function _slashAliceToAllBuyers() private {
        uint256 aliceCollateral = vault[alice];
        vault[alice] = 0;

        uint256 buyersLen = buyers.length;
        uint256 share = buyersLen == 0 ? 0 : aliceCollateral / buyersLen;
        uint256 remainder = buyersLen == 0 ? 0 : aliceCollateral % buyersLen;

        for (uint256 i = 0; i < buyersLen; i++) {
            address buyerAddr = buyers[i];
            uint256 payout = vault[buyerAddr] + share;
            if (i == 0) {
                payout += remainder;
            }
            vault[buyerAddr] = 0;
            if (payout == 0) {
                continue;
            }
            (bool successBuyer, ) = payable(buyerAddr).call{value: payout}("");
            require(successBuyer, "Buyer payout failed");
        }
        currentStage = Stage.Closed;
    }

    function closeDispute() external {
        require(currentStage == Stage.Dispute, "Wrong stage");
        require(_isParticipant(msg.sender), "Only participant");

        if (block.timestamp > deadlines.dispute || pendingDisputeBuyerClosures == 0) {
            currentStage = Stage.Labels;
            return;
        }

        if (isBuyer[msg.sender]) {
            require(buyerStatus[msg.sender] == BuyerStatus.Ready, "Buyer not active in dispute");
            if (!disputeClosedByBuyer[msg.sender]) {
                disputeClosedByBuyer[msg.sender] = true;
                pendingDisputeBuyerClosures -= 1;
            }
            if (pendingDisputeBuyerClosures == 0) {
                currentStage = Stage.Labels;
            }
            return;
        }

        if (msg.sender == alice) {
            require(block.timestamp > deadlines.dispute, "Dispute window still open");
            currentStage = Stage.Labels;
            return;
        }

        revert("Only participant");
    }

    // ------ GC part ------
    //  Spec primitives

    // setting primitives
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
    event OTInstanceRootChallenged(uint256 indexed instanceId, bool mismatch);
    event OTBuyerRootChallenged(address indexed buyer, uint256 indexed instanceId, bool mismatch);
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
        require(isBuyer[msg.sender], "Only buyer for dispute");
        require(buyerStatus[msg.sender] == BuyerStatus.Ready, "Buyer not active in dispute");

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
            emit CheaterSlashed(alice, address(0));
            _slashAliceToAllBuyers();
        } else {
            emit GateLeafChallenged(instanceId, gateIndex, false);
            emit CheaterSlashed(msg.sender, alice);
            _slashBuyerToAlice(msg.sender);
        }
    }

    /**
     * @dev Phase 6 (Dispute): Buyer challenges OT root commitment for one opened instance.
     * Contract deterministically recomputes rootOT from (revealed garbler seed, revealed verifier seed)
     * and immediately resolves/slashes on mismatch or false challenge.
     */
    function disputeObliviousTransferRoot(uint256 instanceId) external {
        require(isBuyer[msg.sender], "Only buyer");
        disputeObliviousTransferRootForBuyer(msg.sender, instanceId);
    }

    /**
     * @dev Buyer-scoped OT dispute for opened instances.
     * Buyer can challenge only their own OT root commitment.
     */
    function disputeObliviousTransferRootForBuyer(address buyerAddr, uint256 instanceId) public {
        require(currentStage == Stage.Dispute, "Wrong stage");
        require(block.timestamp <= deadlines.dispute, "Dispute deadline missed");
        require(isBuyer[buyerAddr], "Not buyer");
        require(msg.sender == buyerAddr, "Only challenged buyer");
        require(vault[msg.sender] == DEPOSIT_EVALUATOR, "Challenger not deposited");
        require(buyerStatus[msg.sender] == BuyerStatus.Ready, "Buyer not active in dispute");
        require(instanceId < N, "Index out of bounds");
        require(instanceId != m, "Cannot dispute evaluation circuit m");
        require(verifierSeedFinalized, "Verifier seed not finalized");
        _resolveOtRootChallenge(buyerAddr, instanceId, msg.sender);
    }

    // leaf = H(circuitId || gateIndex || gateType || wireA || wireB || wireC)
    function _layoutLeafHash(uint256 gateIndex, GateDesc calldata g) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(circuitId, gateIndex, uint8(g.gateType), g.wireA, g.wireB, g.wireC));
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
    function _commutativeNodeHash(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a <= b
            ? keccak256(abi.encodePacked(a, b))
            : keccak256(abi.encodePacked(b, a));
    }

    function _otMessageAuthor(uint8 round) internal pure returns (uint8) {
        require(round < OT_ROUNDS_PER_INPUT, "Bad OT round");
        return round == 1 ? 1 : 0;
    }

    function _otTranscriptLeafHash(uint16 inputBit, uint8 round, uint8 author, bytes32 payloadHash)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(inputBit, round, author, payloadHash));
    }

    function _evaluatorWireId(uint16 inputBit) internal view returns (uint16) {
        require(inputBit < bitWidth, "OT input bit out of range");
        return bitWidth + inputBit;
    }

    function _computeOtPayloadHash(
        bytes32 garblerSeed,
        bytes32 verifierSeedValue,
        address buyerAddr,
        uint256 instanceId,
        uint16 inputBit,
        uint8 round
    )
        internal
        view
        returns (bytes32)
    {
        uint16 wireId = _evaluatorWireId(inputBit);
        bytes16 label0 = deriveWireLabel(garblerSeed, instanceId, wireId, 0);
        bytes16 label1 = deriveWireLabel(garblerSeed, instanceId, wireId, 1);

        bytes32 senderRandomness = keccak256(
            abi.encodePacked("OT-S", circuitId, buyerAddr, instanceId, wireId, garblerSeed)
        );
        bytes32 verifierRandomness = keccak256(
            abi.encodePacked("OT-R", circuitId, buyerAddr, instanceId, wireId, verifierSeedValue)
        );

        if (round == 0) {
            return keccak256(
                abi.encodePacked(
                    "OT-M0",
                    circuitId,
                    buyerAddr,
                    instanceId,
                    inputBit,
                    wireId,
                    label0,
                    label1,
                    senderRandomness
                )
            );
        }

        if (round == 1) {
            return keccak256(
                abi.encodePacked(
                    "OT-M1",
                    circuitId,
                    buyerAddr,
                    instanceId,
                    inputBit,
                    wireId,
                    OT_DUMMY_CHOICE,
                    verifierRandomness
                )
            );
        }

        return keccak256(
            abi.encodePacked(
                "OT-M2",
                circuitId,
                buyerAddr,
                instanceId,
                inputBit,
                wireId,
                OT_DUMMY_CHOICE,
                label0,
                senderRandomness,
                verifierRandomness
            )
        );
    }

    function _recomputeOtRoot(
        bytes32 garblerSeed,
        bytes32 verifierSeedValue,
        address buyerAddr,
        uint256 instanceId
    )
        internal
        view
        returns (bytes32)
    {
        uint256 width = uint256(bitWidth) * OT_ROUNDS_PER_INPUT;
        bytes32[] memory level = new bytes32[](width);

        uint256 cursor = 0;
        for (uint16 inputBit = 0; inputBit < bitWidth; inputBit++) {
            for (uint8 round = 0; round < OT_ROUNDS_PER_INPUT; round++) {
                uint8 author = _otMessageAuthor(round);
                bytes32 payloadHash = _computeOtPayloadHash(
                    garblerSeed,
                    verifierSeedValue,
                    buyerAddr,
                    instanceId,
                    inputBit,
                    round
                );
                level[cursor] = _otTranscriptLeafHash(inputBit, round, author, payloadHash);
                cursor++;
            }
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

    function _resolveOtRootChallenge(address buyerAddr, uint256 instanceId, address challenger) internal {
        bytes32 garblerSeed = _requireRevealedSeedForOpenedInstance(instanceId);
        bytes32 expectedRoot = _recomputeOtRoot(garblerSeed, verifierSeed, buyerAddr, instanceId);
        bytes32 committedRoot = buyerRootOTCommitment[buyerAddr][instanceId];
        require(committedRoot != bytes32(0), "Buyer OT root not committed");
        bool matchRoot = expectedRoot == committedRoot;

        if (!matchRoot) {
            emit OTInstanceRootChallenged(instanceId, true);
            emit OTBuyerRootChallenged(buyerAddr, instanceId, true);
            emit CheaterSlashed(alice, address(0));
            _slashAliceToAllBuyers();
        } else {
            emit OTInstanceRootChallenged(instanceId, false);
            emit OTBuyerRootChallenged(buyerAddr, instanceId, false);
            emit CheaterSlashed(challenger, alice);
            _slashBuyerToAlice(challenger);
        }
    }
}
