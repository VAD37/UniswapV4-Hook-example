// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

// struct HookParams {
//     bool feeOnInput;
//     uint24 lpFee;
//     address refundTo;
// }

library HookLibrary {
    ///@notice by default allow all caller with unsupported data to swap with zero fee.
    ///@dev ignore empty data allow bot miner to swap and maintain pool price
    ///@dev if invalid data return lpFee with zero fee. zero fee bypass all swap logic
    function softParse(bytes calldata hookData)
        internal
        pure
        returns (bool feeOnInput, uint24 lpFee, address refundTo)
    {
        //abi.encodePacked(bool,uint24,address) = 1+3+20 = 24 bytes
        if (hookData.length != 24) {
            return (false, 0, address(0));
        }
        //@dev unsure about IR gas efficient
        feeOnInput = bytes1(hookData) == 0x01;
        lpFee = uint24((bytes3(hookData[1:4])));
        refundTo = address(bytes20(bytes32(hookData[4:24])));
    }

    //@dev not possible to have zero swap amount
    function IsExactInput(IPoolManager.SwapParams calldata params) internal pure returns (bool) {
        return params.amountSpecified < 0;
    }

    function IsExactOutput(IPoolManager.SwapParams calldata params) internal pure returns (bool) {
        return params.amountSpecified > 0;
    }

    /* HELPER */
    function bpsToLPFee(uint16 bps) internal pure returns (uint24) {
        if (bps > 10000) {
            bps = 10000;
        }
        return (uint24(bps) * 100) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    function toLPFee(uint24 bip) internal pure returns (uint24) {
        return uint24((bip & 0x0FFFFF)  | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function packHookData(bool feeOnInput, uint24 feeBps, address refundTo)
        internal
        pure
        returns (bytes memory hookData)
    {
        return abi.encodePacked(feeOnInput, feeBps, refundTo);
    }
}
