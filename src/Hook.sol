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
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

import "./DoorLock.sol";
import "./libraries/Security.sol";
import "./libraries/HookLibrary.sol";

import {console2} from "forge-std/Test.sol";

interface DebtIssuer {
    function issueDebt(Currency currency, uint256 amount, address toUser) external;
}

/// @title Uniswap Hook for private pool that refund 100% fee back. Made to support free infrastructure in spirit.
/// @notice DynamicFee is forced to be 0% for this hook. Use override fee based on HookData.
/// @notice Allow any contract to swap for free. Anyone can make unofficial website to help user swap for free. Only holding fee for user going through main channel.
/// @notice Support take fee from input or output token based on hook data.
/// @notice Take fee on output token come with lots of **caveat**.
/// @notice Did not take Uniswap Protocol Fee into consideration. Expect uniswap fee to be 0% all the times same as UniswapV2,V3.
/// @dev fee is optional from HookData. Empty Hook data mean no fee.
/// @dev for take fee on output token to work. Router must call donate() with empty value after swap action.
/// @dev This hook refund fee to user. So take fee on output token help user only want output token
contract Hook is DoorLock, BaseHook {
    using SafeCast for *;
    using HookLibrary for IPoolManager.SwapParams;

    using LPFeeLibrary for uint24;
    using TransientStateLibrary for IPoolManager;

    event TokenWhitelistUpdated(address token, bool isAllowed);
    event Refund(address indexed token, address indexed to, uint256 amount);
    event PlaceHolder(); //@dev just to ignore unused warning. HookLiquidity have no special use at the moment

    error OnlyPoolManager();

    DebtIssuer public debtor;

    constructor(address _owner, address _poolManager, address _debtor)
        DoorLock(_owner)
        BaseHook(IPoolManager(_poolManager))
    {
        debtor = DebtIssuer(_debtor);
    }

    ///@dev immutable variable does not work with Hook struct.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, //prevent unknown pool hook
            afterInitialize: false,
            beforeAddLiquidity: true, // prevent user from adding liquidity
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true, // prevent user from adding liquidity
            afterRemoveLiquidity: false,
            beforeSwap: true, //
            afterSwap: true, //
            beforeDonate: false,
            afterDonate: true, // use to clear hook balance
            beforeSwapReturnDelta: true, //swapReturnDelta change how much input,output token is exchanged.
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    //* EXPLICIT ADMIN POOL INTERACTION *//

    function beforeInitialize(address, PoolKey calldata poolKey, uint160) external virtual override returns (bytes4) {
        //Always assume trusted admin know what they are doing
        _checkSecurityAndLock(Security.BASIC);
        require(msg.sender == address(poolManager), OnlyPoolManager());
        require(poolKey.hooks == IHooks(address(this)), "Wrong Hook");
        require(poolKey.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG, "Must be Dynamic Fee");
        return BaseHook.beforeInitialize.selector;
    }

    ///@notice This Private pool should be managed by Bank contract directly. Not going though PositionManager.
    ///@dev Unlock Security here allow simpler ownership handling. Since hook do not care who is the caller.
    ///@dev it is possible to force Hook always take ownedFee from position and redirect that gain to Bank, allowing Position to be controlled by anone. But it is much faster to have admin manually control position offchain
    /// Also if hook take fee from liquidity then router also have to donate fee back from hook to bank.
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        override
        returns (bytes4)
    {
        _checkSecurityAndLock(Security.BASIC);
        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external override returns (bytes4) {
        _checkSecurityAndLock(Security.BASIC);
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

        //@ during BeforeSwap phase. we can only see and update specified token amount. So only take fee if both fee token and specified token are the same

        // if valid fee then start refund user. fee could be 104.8575%. Send that debt to user anyway. V4 Pool will revert with fee too high later
        if (!lpFee.isOverride()) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        if (feeOnInput) {
            // swap fee by default take fee on Input token. return override fee is enough
            if (swapParams.IsExactInput()) {
                //input always negative
                uint256 feeAmount =
                    uint256(-swapParams.amountSpecified) * lpFee.removeOverrideFlag() / LPFeeLibrary.MAX_LP_FEE;
                Currency currency = swapParams.zeroForOne ? poolKey.currency0 : poolKey.currency1;
                debtor.issueDebt(currency, feeAmount, refundTo);
            }
            //if fee on input, but specified exactOutput.
            // wait until afterSwap to get unspecified input amount before refund fee.

            //return override fee
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFee);
        }
        //fee on output. and specified token is output, must edit specified token here. Calculate fee and add that amount to total output token needed to swap
        else if (!feeOnInput && swapParams.IsExactOutput()) {
            // swapAmount = specifiedAmount  * (100%-fee%)
            // feeAmount = specifiedAmount * fee% / (100%-fee%)
            uint256 fee = lpFee.removeOverrideFlag();
            uint256 feeAmount = uint256(swapParams.amountSpecified) * fee / (LPFeeLibrary.MAX_LP_FEE - fee);
            Currency currency = swapParams.zeroForOne ? poolKey.currency1 : poolKey.currency0;

            debtor.issueDebt(currency, feeAmount, refundTo);
            int128 feeDelta = feeAmount.toInt128();
            //toBeforeSwapDelta(specified,unspecified)
            //here we increase specified token which is exactOutput
            //So user need to call donate() after swap to wipe pool balance.
            BeforeSwapDelta hookDelta = toBeforeSwapDelta(feeDelta, 0);
            return (BaseHook.beforeSwap.selector, hookDelta, 0);
        }
        // no case for feeOnOutput and ExactInput. Because output is unspecified, afterSwap phase can edit unspecified.

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @return feeDelta should be positive. taken from user balance and transfer to this Hook balance.
    function afterSwap(
        address,
        PoolKey calldata poolKey,
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta swapResult,
        bytes calldata hookData
    ) external override returns (bytes4, int128) {
        require(msg.sender == address(poolManager), OnlyPoolManager());

        (bool feeOnInput, uint24 lpFee, address refundTo) = HookLibrary.softParse(hookData);

        if (!lpFee.isOverride()) {
            return (BaseHook.afterSwap.selector, 0);
        }

        if (feeOnInput && swapParams.IsExactOutput()) {
            // afterSwap phase return unspecified input amount result. How much input token was taken to swap exactOutput
            // swapResult always negative for input token. So we inverse it.
            uint256 inputTokenAmount = uint128(-(swapParams.zeroForOne ? swapResult.amount0() : swapResult.amount1()));
            // feeAmount = totalInput * fee%
            uint256 feeAmount = inputTokenAmount * lpFee.removeOverrideFlag() / LPFeeLibrary.MAX_LP_FEE;

            Currency currency = swapParams.zeroForOne ? poolKey.currency0 : poolKey.currency1;
            debtor.issueDebt(currency, feeAmount, refundTo);

            return (BaseHook.afterSwap.selector, 0);
        } else if (!feeOnInput && swapParams.IsExactInput()) {
            uint256 outputTokenAmount = uint128(swapParams.zeroForOne ? swapResult.amount1() : swapResult.amount0());
            // if fee is 0.3%. then swapResult for input here already include 0.3% fee.
            uint256 feeAmount = outputTokenAmount * lpFee.removeOverrideFlag() / LPFeeLibrary.MAX_LP_FEE;

            Currency currency = swapParams.zeroForOne ? poolKey.currency1 : poolKey.currency0;
            debtor.issueDebt(currency, feeAmount, refundTo);

            //@dev must call poolManager.donate() right after swap to move fee from Hook to Position
            //user output reduced by fee amount
            //fee earned is on hook account balance
            return (BaseHook.afterSwap.selector, feeAmount.toInt128());
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    ///@notice called by router inside swap callback. To move fee from hook to pool. Only for take fee on output token
    ///@dev UniswapV4 still in early development. Router do not have Post final swap callback yet. So this should be called by custom router after swap callback
    ///@dev Current dumb solution is trigger `hook.afterDonate()` inside router by donate() ZERO amount.
    function postHookSwap(PoolKey calldata poolKey) external {
        _donateAll(poolKey);
    }

    function afterDonate(address sender, PoolKey calldata poolKey, uint256 amount0, uint256 amount1, bytes calldata)
        external
        override
        returns (bytes4)
    {
        //prevent infinite loop
        if (sender != address(this) && amount0 == 0 && amount1 == 0) {
            _donateAll(poolKey);
        }
        return BaseHook.afterDonate.selector;
    }

    function _donateAll(PoolKey calldata poolKey) internal {
        int256 amount0 = poolManager.currencyDelta(address(this), poolKey.currency0);
        int256 amount1 = poolManager.currencyDelta(address(this), poolKey.currency1);
        //@dev no safecast seem ok, pool revert on wrong balance accounting. Since this only move all Hook balance to our own Position
        poolManager.donate(poolKey, uint256(amount0), uint256(amount1), new bytes(0));
    }
}
