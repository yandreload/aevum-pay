// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @notice Minimal interface of the tUSD8 stablecoin (USDC-style) that AevumPay needs.
interface ITUSD8 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title AevumPay — pay-links for agents on Aevum testnet
/// @author Built for the Aevum Builder Challenge #1 (QDay / DoraHacks)
/// @notice Merchants (or their agents) create payment links priced in tUSD8.
/// A buyer pays a link exactly once, either the standard way (approve + pay)
/// or gaslessly: the buyer signs an EIP-3009 ReceiveWithAuthorization
/// off-chain and any relayer submits it, so an agent can pay without holding
/// the gas token. An on-chain agent registry maps human-readable agent names
/// to addresses (Confirmation of Payee) — QDay's ERC-8004 registry is still
/// in internal testing, so the mapping lives in this contract, as the
/// challenge docs suggest.
/// @dev One flow, end to end. Funds always settle in tUSD8 on Aevum testnet
/// (chain 44005). EVM version Shanghai.
contract AevumPay is ReentrancyGuard {
    ITUSD8 public immutable token;

    uint256 public nextLinkId = 1;

    struct Link {
        address merchant;
        address agent;
        uint256 amount;
        uint256 expiry;
        string description;
        bool paid;
        address payer;
    }

    mapping(uint256 => Link) public links;
    /// @notice EIP-3009 nonce bound to a link. The signed authorization must
    /// use exactly this nonce, so a signature cannot be replayed onto a
    /// different link.
    mapping(uint256 => bytes32) public authorizationNonce;

    mapping(address => string) public agentName;
    mapping(string => address) public agentAddress;

    event AgentRegistered(address indexed agent, string name);
    event LinkCreated(
        uint256 indexed linkId,
        address indexed merchant,
        address indexed agent,
        uint256 amount,
        uint256 expiry,
        string description
    );
    event Paid(uint256 indexed linkId, address indexed payer, address indexed merchant, uint256 amount, bool gasless);
    event Recovered(uint256 indexed linkId, address indexed merchant, uint256 amount);

    error InvalidName();
    error NameTaken();
    error AlreadyRegistered();
    error InvalidAmount();
    error InvalidExpiry();
    error DescriptionTooLong();
    error UnknownAgent();
    error LinkNotFound();
    error NotMerchant();
    error AlreadyPaid();
    error LinkExpired();
    error AuthorizationNotConsumed();
    error InsufficientBalance();

    constructor(address tokenAddress) {
        token = ITUSD8(tokenAddress);
    }

    // ---- Agent registry (Confirmation of Payee) ----

    /// @notice Register a human-readable name for the caller's address.
    /// Names are 3-32 chars, lowercase letters, digits and dashes only.
    function registerAgent(string calldata name) external {
        bytes memory b = bytes(name);
        if (b.length < 3 || b.length > 32) revert InvalidName();
        if (b[0] == bytes1("-") || b[b.length - 1] == bytes1("-")) revert InvalidName();
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            bool ok =
                (c >= bytes1("a") && c <= bytes1("z")) || (c >= bytes1("0") && c <= bytes1("9")) || c == bytes1("-");
            if (!ok) revert InvalidName();
        }
        if (bytes(agentName[msg.sender]).length != 0) revert AlreadyRegistered();
        if (agentAddress[name] != address(0)) revert NameTaken();
        agentName[msg.sender] = name;
        agentAddress[name] = msg.sender;
        emit AgentRegistered(msg.sender, name);
    }

    // ---- Payment links ----

    /// @notice Create a payment link. `expirySeconds` is the lifetime from now
    /// (max 30 days). `agent` is the registered agent that issued the link on
    /// the merchant's behalf, or address(0) for a direct merchant link.
    function createLink(uint256 amount, string calldata description, uint256 expirySeconds, address agent)
        external
        returns (uint256 linkId)
    {
        if (amount == 0) revert InvalidAmount();
        if (expirySeconds == 0 || expirySeconds > 30 days) revert InvalidExpiry();
        if (bytes(description).length > 140) revert DescriptionTooLong();
        if (agent != address(0) && bytes(agentName[agent]).length == 0) revert UnknownAgent();

        linkId = nextLinkId++;
        links[linkId] = Link({
            merchant: msg.sender,
            agent: agent,
            amount: amount,
            expiry: block.timestamp + expirySeconds,
            description: description,
            paid: false,
            payer: address(0)
        });
        authorizationNonce[linkId] = keccak256(abi.encode("AevumPay:auth", linkId));
        emit LinkCreated(linkId, msg.sender, agent, amount, block.timestamp + expirySeconds, description);
    }

    /// @notice Standard payment: buyer must have approved this contract first.
    function pay(uint256 linkId) external nonReentrant {
        Link storage link = links[linkId];
        if (link.merchant == address(0)) revert LinkNotFound();
        if (link.paid) revert AlreadyPaid();
        if (block.timestamp > link.expiry) revert LinkExpired();

        link.paid = true;
        link.payer = msg.sender;
        require(token.transferFrom(msg.sender, link.merchant, link.amount), "transfer failed");
        emit Paid(linkId, msg.sender, link.merchant, link.amount, false);
    }

    /// @notice Gasless payment: `from` signed an EIP-3009
    /// ReceiveWithAuthorization off-chain authorizing this contract to pull
    /// `link.amount` tUSD8. Anyone (a relayer, or an agent) can submit it;
    /// the buyer pays no gas. The signature's nonce must equal this link's
    /// authorization nonce, binding it to exactly this link.
    function payWithAuthorization(
        uint256 linkId,
        address from,
        uint256 validAfter,
        uint256 validBefore,
        bytes calldata signature
    ) external nonReentrant {
        Link storage link = links[linkId];
        if (link.merchant == address(0)) revert LinkNotFound();
        if (link.paid) revert AlreadyPaid();
        if (block.timestamp > link.expiry) revert LinkExpired();

        bytes32 nonce = authorizationNonce[linkId];
        link.paid = true;
        link.payer = from;
        token.receiveWithAuthorization(from, address(this), link.amount, validAfter, validBefore, nonce, signature);
        require(token.transfer(link.merchant, link.amount), "forward failed");
        emit Paid(linkId, from, link.merchant, link.amount, true);
    }

    /// @notice Rescue path: if a signed authorization was submitted directly
    /// to the token (front-run) instead of through payWithAuthorization, the
    /// funds land in this contract and the link stays unpaid. The merchant
    /// can then claim the stuck funds and the link is marked paid.
    /// `authorizer` is the buyer address that signed the authorization.
    function recover(uint256 linkId, address authorizer) external nonReentrant {
        Link storage link = links[linkId];
        if (link.merchant == address(0)) revert LinkNotFound();
        if (link.paid) revert AlreadyPaid();
        if (msg.sender != link.merchant) revert NotMerchant();
        bytes32 nonce = authorizationNonce[linkId];
        if (!token.authorizationState(authorizer, nonce)) revert AuthorizationNotConsumed();
        if (token.balanceOf(address(this)) < link.amount) revert InsufficientBalance();

        link.paid = true;
        link.payer = authorizer;
        require(token.transfer(link.merchant, link.amount), "recover failed");
        emit Recovered(linkId, link.merchant, link.amount);
    }

    /// @notice Read a link plus its paid status. The receipt for a payment is
    /// the `Paid` event; this view is the on-chain confirmation.
    function paymentOf(uint256 linkId)
        external
        view
        returns (
            address merchant,
            address agent,
            uint256 amount,
            uint256 expiry,
            string memory description,
            bool paid,
            address payer
        )
    {
        Link storage link = links[linkId];
        return (link.merchant, link.agent, link.amount, link.expiry, link.description, link.paid, link.payer);
    }
}
