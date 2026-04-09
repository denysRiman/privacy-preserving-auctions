// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract EnsAuctionAdapterMock {
    event Assigned(bytes32 indexed namehash, address indexed receiver);

    function assign(bytes32 namehash, address receiver) external {
        emit Assigned(namehash, receiver);
    }
}
