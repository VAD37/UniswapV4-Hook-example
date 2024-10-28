// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Owned} from "solmate/src/auth/Owned.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";

import "./DoorLock.sol";
import "./libraries/Security.sol";

/// @title Uniswap Hook for private pool refund 100% fee back.
/// @notice Fee is forced to be 0% for this hook. Official Web interface will include how much fee is taken for normal user.
/// @notice Bot contract allowed to use this hook with empty data to swap for free as intended.
/// @dev fee is optional from HookData. This allow take fee from input or output token directly much more gas-cost efficient.
/// @dev dynamic fee only take from input token. For PoolLiquidity holder this seem right.
/// But from user perspective want free cashback. User must have option to choose what kind of final asset they want to hold without extra steps through router.
contract Hook is DoorLock, BaseHook {
    event TokenWhitelistUpdated(address token, bool isAllowed);

    error OnlyPoolManager();

    constructor(address _owner, address _poolManager) DoorLock(_owner) BaseHook(IPoolManager(_poolManager)) {}

    ///@dev immutable variable does not work with Hook struct.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, //prevent unknown pool hook by mistake
            afterInitialize: false,
            beforeAddLiquidity: true, // prevent user from adding liquidity
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true, // prevent user from adding liquidity
            afterRemoveLiquidity: false,
            beforeSwap: true, //
            afterSwap: true, //
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, //@note delta is money "write" to Hook contract balance not to router/user
            afterSwapReturnDelta: true, // It is unclear if swapDelta still used without set beforeSwap to true
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    //* EXPLICIT ADMIN POOL INTERACTION *//

    function beforeInitialize(address, PoolKey calldata _poolKey, uint160) external virtual override returns (bytes4) {
        //Always assume trusted admin know what they are doing
        _checkSecurity(Security.BASIC);
        require(_poolKey.hooks == IHooks(address(this)), "Wrong Hook");
        require(_poolKey.fee == 0, "Fee must be 0");
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

    //* USER INTERACTION *//

    function beforeSwap(
        address _sender,
        PoolKey calldata _poolKey,
        IPoolManager.SwapParams calldata _swapParams,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        require(msg.sender == address(poolManager), OnlyPoolManager());

        //amountSpecified < 0  means taking exactInput
        if (_swapParams.amountSpecified < 0 && _poolKey.fee > 0) {
            uint256 feeEarned = uint256(-_swapParams.amountSpecified) * _poolKey.fee / 10000000;

            address token =
                _swapParams.zeroForOne ? Currency.unwrap(_poolKey.currency0) : Currency.unwrap(_poolKey.currency1);

            //pool take fee from input. Refund that to user
            // magicMock.compensate(_sender, token, feeEarned);
        }

        //if exactOutput. then wait for afterSwap to calculate input fee
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @return feeDelta should be positive. taken from user balance and transfered it to this Hook contracts.
    function afterSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta swapResult,
        bytes calldata
    ) external override returns (bytes4, int128 feeDelta) {
        require(msg.sender == address(poolManager), "Only pool Hook");
        //if exactOutput then find input token amount then predict how much fee was taken from that

        if (swapParams.amountSpecified > 0 && poolKey.fee > 0) {
            // swapResult always negative for input token. So we inverse it.
            uint256 inputTokenAmount = uint128(-(swapParams.zeroForOne ? swapResult.amount0() : swapResult.amount1()));
            // if fee is 0.3%. then swapResult amount here already include 0.3% fee.
            // we divided by 1.003 to get original swap with fee. subtract that to get fee profit. Then refund this to user
            //@not use FullMath cuz lazy
            uint256 feeEarned = inputTokenAmount - (inputTokenAmount * 10000000 / (10000000 + poolKey.fee));
            address token =
                swapParams.zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
            // magicMock.compensate(msg.sender, token, feeEarned);
        }

        //@note Hooks.afterSwap() is confusing. Unclear if return delta value update input or output token.

        //@note it is impossible to call PoolManager.clear() to prevent token transfer from pool to hook.
        //it is not necessary here because pool is private there is no need to transfer fee from pool to hook

        return (BaseHook.afterSwap.selector, feeDelta);
    }
}
