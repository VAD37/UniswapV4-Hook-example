// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import {Owned} from "solmate/src/auth/Owned.sol";

/**
 * @notice Follow Uniswap Pool unlock callback pattern.
 * @dev Rely on transient storage and multicall. Owner open/close permission for single transaction.
 * @dev This is "Extreme" flawed security design. Meant for special use case only.
 * Made implicit for allowing external contract call interaction without worriying about permission. Like `PositionManager.sol`
 * Admin must be contract handle multicall like gnosis safe.
 * Reentrancy attack from ERC20 token is primary security concern. All external call to trusted contract should be safe.
 */
contract DoorLock is Owned {
    uint transient unlockedLevel;

    error UnauthorizedAccess(uint current, uint required);
    error AlreadyUnlocked();

    constructor(address _owner) Owned(_owner) {
        
    }

    function Unlock(uint unlockTier) public onlyOwner {
        if(unlockTier == 0 || unlockTier <= unlockedLevel) {
            revert AlreadyUnlocked();   
        }
        unlockedLevel = unlockTier;
    }

    function Lock() public onlyOwner {
        unlockedLevel = 0;
    }

    function _checkSecurity(uint requiredLevel) internal view {
        if(requiredLevel > unlockedLevel) {
            revert UnauthorizedAccess(unlockedLevel,requiredLevel);
        }
    }
}
