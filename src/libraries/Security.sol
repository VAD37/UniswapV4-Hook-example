// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

interface IDoor {
    function unlock(uint256 unlockTier) external;
    function lock() external;
    function isLocked() external view returns (bool);
}

/// @notice Library to define list of Security Level
library Security {
    // Basic config
    uint256 constant BASIC = 0xc0ffee; // 12648430 Number big enough to avoid confusion

    function unlock(address target, uint256 lv) internal {
        IDoor(target).unlock(lv);
    }

    function lock(address target) internal {
        IDoor(target).lock();
    }
    function isLocked(address target) internal view returns (bool) {
        return IDoor(target).isLocked();
    }
}
