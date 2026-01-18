// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract MillionairesProblem {
    address public alice;
    address public bob;
    uint256 public constant DEPOSIT = 1 ether;

    mapping(address => uint256) public deposits;
    bool public isReady;

    constructor(address _bob) {
        alice = msg.sender;
        bob = _bob;
    }

    function deposit() public payable {
        require(msg.sender == alice || msg.sender == bob, "Not a participant");
        require(msg.value == DEPOSIT, "Must be 1 ETH");
        require(deposits[msg.sender] == 0, "Already deposited");

        deposits[msg.sender] = msg.value;

        if (deposits[alice] == DEPOSIT && deposits[bob] == DEPOSIT) {
            isReady = true;
        }
    }
}