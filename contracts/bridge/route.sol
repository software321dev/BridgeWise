// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract BridgeRoute is AccessControl {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error Unauthorized();
    event RouteConfigured(uint32 indexed sourceChain, uint32 indexed destChain, address indexed token);

    mapping(uint32 => mapping(uint32 => mapping(address => bool))) public supportedRoutes;

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setRoute(uint32 srcChain, uint32 dstChain, address token, bool supported) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        supportedRoutes[srcChain][dstChain][token] = supported;
        emit RouteConfigured(srcChain, dstChain, token);
    }

    function isRouteSupported(uint32 srcChain, uint32 dstChain, address token) external view returns (bool) {
        return supportedRoutes[srcChain][dstChain][token];
    }
}
