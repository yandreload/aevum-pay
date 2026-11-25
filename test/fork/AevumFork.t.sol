// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AevumPay} from "../../src/AevumPay.sol";

/// @notice Minimal view of the real tUSD8 needed for fork tests.
interface IRealTUSD8 {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
}

/// @notice Fork tests: the same flows as the unit tests, but against the REAL
/// tUSD8 contract on a local fork of Aevum testnet (chain 44005).
/// Run with: forge test --fork-url https://rpc-test.qday.info --match-path test/fork/*
contract AevumForkTest is Test {
    address public constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    AevumPay public pay;
    IRealTUSD8 public token;

    address public merchant = makeAddr("merchant");
    uint256 public buyerKey = 0xB0B;
    address public buyer;
    address public relayer = makeAddr("relayer");

    uint256 public constant AMOUNT = 2_500_000; // 2.50 tUSD8 (6 decimals)

    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    function setUp() public {
        // Fork URL comes from AEVUM_RPC_URL so CI can point at a local relay.
        // The QDay RPC drops TLS connections without close_notify, which
        // Foundry's rustls stack rejects; tools/rpc-relay.mjs works around it.
        string memory rpcUrl = "https://rpc-test.qday.info";
        try vm.envString("AEVUM_RPC_URL") returns (string memory v) {
            rpcUrl = v;
        } catch {}
        vm.createSelectFork(rpcUrl);
        token = IRealTUSD8(TUSD8);
        pay = new AevumPay(TUSD8);
        buyer = vm.addr(buyerKey);
        // Give the buyer real tUSD8 on the fork (local state only).
        deal(TUSD8, buyer, 100_000_000);
        assertEq(token.balanceOf(buyer), 100_000_000);
    }

    function testForkPayStandard() public {
        vm.prank(merchant);
        uint256 linkId = pay.createLink(AMOUNT, "Fork demo: kopi untuk agent", 1 days, address(0));

        vm.prank(buyer);
        token.approve(address(pay), AMOUNT);
        vm.prank(buyer);
        pay.pay(linkId);

        assertEq(token.balanceOf(merchant), AMOUNT);
        (,,,,, bool paid, address payer) = pay.paymentOf(linkId);
        assertTrue(paid);
        assertEq(payer, buyer);
    }

    function testForkPayGaslessRealTUSD8() public {
        vm.prank(merchant);
        uint256 linkId = pay.createLink(AMOUNT, "Fork demo gasless: kopi untuk agent", 1 days, address(0));

        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = pay.authorizationNonce(linkId);
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, buyer, address(pay), AMOUNT, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        pay.payWithAuthorization(linkId, buyer, validAfter, validBefore, sig);

        assertEq(token.balanceOf(merchant), AMOUNT);
        assertTrue(token.authorizationState(buyer, nonce));
        (,,,,, bool paid, address payer) = pay.paymentOf(linkId);
        assertTrue(paid);
        assertEq(payer, buyer);
    }
}
