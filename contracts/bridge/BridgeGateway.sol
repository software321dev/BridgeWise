// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {BridgeEvents} from "../events/BridgeEvents.sol";
import {BridgeWrappedToken} from "../tokens/BridgeWrappedToken.sol";

contract BridgeGateway is BridgeEvents, AccessControl {
    using SafeERC20 for IERC20;

    uint32 public immutable chainId;
    address public immutable wrappedToken;
    mapping(uint32 => uint64) public outboundNonces;
    mapping(address => uint256) public maxDepositLimit;
    mapping(address => bool) public isTokenAllowed;
    mapping(address => uint256) public tokenExposure;
    mapping(uint32 => uint256) public chainExposure;
    mapping(address => uint256) public maxTokenExposure;
    mapping(uint32 => uint256) public maxChainExposure;

    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error TokenNotAllowed(address token);
    error DepositExceedsLimit(uint256 amount, uint256 limit);
    error TokenExposureExceeded(address token, uint256 exposure, uint256 limit);
    error ChainExposureExceeded(uint32 dstChainId, uint256 exposure, uint256 limit);

    event TokenAllowlistUpdated(address indexed token, bool allowed);
    event MaxDepositLimitSet(address indexed token, uint256 amount);
    event MaxTokenExposureSet(address indexed token, uint256 amount);
    event MaxChainExposureSet(uint32 indexed chainId, uint256 amount);
    event DepositLocked(address indexed token, address indexed sender, uint256 amount, uint32 destinationChainId, bytes32 recipient);
    event LiquidityWithdrawn(address indexed token, address indexed to, uint256 amount);

    constructor(uint32 _chainId, address _wrappedToken, address _admin) {
        if (_wrappedToken == address(0)) revert ZeroAddress();
        if (_admin == address(0)) revert ZeroAddress();
        chainId = _chainId;
        wrappedToken = _wrappedToken;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function setTokenAllowed(address token, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        isTokenAllowed[token] = allowed;
        emit TokenAllowlistUpdated(token, allowed);
    }

    function setBatchTokenAllowed(address[] calldata tokens, bool[] calldata allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tokens.length != allowed.length) revert ZeroAddress();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) revert ZeroAddress();
            isTokenAllowed[tokens[i]] = allowed[i];
            emit TokenAllowlistUpdated(tokens[i], allowed[i]);
        }
    }

    function setMaxDepositLimit(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        maxDepositLimit[token] = amount;
        emit MaxDepositLimitSet(token, amount);
    }

    function setMaxTokenExposure(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        maxTokenExposure[token] = amount;
        emit MaxTokenExposureSet(token, amount);
    }

    function setMaxChainExposure(uint32 dstChainId, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxChainExposure[dstChainId] = amount;
        emit MaxChainExposureSet(dstChainId, amount);
    }

    function lock(uint32 dstChainId, address token, uint256 amount, bytes32 recipient) external returns (bytes32 msgHash, uint64 nonce) {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!isTokenAllowed[token]) revert TokenNotAllowed(token);
        uint256 depositLimit = maxDepositLimit[token];
        if (depositLimit > 0 && amount > depositLimit) {
            revert DepositExceedsLimit(amount, depositLimit);
        }
        _checkTokenExposure(token, amount);
        _checkChainExposure(dstChainId, amount);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        tokenExposure[token] += amount;
        chainExposure[dstChainId] += amount;
        nonce = outboundNonces[dstChainId];
        outboundNonces[dstChainId] = nonce + 1;
        msgHash = keccak256(abi.encodePacked(chainId, dstChainId, nonce, token, amount, recipient));
        emit MessageSent(msgHash, chainId, dstChainId, nonce);
    }

    function burn(uint32 dstChainId, address account, uint256 amount, bytes32 recipient) external returns (bytes32 msgHash, uint64 nonce) {
        if (account == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 depositLimit = maxDepositLimit[wrappedToken];
        if (depositLimit > 0 && amount > depositLimit) {
            revert DepositExceedsLimit(amount, depositLimit);
        }
        _checkTokenExposure(wrappedToken, amount);
        _checkChainExposure(dstChainId, amount);
        BridgeWrappedToken(wrappedToken).burnFrom(account, amount);
        tokenExposure[wrappedToken] += amount;
        chainExposure[dstChainId] += amount;
        nonce = outboundNonces[dstChainId];
        outboundNonces[dstChainId] = nonce + 1;
        msgHash = keccak256(abi.encodePacked(chainId, dstChainId, nonce, account, amount, recipient));
        emit MessageSent(msgHash, chainId, dstChainId, nonce);
    }

    function mint(bytes32 msgHash, uint32 srcChainId, address to, uint256 amount) external {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!isTokenAllowed[wrappedToken]) revert TokenNotAllowed(wrappedToken);
        BridgeWrappedToken(wrappedToken).mint(to, amount);
        emit MessageDelivered(msgHash, srcChainId, chainId, true);
    }

    function unlock(bytes32 msgHash, uint32 srcChainId, address token, address to, uint256 amount) external {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (!isTokenAllowed[token]) revert TokenNotAllowed(token);
        IERC20(token).safeTransfer(to, amount);
        emit MessageDelivered(msgHash, srcChainId, chainId, true);
    }

    function fail(bytes32 msgHash, uint32 srcChainId, address recipient, address token, uint256 amount) external {
        if (recipient == address(0)) revert ZeroAddress();
        emit MessageFailed(msgHash, srcChainId, chainId, recipient, token, amount);
    }

    function withdrawLiquidity(address token, uint256 amount, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit LiquidityWithdrawn(token, to, amount);
    }

    function _checkTokenExposure(address token, uint256 amount) internal view {
        uint256 limit = maxTokenExposure[token];
        if (limit > 0 && tokenExposure[token] + amount > limit) {
            revert TokenExposureExceeded(token, tokenExposure[token] + amount, limit);
        }
    }

    function _checkChainExposure(uint32 dstChainId, uint256 amount) internal view {
        uint256 limit = maxChainExposure[dstChainId];
        if (limit > 0 && chainExposure[dstChainId] + amount > limit) {
            revert ChainExposureExceeded(dstChainId, chainExposure[dstChainId] + amount, limit);
        }
    }
}
