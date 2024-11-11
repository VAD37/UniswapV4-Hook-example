// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import "src/BankToken.sol";

contract TokenTest is Test {
    BankToken token;
    uint256 startTime = block.timestamp;

    function setUp() public {
        token = new BankToken(address(this), "Test Token", "TST", 6);
        token.updateInterestRate(0.10e18); // 1% per year
    }

    function testCompound() public {
        uint256 value = 6e6;

        console.log("present: %e", token.presentValue(value));
        console.log("principle: %e", token.principalValue(value));
        //total time is 365 days
        uint count = 350000;
        uint split = 31_536_000 / count;
        for (uint256 i = 0; i < count; i++) {
            vm.warp(startTime + i * split);
            token.accrue();
        }

        vm.warp(startTime + 365 days);
        token.accrue();
        console.log("index: ", token.index());
        console.log("present: %e", token.presentValue(value));
        console.log("principle: %e", token.principalValue(value));

        console.log(block.timestamp);
    }

    function testCompound2() public {
        uint256 value = 6e6;
        console.log("present: %e", token.presentValue(value));
        console.log("principle: %e", token.principalValue(value));

        vm.warp(startTime + 365 days);
        token.accrue();
        console.log("index: ", token.index());
        console.log("present: %e", token.presentValue(value));
        console.log("principle: %e", token.principalValue(value));

        console.log(block.timestamp);
    }
}
