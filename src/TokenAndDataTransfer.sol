// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ITokenSender} from "./interface/ITokenSender.sol";
import {ITokenReceiver} from "./interface/ITokenReceiver.sol";
contract TokenTransfers is CCIPReceiver, AccessControl, ITokenSender, ITokenReceiver {
    using SafeERC20 for IERC20;

    // Define roles for access control
    bytes32 public constant SENDER_ROLE = keccak256("SENDER_ROLE");
    bytes32 public constant RECEIVER_ROLE = keccak256("RECEIVER_ROLE");

    IRouterClient public router;
    IERC20 public linkToken;

    mapping(uint64 => bool) public allowlistedDestinationChains;
    mapping(uint64 => mapping(address => bool)) public allowlistedSourceChainAndSender;

    bytes32 public lastReceivedMessageId;
    address public lastReceivedTokenAddress;
    uint256 public lastReceivedTokenAmount;
    string public lastReceivedText;

    event MessageSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address receiver,
        string text,
        address token,
        uint256 amount,
        address feeToken,
        uint256 fees
    );

    event MessageReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address sender,
        address token,
        uint256 amount,
        string text
    );

    event RequestDataReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address sender,
        address token,
        uint256 amount,
        string text
    );

    constructor(address _router, address _linkToken) CCIPReceiver(_router) {
        router = IRouterClient(_router);
        linkToken = IERC20(_linkToken);

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(SENDER_ROLE, msg.sender);
        _setupRole(RECEIVER_ROLE, msg.sender);
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(AccessControl, CCIPReceiver) returns (bool) {
        return AccessControl.supportsInterface(interfaceId) || CCIPReceiver.supportsInterface(interfaceId);
    }

    function allowlistDestinationChain(uint64 _destinationChainSelector, bool _allowed)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        allowlistedDestinationChains[_destinationChainSelector] = _allowed;
    }

    function allowlistSourceChainAndSender(
        uint64 _sourceChainSelector,
        address _sender,
        bool _allowed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allowlistedSourceChainAndSender[_sourceChainSelector][_sender] = _allowed;
    }

    function transferTokenFromSender(address _token, uint256 _amount) internal {
        require(_token != address(0), "Token address cannot be zero");
        require(_amount > 0, "Amount must be greater than zero");

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
    }

    function _buildCCIPMessage(
        address _receiver,
        string calldata _text,
        address _token,
        uint256 _amount,
        address _feeTokenAddress,
        bool _includeTokens
    ) private pure returns (Client.EVM2AnyMessage memory) {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        if (_includeTokens) {
            tokenAmounts[0] = Client.EVMTokenAmount({token: _token, amount: _amount});
        } else {
            tokenAmounts[0] = Client.EVMTokenAmount({token: address(0), amount: 0});
        }

        return Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: abi.encode(_text),
            tokenAmounts: tokenAmounts,
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 200_000})
            ),
            feeToken: _feeTokenAddress
        });
    }

    function sendMessageWithTokensPayLINK(
        uint64 _destinationChainSelector,
        address _receiver,
        string calldata _text,
        address _token,
        uint256 _amount
    ) external onlyRole(SENDER_ROLE) returns (bytes32 messageId) {
        require(allowlistedDestinationChains[_destinationChainSelector], "Destination chain not allowlisted");
        require(_token != address(0), "Token address cannot be zero");
        require(_amount > 0, "Amount must be greater than zero");

        transferTokenFromSender(_token, _amount);

        Client.EVM2AnyMessage memory message = _buildCCIPMessage(
            _receiver,
            _text,
            _token,
            _amount,
            address(linkToken),
            true
        );

        uint256 fees = router.getFee(_destinationChainSelector, message);
        require(linkToken.balanceOf(address(this)) >= fees, "Not enough LINK to pay fees");

        linkToken.safeApprove(address(router), fees);
        IERC20(_token).safeApprove(address(router), _amount);

        messageId = router.ccipSend(_destinationChainSelector, message);

        emit MessageSent(
            messageId,
            _destinationChainSelector,
            _receiver,
            _text,
            _token,
            _amount,
            address(linkToken),
            fees
        );

        return messageId;
    }

    function sendMessageWithTokensPayNative(
        uint64 _destinationChainSelector,
        address _receiver,
        string calldata _text,
        address _token,
        uint256 _amount
    ) external payable onlyRole(SENDER_ROLE) returns (bytes32 messageId) {
        require(allowlistedDestinationChains[_destinationChainSelector], "Destination chain not allowlisted");
        require(_token != address(0), "Token address cannot be zero");
        require(_amount > 0, "Amount must be greater than zero");

        Client.EVM2AnyMessage memory message = _buildCCIPMessage(
            _receiver,
            _text,
            _token,
            _amount,
            address(0),
            true
        );

        uint256 fees = router.getFee(_destinationChainSelector, message);
        require(msg.value >= fees, "Not enough native gas to pay fees");

        IERC20(_token).safeApprove(address(router), _amount);

        messageId = router.ccipSend{value: fees}(_destinationChainSelector, message);

        emit MessageSent(
            messageId,
            _destinationChainSelector,
            _receiver,
            _text,
            _token,
            _amount,
            address(0),
            fees
        );

        return messageId;
    }

    function sendMessageWithoutTokensPayLINK(
        uint64 _destinationChainSelector,
        address _receiver,
        string calldata _text
    ) external onlyRole(SENDER_ROLE) returns (bytes32 messageId) {
        require(allowlistedDestinationChains[_destinationChainSelector], "Destination chain not allowlisted");

        Client.EVM2AnyMessage memory message = _buildCCIPMessage(
            _receiver,
            _text,
            address(0),
            0,
            address(linkToken),
            false
        );

        uint256 fees = router.getFee(_destinationChainSelector, message);
        require(linkToken.balanceOf(address(this)) >= fees, "Not enough LINK to pay fees");

        linkToken.safeApprove(address(router), fees);

        messageId = router.ccipSend(_destinationChainSelector, message);

        emit MessageSent(
            messageId,
            _destinationChainSelector,
            _receiver,
            _text,
            address(0),
            0,
            address(linkToken),
            fees
        );

        return messageId;
    }

    function sendMessageWithoutTokensPayNative(
        uint64 _destinationChainSelector,
        address _receiver,
        string calldata _text
    ) external payable onlyRole(SENDER_ROLE) returns (bytes32 messageId) {
        require(allowlistedDestinationChains[_destinationChainSelector], "Destination chain not allowlisted");

        Client.EVM2AnyMessage memory message = _buildCCIPMessage(
            _receiver,
            _text,
            address(0),
            0,
            address(0),
            false
        );

        uint256 fees = router.getFee(_destinationChainSelector, message);
        require(msg.value >= fees, "Not enough native gas to pay fees");

        messageId = router.ccipSend{value: fees}(_destinationChainSelector, message);

        emit MessageSent(
            messageId,
            _destinationChainSelector,
            _receiver,
            _text,
            address(0),
            0,
            address(0),
            fees
        );

        return messageId;
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        address sender = abi.decode(message.sender, (address));
        require(
            allowlistedSourceChainAndSender[message.sourceChainSelector][sender],
            "Source chain or sender not allowlisted"
        );

        lastReceivedMessageId = message.messageId;
        lastReceivedTokenAddress = message.destTokenAmounts[0].token;
        lastReceivedTokenAmount = message.destTokenAmounts[0].amount;
        lastReceivedText = abi.decode(message.data, (string));

        emit MessageReceived(
            message.messageId,
            message.sourceChainSelector,
            sender,
            message.destTokenAmounts[0].token,
            message.destTokenAmounts[0].amount,
            lastReceivedText
        );

        emit RequestDataReceived(
            message.messageId,
            message.sourceChainSelector,
            sender,
            message.destTokenAmounts[0].token,
            message.destTokenAmounts[0].amount,
            lastReceivedText
        );
    }

    function getLastReceivedMessageDetails()
        external
        view
        onlyRole(RECEIVER_ROLE)
        returns (bytes32 messageId, address tokenAddress, uint256 tokenAmount, string memory text)
    {
        return (lastReceivedMessageId, lastReceivedTokenAddress, lastReceivedTokenAmount, lastReceivedText);
    }

    receive() external payable {}
}