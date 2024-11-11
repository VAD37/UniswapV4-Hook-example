// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {Owned} from "solmate/src/auth/Owned.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/erc20/ERC20.sol";

///@notice A simplified fixed interest rate token based on Compound Finance. Do not use in production.
///@dev balanceOf use debasing value (present value upscale from principal value). Transfer modified to allow transfer over limit.
///@dev one of known issue with accrued index is if interest rate is 10% per year. If call accrrue aggresively, the final total value after interest is offset by ~0.5% at the end of year. Result in ~10.5%.
///@dev accrued here was not called every transacion as in Compound. Unless someone want to. This is gas saving measure. Resulting in user not benefit from actual compound curve interest.
contract BankToken is Owned, ERC20 {
    using Math for uint256;

    uint8 decimal;

    uint256 public index;
    uint256 public lastAccrualTime;
    uint256 public supplyRate;

    uint256 public constant MAX_RATE = 1e18; //100% APY
    uint256 public constant BASE_INDEX = 1e18;
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    constructor(address _owner, string memory _name, string memory _symbol, uint8 _decimals)
        Owned(_owner)
        ERC20(_name, _symbol)
    {
        lastAccrualTime = block.timestamp;
        index = BASE_INDEX;
        require(_decimals <= 18 && _decimals >= 6, "Weird ERC20");
        decimal = _decimals;
    }
    /* MODIFIED ERC20 */

    function decimals() public view override returns (uint8) {
        return decimal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return presentValue(super.balanceOf(account));
    }

    function balancePrincipalOf(address account) public view returns (uint256) {
        return super.balanceOf(account);
    }

    function totalSupply() public view override returns (uint256) {
        return presentValue(super.totalSupply());
    }

    function totalPrincipalSupply() public view returns (uint256) {
        return super.totalSupply();
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        if (amount > super.balanceOf(msg.sender)) {
            amount = super.balanceOf(msg.sender);
        }
        return super.transfer(recipient, amount);
    }

    /* BANK FUNCTION */

    function mint(address account, uint256 amount) public onlyOwner {
        // accrue();
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) public onlyOwner {
        // accrue();
        _burn(account, amount);
    }

    function updateInterestRate(uint256 newInterestRate) public onlyOwner {
        require(newInterestRate <= MAX_RATE, "rate too high");
        accrue();
        supplyRate = newInterestRate / SECONDS_PER_YEAR;
    }

    function accrue() public {
        uint256 currentTime = block.timestamp;
        uint256 timeDelta = currentTime - lastAccrualTime;
        // if (timeDelta == 0) return;
        index += (index * supplyRate * timeDelta) / BASE_INDEX;
        lastAccrualTime = currentTime;
    }

    function currentIndex() public view returns (uint256) {
        uint256 timeDelta = block.timestamp - lastAccrualTime;
        uint256 interest = (index * supplyRate * timeDelta) / BASE_INDEX;
        return index + interest;
    }

    function presentValue(uint256 _principalValue) public view returns (uint256) {
        return (_principalValue * currentIndex()) / BASE_INDEX;
    }

    function principalValue(uint256 _presentValue) public view returns (uint256) {
        return (_presentValue * BASE_INDEX) / currentIndex();
    }
}
