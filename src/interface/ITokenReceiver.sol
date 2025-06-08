// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITokenReceiver {
    function getLastReceivedMessageDetails()
        external
        view
        returns (bytes32 messageId, address tokenAddress, uint256 tokenAmount, string memory text);
}