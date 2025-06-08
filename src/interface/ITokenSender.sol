// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ITokenSender {
    function sendMessageWithTokensPayLINK(
        uint64 destinationChainSelector,
        address receiver,
        string calldata text,
        address token,
        uint256 amount
    ) external returns (bytes32 messageId);

    function sendMessageWithTokensPayNative(
        uint64 destinationChainSelector,
        address receiver,
        string calldata text,
        address token,
        uint256 amount
    ) external payable returns (bytes32 messageId);

    function sendMessageWithoutTokensPayLINK(
        uint64 destinationChainSelector,
        address receiver,
        string calldata text
    ) external returns (bytes32 messageId);

    function sendMessageWithoutTokensPayNative(
        uint64 destinationChainSelector,
        address receiver,
        string calldata text
    ) external payable returns (bytes32 messageId);
}