// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

import {Hook} from "src/Hook.sol";

contract HookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Hook hook;

    PoolId poolId;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    address user = address(0xcafe);

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        //@create Hook to Anvil

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(address(this), manager); //Add all the necessary constructor arguments from the hook
        deployCodeTo("Hook.sol:Hook", constructorArgs, flags);
        hook = Hook(flags);

        // Create the pool
        uint24 fee = 3000;
        key = PoolKey(currency0, currency1, fee, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 100_000_000e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        // console.log("Pool token balance. amount0: %e, amount1: %e", amount0Expected, amount1Expected);

        bytes memory unlockSignature = abi.encode(bytes32(uint256(0x1337)));

        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            unlockSignature
        );
        // send token to user

        seedBalance(user); //10_000_000e18
        // seedBalance(address(magic)); //10_000_000e18
        approvePosmFor(user);

        // user approve all the routers
        vm.startPrank(user);
        address[10] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter),
            address(manager)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            MockERC20(Currency.unwrap(currency0)).approve(toApprove[i], type(uint256).max);
            MockERC20(Currency.unwrap(currency1)).approve(toApprove[i], type(uint256).max);
        }
        vm.stopPrank();
    }

    function testSwapExactInputA() public {
        vm.startPrank(user);
        _printStartingBalance();
        bool zeroForOne = true;
        int256 amountSpecified = -5_000_000e18;
        console.log("swap token0 to token1. ExactInput: %e ", amountSpecified);
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        _printDebug(swapDelta);

        assertEq(int256(swapDelta.amount0()), amountSpecified);
        vm.stopPrank();
    }

    function testSwapExactInputB() public {
        vm.startPrank(user);
        _printStartingBalance();
        bool zeroForOne = false;
        int256 amountSpecified = -10_000_000e18;
        console.log("swap token1 to token0. ExactInput: %e ", amountSpecified);
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        _printDebug(swapDelta);

        assertEq(int256(swapDelta.amount1()), amountSpecified);

        vm.stopPrank();
    }

    function testSwapExactOutputA() public {
        vm.startPrank(user);
        _printStartingBalance();
        bool zeroForOne = true;
        int256 amountSpecified = 8_000_000e18;
        console.log("swap token0 to token1. ExactOutput: %e ", amountSpecified);
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        _printDebug(swapDelta);

        assertEq(int256(swapDelta.amount1()), amountSpecified);
        vm.stopPrank();
    }

    function testSwapExactOutputB() public {
        vm.startPrank(user);
        _printStartingBalance();
        bool zeroForOne = false;
        int256 amountSpecified = 8_000_000e18;
        console.log("swap token1 to token0. ExactOutput: %e ", amountSpecified);
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);
        _printDebug(swapDelta);

        assertEq(int256(swapDelta.amount0()), amountSpecified);
        vm.stopPrank();
    }

    function _printStartingBalance() private {
        console.log("userToken0Balance: %e", currency0.balanceOf(user));
        console.log("userToken1Balance: %e", currency1.balanceOf(user));
    }

    function _printDebug(BalanceDelta swapDelta) private {
        console.log("deltaAmount0: %e", swapDelta.amount0());
        console.log("deltaAmount1: %e", swapDelta.amount1());

        console.log("userToken0Balance: %e", currency0.balanceOf(user));
        console.log("userToken1Balance: %e", currency1.balanceOf(user));
    }
}
