// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MillionairesProblem {
    address public alice; //Garbler
    address public bob; //Evaluator

    struct Deadlines {
        uint256 commit;
        uint256 open;
        uint256 dispute;
        uint256 settle;
    }

    enum Stage { Setup, Deposits, Commitments, Open, Dispute, Settle }
    Stage public currentStage;

    uint256 public constant DEPOSIT_GARBLER = 1 ether;
    uint256 public constant DEPOSIT_EVALUATOR = 1 ether;

    mapping(address => uint256) public vault;
    Deadlines public deadlines;

    constructor(address _bob) {
        alice = msg.sender;
        bob = _bob;
        currentStage = Stage.Deposits;

        deadlines.commit = block.timestamp + 1 hours;
    }

    function deposit() external payable {
        require(currentStage == Stage.Deposits, "Wrong stage");
        require(msg.sender == alice || msg.sender == bob, "Not authorized");
        require(vault[msg.sender] == 0, "Deposit already exists");
        require(msg.value == (msg.sender == alice ?
            DEPOSIT_GARBLER : DEPOSIT_EVALUATOR), "Wrong amount");

        vault[msg.sender] += msg.value;
        if (vault[alice] == DEPOSIT_GARBLER && vault[bob] == DEPOSIT_EVALUATOR) {
            currentStage = Stage.Commitments;
        }
    }

    /**
     * @dev Timeout logic for Phase 1.
     * Allows refund if the other party fails to deposit by the deadline.
     */
    function refund() external {
        require(currentStage == Stage.Deposits, "Too late for refund");
        require(block.timestamp > deadlines.commit, "Deadline not reached");
        require(vault[msg.sender] > 0, "Nothing to refund");

        uint256 amount = vault[msg.sender];
        vault[msg.sender] = 0;

        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }
}