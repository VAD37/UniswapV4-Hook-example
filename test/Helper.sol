// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {stdMath} from "forge-std/StdMath.sol";

///@notice for Test and peripheral use only
library Helper {
    function bpsToLPFee(uint16 bps) internal pure returns (uint24) {
        if (bps > 10000) {
            bps = 10000;
        }
        return (uint24(bps) * 100) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    function toLPFee(uint24 bip) internal pure returns (uint24) {
        return uint24((bip & 0x0FFFFF) | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    ///@notice if user want specific outputAmount with fee on output, calculate exactOutputAmount include fee so Hook will return exact specified amount to user after swap
    ///@dev if user want 5000 token and 5% fee. exactOutput pass to router should be ~5263.1579 token. So swap result after fee will return exact 5000 token as user want
    function getExactOutputWithFee(uint24 feeLP, uint256 specifiedOutputAmount)
        internal pure
        returns (uint256 exactOutputAmount, uint256 fee)
    {
        // fee = specified * fee% / (100% - fee%)
        fee = (specifiedOutputAmount * feeLP / LPFeeLibrary.MAX_LP_FEE) / (LPFeeLibrary.MAX_LP_FEE - feeLP);
        exactOutputAmount = specifiedOutputAmount + fee;
    }

    function packHookData(bool feeOnInput, uint24 feeBps, address refundTo)
        internal
        pure
        returns (bytes memory hookData)
    {
        return abi.encodePacked(feeOnInput, feeBps, refundTo);
    }
}
