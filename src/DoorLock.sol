// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.28;

import {Owned} from "solmate/src/auth/Owned.sol";

/**
 * @notice Follow Uniswap Pool unlock callback pattern.
 * @dev Rely on transient storage and multicall. Owner open/close permission for single transaction.
 * @dev Made exclusively to deal with UniswapV4 Position. This is "Extreme" flawed security design. Meant for special use case only.
 * Allowing external contract call interaction freely without worried about who is the caller.
 * It require explicit from owner to accept any interaction.
 * Reentrancy attack from ERC20 token is primary security concern.
 */
contract DoorLock is Owned {
    uint transient unlockedKey;

    error UnauthorizedAccess(uint current, uint required);
    error AlreadyUnlocked();

    constructor(address _owner) Owned(_owner) {
        
    }

    function unlock(uint unlockTier) public onlyOwner {
        if(unlockTier == 0 || unlockTier == unlockedKey) {
            revert AlreadyUnlocked();
        }
        unlockedKey = unlockTier;
    }

    function lock() public onlyOwner {
        _lock();
    }
    function _lock() internal {
        unlockedKey = 0;
    }

    function _checkSecurity(uint key) internal view {
        if(key != unlockedKey) {
            revert UnauthorizedAccess(unlockedKey,key);
        }
    }
    function _checkSecurityAndLock(uint key) internal {
        if(key != unlockedKey) {
            revert UnauthorizedAccess(unlockedKey,key);
        }
        _lock();
    }
    function isLocked() public view returns (bool) {
        return unlockedKey == 0;
    }
}
