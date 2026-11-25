// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AevumPay} from "../src/AevumPay.sol";

/// @notice Deploy AevumPay to Aevum testnet (chain 44005) or a local fork.
/// @dev Aevum needs legacy (type 0) transactions: run with --legacy.
/// Example (testnet):
///   forge script script/Deploy.s.sol --rpc-url https://rpc-test.qday.info \
///     --broadcast --legacy --private-key $DEPLOYER_KEY
/// Example (local fork on 127.0.0.1:8555):
///   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8555 \
///     --broadcast --legacy --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f3ff80
contract Deploy is Script {
    address public constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function run() external {
        address token = TUSD8;
        try vm.envAddress("TUSD8") returns (address v) {
            token = v;
        } catch {}

        vm.startBroadcast();
        AevumPay pay = new AevumPay(token);
        vm.stopBroadcast();

        console.log("AevumPay deployed at:", address(pay));
        console.log("tUSD8 token:        ", token);
        console.log("chain id:           ", block.chainid);
    }
}
