// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {Owned} from "solmate/src/auth/Owned.sol";
import {SafeTransferLib, ERC20} from "solmate/src/utils/SafeTransferLib.sol";
// import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {BankToken} from "./BankToken.sol";
import {Hook} from "./Hook.sol";
import {CurrencyLibrary, Currency} from "lib/v4-core/src/types/Currency.sol";
import "./libraries/Security.sol";
import {SafeCallback, IPoolManager} from "lib/v4-periphery/src/base/SafeCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

///@notice A simple, practical Dapp to showcase how Uniswap Hook could be used.
///@dev Bank do not control its own private pool position. Bank receive all fee generated from pool. Owner handle all pool position related operation.
///@dev At all times, Bank must always have surplus of currency to repay debt to user. So investment > debt.
///@dev All fee generated from the pool belong to user and it is count as bank debt. Bank temporary hold the fee and reinvest it to lending activity.
///@dev Bank have obligation to repay user debt if they want to reclaim at any time. The only fee user inccur are gas cost.
///@dev Bank token internally provide fixed interest rate. So whatever bank do with money should always return more than what user gain.
contract SimpleBank is Owned, SafeCallback {
    using Security for address;
    using SafeTransferLib for ERC20;

    event NewCurrency(Currency currency, BankToken token);
    event Claimed(address user, Currency currency, uint256 amount);

    // local config per token
    struct TokenConfig {
        BankToken bToken;
    }

    mapping(Currency => TokenConfig) public configs;
    Currency[] public currencyLists;

    //Hook address
    address public hook;

    constructor(address _owner, IPoolManager _poolmanager) Owned(_owner) SafeCallback(_poolmanager) {}

    /* ADMIN OPERATION */

    ///@notice Minter is hook to create new debt
    function setMinter(address _minter) public onlyOwner {
        hook = _minter;
    }

    function addToken(Currency currency, uint256 apyRate) public onlyOwner {
        require(address(configs[currency].bToken) == address(0), "Currency already exist");
        TokenConfig storage config = configs[currency];
        currencyLists.push(currency);

        ERC20 metadata = ERC20(Currency.unwrap(currency));
        string memory name = string(abi.encodePacked("BB ", metadata.name())); //random nonsense
        string memory symbol = string(abi.encodePacked("b", metadata.symbol()));
        uint8 decimals = metadata.decimals();

        BankToken bToken = new BankToken(address(this), name, symbol, decimals);

        config.bToken = bToken;
        bToken.updateInterestRate(apyRate);

        emit NewCurrency(currency, bToken);
    }

    ///@notice Bank do not care about Pool, Positions, or any other Uniswap related stuff.It only handle debt and repayment to user.
    ///All currency inside Position belong to owner. Fee generated belong to the bank.
    function initNewPool(PoolKey calldata key, uint160 sqrtPriceX96) public onlyOwner {
        hook.unlock(Security.BASIC);
        poolManager.initialize(key, sqrtPriceX96);
        require(hook.isLocked(), "should be locked after initializePool operation completed");
    }

    function modifyPoolLiquidity(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) public payable onlyOwner {
        hook.unlock(Security.BASIC);
        uint256 ethReceive = msg.value;
        poolManager.unlock(abi.encode(key, params, hookData, ethReceive));
        require(hook.isLocked(), "should be locked after modifyLiquidity operation completed");
    }

    ///TODO: change callback so it similar to actions router.

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        (
            PoolKey memory key,
            IPoolManager.ModifyLiquidityParams memory params,
            bytes memory hookData,
            uint256 ethReceive
        ) = abi.decode(data, (PoolKey, IPoolManager.ModifyLiquidityParams, bytes, uint256));
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(key, params, hookData);

        // keep all positive fee belong to user here. PoolManager always return positive feesAccrued
        poolManager.take(key.currency0, address(this), uint128(feesAccrued.amount0()));
        poolManager.take(key.currency1, address(this), uint128(feesAccrued.amount1()));
        // the rest is pool liquidation change. belong to sender/owner.
        callerDelta = callerDelta - feesAccrued;

        _settleForOwner(key.currency0, callerDelta.amount0(), ethReceive);
        _settleForOwner(key.currency1, callerDelta.amount1(), ethReceive);
    }

    ///@notice settle/take currency back/from to owner. Based on `CurrencySettler.sol`. Only for liquidity control.
    function _settleForOwner(Currency currency, int128 amount, uint256 ethReceive) internal {
        // positive balance mean withdraw, negative mean deposit from owner to PoolManager
        if (amount > 0) {
            poolManager.take(currency, owner, uint128(amount));
        } else if (amount < 0) {
            if (currency.isAddressZero()) {
                require(uint128(-amount) == ethReceive, "ETH amount mismatch");
                poolManager.settle{value: ethReceive}();
            } else {
                poolManager.sync(currency);
                ERC20(Currency.unwrap(currency)).safeTransferFrom(owner, address(poolManager), uint128(-amount));
                poolManager.settle();
            }
        }
    }

    /* HOOK */
    function issueDebt(Currency currency, uint256 amount, address toUser) public {
        TokenConfig storage config = configs[currency];

        require(msg.sender == hook, "Only minter can create debt");
        require(address(config.bToken) != address(0), "Currency not supported");

        BankToken token = config.bToken;

        uint256 principal = token.principalValue(amount);
        token.mint(toUser, principal);
    }

    /* USER */

    ///@notice no option for partial withdraw as intended for simpler design. If bank failed and run out of cash, last person will failed to withdraw. This can be remedy by flashloan and then transfer token to bank and reclaim left over.
    ///@dev there is no internal enumeration for possible pool to withdraw from.
    ///Offchain read all pools with available fee and pass in best pool with highest available fee to withdraw. If failed then withdraw from Investment Pool
    function reclaim(Currency currency) public {
        TokenConfig storage config = configs[currency];

        require(address(config.bToken) != address(0), "Currency not supported");

        BankToken token = config.bToken;

        address user = msg.sender;
        uint256 principal = token.balancePrincipalOf(user);
        uint256 presentValue = token.presentValue(principal);
        token.burn(msg.sender, principal);

        // make sure there is enough reserve to withdraw
        prepareCashReserve(currency, presentValue);

        currency.transfer(user, presentValue);

        emit Claimed(user, currency, presentValue);
    }

    /* OFFCHAIN BOT */
    function batchReclaim() public {
        //TODO: custom permit signature to approce Bank reclaim on user behalf and take some fixed fee from user. This is for gas effiency, on mainnet.
        //If use ERC20 permit, it still use nonce storage, here both user, bank only care about single reclaim within few hours.
    }

    /* INTERNAL */
    function prepareCashReserve(Currency currency, uint256 amount) internal {
        //check current balance
        uint256 reservesNow = currency.balanceOfSelf();
        if (reservesNow >= amount) return;
        // withdraw fee from pool. Didnt check if pool have empty fee or not. just withdraw
        // call modifyLiquidity with zero liquidity here.
    }

    receive() external payable {}

    /* LENS */
}
