// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AevumPay} from "../src/AevumPay.sol";
import {MockUSD8} from "../src/MockUSD8.sol";

/// @notice Unit tests for AevumPay against a local mock of tUSD8.
/// The fork tests in test/fork run the same flows against the real tUSD8.
contract AevumPayTest is Test {
    AevumPay public pay;
    MockUSD8 public token;

    address public merchant = makeAddr("merchant");
    address public buyer = makeAddr("buyer");
    address public relayer = makeAddr("relayer");
    uint256 public buyerKey = 0xB0B;
    address public agent = makeAddr("agent");

    uint256 public constant AMOUNT = 2_500_000; // 2.50 tUSD8 (6 decimals)

    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    function setUp() public {
        token = new MockUSD8();
        pay = new AevumPay(address(token));
        buyer = vm.addr(buyerKey);
        token.mint(buyer, 100_000_000); // 100 tUSD8
        token.mint(merchant, 0);
    }

    // ---- helpers ----

    function _createLink() internal returns (uint256 linkId) {
        vm.prank(merchant);
        linkId = pay.createLink(AMOUNT, "Demo: kopi untuk agent", 1 days, address(0));
    }

    function _signAuthorization(uint256 linkId, uint256 validAfter, uint256 validBefore)
        internal
        view
        returns (bytes memory signature)
    {
        bytes32 nonce = pay.authorizationNonce(linkId);
        bytes32 structHash = keccak256(
            abi.encode(RECEIVE_WITH_AUTHORIZATION_TYPEHASH, buyer, address(pay), AMOUNT, validAfter, validBefore, nonce)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    // ---- agent registry ----

    function testRegisterAgent() public {
        vm.prank(agent);
        pay.registerAgent("kopi-agent");
        assertEq(pay.agentName(agent), "kopi-agent");
        assertEq(pay.agentAddress("kopi-agent"), agent);
    }

    function testRegisterAgentRejectsBadNames() public {
        vm.prank(agent);
        vm.expectRevert(AevumPay.InvalidName.selector);
        pay.registerAgent("ab"); // too short

        vm.prank(agent);
        vm.expectRevert(AevumPay.InvalidName.selector);
        pay.registerAgent("Bad Name!"); // uppercase + space + punctuation

        vm.prank(agent);
        vm.expectRevert(AevumPay.InvalidName.selector);
        pay.registerAgent("-leading-dash");
    }

    function testRegisterAgentRejectsDuplicates() public {
        vm.prank(agent);
        pay.registerAgent("kopi-agent");

        address other = makeAddr("other");
        vm.prank(other);
        vm.expectRevert(AevumPay.NameTaken.selector);
        pay.registerAgent("kopi-agent");

        vm.prank(agent);
        vm.expectRevert(AevumPay.AlreadyRegistered.selector);
        pay.registerAgent("nama-lain");
    }

    // ---- link creation ----

    function testCreateLink() public {
        vm.prank(agent);
        pay.registerAgent("kopi-agent");
        vm.prank(merchant);
        uint256 linkId = pay.createLink(AMOUNT, "Demo: kopi untuk agent", 1 days, agent);
        assertEq(linkId, 1);
        (address m, address a, uint256 amt, uint256 expiry, string memory desc, bool paid, address payer) =
            pay.paymentOf(linkId);
        assertEq(m, merchant);
        assertEq(a, agent);
        assertEq(amt, AMOUNT);
        assertEq(expiry, block.timestamp + 1 days);
        assertEq(desc, "Demo: kopi untuk agent");
        assertFalse(paid);
        assertEq(payer, address(0));
        assertTrue(pay.authorizationNonce(linkId) != bytes32(0));
    }

    function testCreateLinkRejectsUnknownAgent() public {
        vm.prank(merchant);
        vm.expectRevert(AevumPay.UnknownAgent.selector);
        pay.createLink(AMOUNT, "x", 1 days, agent);
    }

    function testCreateLinkRejectsBadInput() public {
        vm.prank(merchant);
        vm.expectRevert(AevumPay.InvalidAmount.selector);
        pay.createLink(0, "x", 1 days, address(0));

        vm.prank(merchant);
        vm.expectRevert(AevumPay.InvalidExpiry.selector);
        pay.createLink(AMOUNT, "x", 31 days, address(0));
    }

    // ---- standard pay ----

    function testPayStandard() public {
        uint256 linkId = _createLink();
        vm.prank(buyer);
        token.approve(address(pay), AMOUNT);
        uint256 merchantBefore = token.balanceOf(merchant);

        vm.prank(buyer);
        pay.pay(linkId);

        assertEq(token.balanceOf(merchant), merchantBefore + AMOUNT);
        assertEq(token.balanceOf(buyer), 100_000_000 - AMOUNT);
        (,,,,, bool paid, address payer) = pay.paymentOf(linkId);
        assertTrue(paid);
        assertEq(payer, buyer);
    }

    function testPayTwiceReverts() public {
        uint256 linkId = _createLink();
        vm.prank(buyer);
        token.approve(address(pay), AMOUNT * 2);
        vm.prank(buyer);
        pay.pay(linkId);
        vm.prank(buyer);
        vm.expectRevert(AevumPay.AlreadyPaid.selector);
        pay.pay(linkId);
    }

    function testPayExpiredReverts() public {
        uint256 linkId = _createLink();
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(buyer);
        token.approve(address(pay), AMOUNT);
        vm.prank(buyer);
        vm.expectRevert(AevumPay.LinkExpired.selector);
        pay.pay(linkId);
    }

    // ---- gasless pay (EIP-3009) ----

    function testPayGasless() public {
        uint256 linkId = _createLink();
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes memory sig = _signAuthorization(linkId, validAfter, validBefore);

        uint256 merchantBefore = token.balanceOf(merchant);
        uint256 buyerBefore = token.balanceOf(buyer);

        // The buyer never sends a transaction: the relayer submits it.
        vm.prank(relayer);
        pay.payWithAuthorization(linkId, buyer, validAfter, validBefore, sig);

        assertEq(token.balanceOf(merchant), merchantBefore + AMOUNT);
        assertEq(token.balanceOf(buyer), buyerBefore - AMOUNT);
        (,,,,, bool paid, address payer) = pay.paymentOf(linkId);
        assertTrue(paid);
        assertEq(payer, buyer);
    }

    function testPayGaslessReplayReverts() public {
        uint256 linkId = _createLink();
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes memory sig = _signAuthorization(linkId, validAfter, validBefore);

        vm.prank(relayer);
        pay.payWithAuthorization(linkId, buyer, validAfter, validBefore, sig);

        // Same signature again: link already paid (and nonce consumed).
        vm.prank(relayer);
        vm.expectRevert(AevumPay.AlreadyPaid.selector);
        pay.payWithAuthorization(linkId, buyer, validAfter, validBefore, sig);
    }

    function testPayGaslessWrongSignerReverts() public {
        uint256 linkId = _createLink();
        // Claim `from` = other, but sign with the buyer's key: the recovered
        // signer (buyer) does not match `from` (other) -> invalid signature.
        address other = makeAddr("other");
        bytes32 nonce = pay.authorizationNonce(linkId);
        bytes32 structHash = keccak256(
            abi.encode(
                RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
                other,
                address(pay),
                AMOUNT,
                block.timestamp - 1,
                block.timestamp + 1 hours,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(buyerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(relayer);
        vm.expectRevert("invalid signature");
        pay.payWithAuthorization(linkId, other, block.timestamp - 1, block.timestamp + 1 hours, sig);
    }

    function testPayGaslessExpiredAuthorizationReverts() public {
        uint256 linkId = _createLink();
        // Warp forward so `block.timestamp - 2 hours` cannot underflow
        // (forge tests start at timestamp 1).
        vm.warp(block.timestamp + 3 hours);
        bytes memory sig = _signAuthorization(linkId, block.timestamp - 2 hours, block.timestamp - 1 hours);
        vm.prank(relayer);
        vm.expectRevert("authorization expired");
        pay.payWithAuthorization(linkId, buyer, block.timestamp - 2 hours, block.timestamp - 1 hours, sig);
    }

    // ---- recover (front-run rescue) ----

    function testRecoverAfterFrontRun() public {
        uint256 linkId = _createLink();
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes memory sig = _signAuthorization(linkId, validAfter, validBefore);

        // Attacker/griefer submits the authorization straight to the token:
        // funds land in AevumPay, the link stays unpaid, nonce is consumed.
        bytes32 nonce = pay.authorizationNonce(linkId);
        vm.prank(relayer);
        token.receiveWithAuthorization(buyer, address(pay), AMOUNT, validAfter, validBefore, nonce, sig);
        assertEq(token.balanceOf(address(pay)), AMOUNT);
        (,,,,, bool paidBefore,) = pay.paymentOf(linkId);
        assertFalse(paidBefore);

        // Merchant rescues the stuck funds; link is marked paid.
        uint256 merchantBefore = token.balanceOf(merchant);
        vm.prank(merchant);
        pay.recover(linkId, buyer);
        assertEq(token.balanceOf(merchant), merchantBefore + AMOUNT);
        (,,,,, bool paidAfter, address payerAfter) = pay.paymentOf(linkId);
        assertTrue(paidAfter);
        assertEq(payerAfter, buyer);
    }

    function testRecoverRejectsWhenNothingConsumed() public {
        uint256 linkId = _createLink();
        vm.prank(merchant);
        vm.expectRevert(AevumPay.AuthorizationNotConsumed.selector);
        pay.recover(linkId, buyer);
    }
}
