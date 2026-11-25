// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

/// @notice Dev utility: finds the storage slot of tUSD8's `balances` mapping
/// on a fork, so the live anvil fork can be funded with anvil_setStorageAt.
/// (Foundry's `deal` cheatcode does not persist to a remote anvil node when
/// used inside a broadcast script, so we set the storage directly.)
contract SlotFinderTest is Test {
    address public constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function testFindBalanceSlot() public {
        string memory rpcUrl = "https://rpc-test.qday.info";
        try vm.envString("AEVUM_RPC_URL") returns (string memory v) {
            rpcUrl = v;
        } catch {}
        vm.createSelectFork(rpcUrl);

        address probe = address(0x1234567890123456789012345678901234567890);
        uint256 sentinel = 123456789;
        deal(TUSD8, probe, sentinel);
        for (uint256 slot = 0; slot < 20; slot++) {
            bytes32 key = keccak256(abi.encode(probe, slot));
            bytes32 value = vm.load(TUSD8, key);
            if (uint256(value) == sentinel) {
                console.log("tUSD8 balances mapping slot:", slot);
                return;
            }
        }
        revert("slot not found in 0..20");
    }
}
