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
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {PositionConfig, FeeMath} from "v4-periphery/test/shared/FeeMath.sol";
import {Quoter, IQuoter} from "v4-periphery/src/lens/Quoter.sol";

import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

import "src/Hook.sol";
import "./Helper.sol";

contract HookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    Hook hook;

    PoolId poolId;
    PositionConfig mainPosKey;
    Quoter quoter;

    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    address user = address(0xCAfE2290dD7278aa3DDD389Cc1E1d165cC4BCafE);
    address owner = address(this);

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens,quoter lens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);
        quoter = new Quoter(manager);

        // Deploy the hook to an address with the correct flags
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(owner, manager); //Add all the necessary constructor arguments from the hook
        deployCodeTo("Hook.sol:Hook", constructorArgs, flags);
        hook = Hook(flags);
        //tell hook to unlock permission first before Add new liquidity
        hook.unlock(Security.BASIC);

        // Create the pool
        uint24 fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
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

        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
        mainPosKey = PositionConfig({poolKey: key, tickLower: tickLower, tickUpper: tickUpper});

        // lock admin permission after setup done
        hook.lock();

        // send token to user
        seedBalance(user); //10_000_000e18
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

    /* HELPER */
    function parseAndUnpack(bytes calldata data)
        public
        pure
        returns (bool feeOnInput, uint24 feeBps, address refundTo)
    {
        (feeOnInput, feeBps, refundTo) = HookLibrary.softParse(data);
    }

    function _printOwnedFee() private view {
        BalanceDelta feesOwed = FeeMath.getFeesOwed(posm, manager, mainPosKey, tokenId);
        console.log("feesOwedAmount0: %e", feesOwed.amount0());
        console.log("feesOwedAmount1: %e", feesOwed.amount1());
    }

    function _printStartingBalance() private view {
        console.log("userToken0Balance: %e", currency0.balanceOf(user));
        console.log("userToken1Balance: %e", currency1.balanceOf(user));
    }

    function _printDebug(BalanceDelta swapDelta) private view {
        console.log("deltaAmount0: %e", swapDelta.amount0());
        console.log("deltaAmount1: %e", swapDelta.amount1());

        console.log("userToken0Balance: %e", currency0.balanceOf(user));
        console.log("userToken1Balance: %e", currency1.balanceOf(user));
    }

    /* LIBRARY */
    function testFlagConversion() public pure {
        assertEq(Helper.toLPFee(50), 0x400032);
        assertEq(Helper.toLPFee(9900), 0x4026ac);
        assertEq(Helper.toLPFee(64136), 0x40fa88);

        assertEq(Helper.toLPFee(0x0fffff), 0x4fffff);
        assertEq(Helper.toLPFee(0xf44444), 0x444444);
        assertEq(Helper.toLPFee(0xa12345), 0x412345);
    }

    function test_fuzz_decode_hookdata(bool isInput, uint24 feeLP, address target) public view {
        bytes memory data = Helper.packHookData(isInput, feeLP, target);

        (bool feeOnInput, uint24 feeBps, address refundTo) = HookTest(payable(address(this))).parseAndUnpack(data);
        assertEq(feeOnInput, isInput);
        assertEq(feeBps, feeLP);
        assertEq(refundTo, target);
    }

    /* HOOK SWAP */

    function testSwapExactInputA_Hook_FeeInput() public {
        vm.startPrank(user);
        _printStartingBalance();
        bool zeroForOne = true;
        int256 amountSpecified = -5_000_000e18;
        uint24 feeLP = 50000; //5%
        bool feeOnInput = true;
        uint256 expectedFee =
            FullMath.mulDivRoundingUp(uint256(-amountSpecified), uint256(feeLP), uint256(LPFeeLibrary.MAX_LP_FEE));

        console.log("swap 5% inputFee from token0 to token1. ExactInput: %e ", amountSpecified);

        bytes memory data = Helper.packHookData(feeOnInput, Helper.toLPFee(feeLP), user);
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, data);

        _printDebug(swapDelta);
        _printOwnedFee();

        BalanceDelta feesOwed = FeeMath.getFeesOwed(posm, manager, mainPosKey, tokenId);

        assertEq(int256(swapDelta.amount0()), amountSpecified);
        assertGt(feesOwed.amount0(), 0, "fee not collected on token0");
        assertApproxEqAbs(uint256(int256(feesOwed.amount0())), expectedFee, 1, "fee earned not equal to expectation");
        vm.stopPrank();
    }

    function testSwapExactInputB_Hook_FeeInput() public {
        vm.startPrank(user);
        _printStartingBalance();
        bool zeroForOne = false;
        int256 amountSpecified = -5_000_000e18;
        uint24 feeBip = 50000; //5%
        bool feeOnInput = true;
        uint256 expectedFee =
            FullMath.mulDivRoundingUp(uint256(-amountSpecified), uint256(feeBip), uint256(LPFeeLibrary.MAX_LP_FEE));
        console.log("swap 5% inputFee from token1 to token0. ExactInput: %e ", amountSpecified);

        bytes memory data = Helper.packHookData(feeOnInput, Helper.toLPFee(feeBip), user);
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, data);

        _printDebug(swapDelta);
        _printOwnedFee();

        BalanceDelta feesOwed = FeeMath.getFeesOwed(posm, manager, mainPosKey, tokenId);

        assertEq(int256(swapDelta.amount1()), amountSpecified);
        assertGt(feesOwed.amount1(), 0, "fee not collected on token0");
        assertApproxEqAbs(uint256(int256(feesOwed.amount1())), expectedFee, 1, "fee earned not equal to expectation");
        vm.stopPrank();
    }

    function testSwapExactOutputA_Hook_FeeInput() public {
        vm.startPrank(user);
        _printStartingBalance();
        bool zeroForOne = true;
        int256 amountSpecified = 5_000_000e18;
        uint24 lpFee = 50000; //5%
        bool feeOnInput = true;
        bytes memory data = Helper.packHookData(feeOnInput, Helper.toLPFee(lpFee), user);
        //use Quoter to get inputAmount without fee. Then calculate expected Input + fee
        (uint256 amountIn, uint256 gasEstimate) = quoter.quoteExactOutputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                exactAmount: uint128(uint256(amountSpecified)),
                hookData: ZERO_BYTES //free swap with no fee
            })
        );
        // fee = amountIn_withoutfee * fee% / (100% - fee%)
        uint256 expectedFee = amountIn * lpFee  / (LPFeeLibrary.MAX_LP_FEE - lpFee);
        console.log("quote swap without fee. amountIn: %e", amountIn);
        console.log("predict inputFee: %e", expectedFee);

        console.log("swap 5% inputFee from token0 to token1. ExactOutput %e token1", amountSpecified);
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, data);

        _printDebug(swapDelta);
        _printOwnedFee();

        BalanceDelta feesOwed = FeeMath.getFeesOwed(posm, manager, mainPosKey, tokenId);

        assertEq(int256(swapDelta.amount1()), amountSpecified);
        assertGt(feesOwed.amount0(), 0, "fee not collected on token0");
        assertApproxEqAbs(uint256(int256(feesOwed.amount0())), expectedFee, 1, "fee earned not equal to expectation");
        vm.stopPrank();
    }

    function testSwapExactOutputB_Hook_FeeInput() public {
        vm.startPrank(user);
        _printStartingBalance();
        bool zeroForOne = false;
        int256 amountSpecified = 5_000_000e18;
        uint24 lpFee = 50000; //5%
        bool feeOnInput = true;
        bytes memory data = Helper.packHookData(feeOnInput, Helper.toLPFee(lpFee), user);
        //use Quoter to get inputAmount without fee. Then calculate expected Input + fee
        (uint256 amountIn, uint256 gasEstimate) = quoter.quoteExactOutputSingle(
            IQuoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                exactAmount: uint128(uint256(amountSpecified)),
                hookData: ZERO_BYTES //free swap with no fee
            })
        );
        // fee = amountIn_withoutfee * fee% / (100% - fee%)
        uint256 expectedFee = amountIn * lpFee  / (LPFeeLibrary.MAX_LP_FEE - lpFee);
        console.log("quote swap without fee. amountIn: %e", amountIn);
        console.log("predict inputFee: %e", expectedFee);

        console.log("swap 5% inputFee from token1 to token0. ExactOutput %e token0", amountSpecified);
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, data);

        _printDebug(swapDelta);
        _printOwnedFee();

        BalanceDelta feesOwed = FeeMath.getFeesOwed(posm, manager, mainPosKey, tokenId);

        assertEq(int256(swapDelta.amount0()), amountSpecified);
        assertGt(feesOwed.amount1(), 0, "fee not collected on token0");
        assertApproxEqAbs(uint256(int256(feesOwed.amount1())), expectedFee, 1, "fee earned not equal to expectation");
        vm.stopPrank();
    }

    function testSwapExactInputA_Hook_NoFee() public {
        vm.startPrank(user);
        _printStartingBalance();
        bool zeroForOne = true;
        int256 amountSpecified = -5_000_000e18;
        console.log("swap token0 to token1. ExactInput: %e ", amountSpecified);

        bytes memory data = Helper.packHookData(false, 0, user);
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, data);

        _printDebug(swapDelta);
        _printOwnedFee();

        assertEq(int256(swapDelta.amount0()), amountSpecified);
        vm.stopPrank();
    }

    function testSwapExactInputA_EmptyHook() public {
        vm.startPrank(user);
        _printStartingBalance();
        bool zeroForOne = true;
        int256 amountSpecified = -5_000_000e18;
        console.log("swap token0 to token1. ExactInput: %e ", amountSpecified);

        bytes memory data = ZERO_BYTES;
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, data);

        _printDebug(swapDelta);

        assertEq(int256(swapDelta.amount0()), amountSpecified);
        vm.stopPrank();
    }

    /* NORMAL SWAP */

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
}
