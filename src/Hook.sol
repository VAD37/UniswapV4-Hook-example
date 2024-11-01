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
import "./libraries/HookLibrary.sol";

import {console2} from "forge-std/Test.sol";

/// @title Uniswap Hook for private pool refund 100% fee back.
/// @notice DynamicFee is forced to be 0% for this hook.
/// @notice Allow empty hook data swap for free.
/// @notice Support take fee from input or output token based on hook data.
/// @dev fee is optional from HookData. Fee value is bit flag value pass directly to PoolManager.
/// @dev @note fee on output token will prevent from getting exactOutput amount. Call to Router with exactOutput should padded fee amount to `amountSpecified` first. So exactOutput show to user will get correct amount.
/// @dev This hook refund fee to user. So take fee on output help user only want output token.
contract Hook is DoorLock, BaseHook {
    using HookLibrary for IPoolManager.SwapParams;
    using LPFeeLibrary for uint24;

    event TokenWhitelistUpdated(address token, bool isAllowed);
    event Refund(address indexed token, address indexed to, uint256 amount);
    event PlaceHolder(); //@dev just to ignore unused warning. HookLiquidity have no special use at the moment

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

    function beforeInitialize(address, PoolKey calldata poolKey, uint160) external virtual override returns (bytes4) {
        //Always assume trusted admin know what they are doing
        _checkSecurity(Security.BASIC);
        require(msg.sender == address(poolManager), OnlyPoolManager());
        require(poolKey.hooks == IHooks(address(this)), "Wrong Hook");
        require(poolKey.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG, "Must be Dynamic Fee");
        return BaseHook.beforeInitialize.selector;
    }

    ///@notice This Private pool should have a single Position.
    ///@dev Unlock Security here allow simple position ownership handling
    ///@dev sender expected to be PositionManager.sol
    ///@dev It is caller responsibility to prevent reentrancy attack
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        returns (bytes4)
    {
        _checkSecurity(Security.BASIC);
        emit PlaceHolder();
        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        _checkSecurity(Security.BASIC);
        emit PlaceHolder();
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    //* USER INTERACTION *//

    function beforeSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        require(msg.sender == address(poolManager), OnlyPoolManager());

        (bool feeOnInput, uint24 lpFee, address refundTo) = HookLibrary.softParse(hookData);
        BeforeSwapDelta hookReturn = BeforeSwapDeltaLibrary.ZERO_DELTA;
        //@ during BeforeSwap phase. we can only see and update specified token amount. So only take fee if both fee token and specified token are the same

        // if valid fee then start refund user. fee could be 104.8575%. Send that debt to user anyway. V4 Pool will revert with fee too high later
        if (lpFee.isOverride()) {
            if (swapParams.IsExactInput() && feeOnInput) {
                // swap fee by default take fee on Input token. No special action taken just refund user fee.
                uint256 feeEarned =
                    uint256(-swapParams.amountSpecified) * lpFee.removeOverrideFlag() / LPFeeLibrary.MAX_LP_FEE;
                address token =
                    swapParams.zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
                //TODO refund
                console2.log("refund %e", feeEarned, uint(lpFee.removeOverrideFlag()));
                emit Refund(token, refundTo, feeEarned);
            }
            // if exactOutput and fee on output. Then reduce exactOutput amount right here now. Because PoolManager not support reduce specified token in AfterSwap phase
            if (swapParams.IsExactOutput() && !feeOnInput) {                
                uint256 outputTokenAmount = uint256(swapParams.amountSpecified);                
                uint256 feeEarned = outputTokenAmount * lpFee / LPFeeLibrary.MAX_LP_FEE;
                address token =
                    swapParams.zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
                //update HookReturn to reduce profit from swap. profit move to Hook Balance so we will have to Donate() this later in post swap phase.
                //TODO refund
                emit Refund(token, refundTo, feeEarned);
                console2.log("refund %e", feeEarned);
            }
        }

        

        //if exactOutput and fee on input. then replace fee
        return (BaseHook.beforeSwap.selector, hookReturn, lpFee);
    }

    /// @return feeDelta should be positive. taken from user balance and transfered it to this Hook contracts.
    function afterSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta swapResult,
        bytes calldata hookData
    ) external override returns (bytes4, int128 feeDelta) {
        require(msg.sender == address(poolManager), OnlyPoolManager());
        //if exactOutput then find input token amount then predict how much fee was taken from that
        console2.log("afterSwap amount0: %e", swapResult.amount0());
        console2.log("afterSwap amount1: %e", swapResult.amount1());

        // HookParams memory hookParams = HookLibrary.softParse(hookData);

        // if (swapParams.amountSpecified > 0 && hookParams.lpFeeOverride > 0) {
        //     // swapResult always negative for input token. So we inverse it.
        //     uint256 inputTokenAmount = uint128(-(swapParams.zeroForOne ? swapResult.amount0() : swapResult.amount1()));
        //     // if fee is 0.3%. then swapResult amount here already include 0.3% fee.
        //     // we divided by 1.003 to get original swap with fee. subtract that to get fee profit. Then refund this to user
        //     //@not use FullMath cuz lazy
        //     uint256 feeEarned = inputTokenAmount - (inputTokenAmount * 10000000 / (10000000 + poolKey.fee));
        //     address token =
        //         swapParams.zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);

        //     //TODO refund
        //     emit Refund(token, hookParams.refundTo, feeEarned);
        // }

        return (BaseHook.afterSwap.selector, feeDelta);
    }
}
