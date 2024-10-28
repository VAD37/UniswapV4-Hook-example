// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";

import "./DoorLock.sol";
import "./libraries/Security.sol";

/// @notice Private Hook prevent user from changing liquidity or init new pool with unknown token
abstract contract PrivateHook is DoorLock, BaseHook {
    Hooks.Permissions public hookPermissions;
    mapping(address => bool) public isTokenAllowed;

    event TokenWhitelistUpdated(address token, bool isAllowed);

    constructor(address _owner, address _poolManager) SecurityLock(_owner) BaseHook(IPoolManager(_poolManager)) {
        hookPermissions = updateHookPermissions(hookPermissions);
    }

    function updateHookPermissions(Hooks.Permissions memory _hookPermissions) internal virtual {
        hookPermissions.beforeInitialize = true; //prevent unknown pool hook by mistake
        hookPermissions.beforeAddLiquidity = true; // prevent user from adding liquidity
        hookPermissions.beforeRemoveLiquidity = true;
    }

    function whitelistToken(address _token, bool _isAllowed) external onlyOwner {
        isTokenAllowed[_token] = _isAllowed;
        emit TokenWhitelistUpdated(_token, _isAllowed);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return hookPermissions;
    }

    function beforeInitialize(address sender, PoolKey calldata _poolKey, uint160)
        external
        virtual
        override
        returns (bytes4)
    {
        _checkSecurity(Security.BASIC);
        return BaseHook.beforeInitialize.selector;
    }

    ///@notice This Private pool should have a single Position.
    ///@dev Unlock Security here allow simple position ownership handling
    ///@dev sender expected to be PositionManager.sol
    ///@dev It is caller responsibility to prevent reentrancy attack
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata _hookData
    ) external override returns (bytes4) {
        _checkSecurity(Security.BASIC);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata _hookData
    ) external override returns (bytes4) {
        _checkSecurity(Security.BASIC);
        return BaseHook.beforeRemoveLiquidity.selector;
    }
}
