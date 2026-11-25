# AevumPay — architecture

## Problem

Small merchants and AI agents need to accept stablecoin payments without
running a backend, holding the gas token, or trusting a custodian. On Aevum
testnet the payment token is tUSD8 (a USDC-style ERC-20 with EIP-2612 permit
and EIP-3009 signed transfers), and the gas token is tQDAY. An agent that
wants to pay for something usually holds neither: it holds the stablecoin it
earned, not gas.

AevumPay answers with **pay-links + gasless settlement**:

1. A merchant (or an agent acting for them) creates a payment link: an
   amount in tUSD8, a description, an expiry, and optionally the agent that
   issued it.
2. A buyer pays the link exactly once — either the standard way (approve +
   `pay`) or **gaslessly**: the buyer signs an EIP-3009
   `ReceiveWithAuthorization` off-chain and any relayer submits it. The buyer
   never sends a transaction and needs no tQDAY.
3. Funds settle straight to the merchant in tUSD8. The `Paid` event is the
   receipt; `paymentOf(linkId)` is the on-chain confirmation.

On top of that, an **agent registry** maps human-readable names to addresses
(Confirmation of Payee). QDay's ERC-8004 registry is still in internal
testing and is not open for this challenge, so the mapping lives in this
contract — exactly what the challenge docs suggest.

## Contracts

### `AevumPay` (`src/AevumPay.sol`)

Single contract, OpenZeppelin v4.9.6 `ReentrancyGuard`. No owner, no admin,
no upgradeability — nothing to trust beyond the code.

State:

- `token` (immutable) — the tUSD8 address.
- `nextLinkId` — counter, starts at 1.
- `links[linkId]` — `Link { merchant, agent, amount, expiry, description,
  paid, payer }`.
- `authorizationNonce[linkId]` — `keccak256("AevumPay:auth", linkId)`, set at
  creation. The EIP-3009 signature must use exactly this nonce.
- `agentName[address]` / `agentAddress[string]` — the registry.

Functions (see README for the list): `registerAgent`, `createLink`, `pay`,
`payWithAuthorization`, `recover`, `paymentOf`.

### `MockUSD8` (`src/MockUSD8.sol`, test-only)

ERC-20 (6 decimals) + EIP-2612 permit + EIP-3009 `receiveWithAuthorization`,
mirroring the real tUSD8 interface, plus a public `mint` for tests. Never
deployed to Aevum testnet.

## Flows

### Standard payment

```
buyer → approve(AevumPay, amount) → tUSD8
buyer → pay(linkId)               → AevumPay
        AevumPay → transferFrom   → merchant
        emits Paid(linkId, buyer, merchant, amount, gasless=false)
```

### Gasless payment (the agent flow)

```
buyer   signs ReceiveWithAuthorization off-chain
          from=buyer, to=AevumPay, value=link.amount,
          validAfter/validBefore, nonce=authorizationNonce(linkId)
relayer → payWithAuthorization(...) → AevumPay
          AevumPay → tUSD8.receiveWithAuthorization(...)  (pulls funds in)
          AevumPay → tUSD8.transfer(merchant, amount)
          emits Paid(linkId, buyer, merchant, amount, gasless=true)
```

Design choices (following the challenge docs' checkout design):

- The signed nonce is bound to the link, so a signature cannot be replayed
  onto a different link.
- `receiveWithAuthorization` (not `transferWithAuthorization`) with
  `to = AevumPay` means only this contract can pull the funds, so nobody can
  front-run the signature into a plain transfer to themselves.
- The contract never sets prices: the app decides what a link costs and
  checks `paymentOf(linkId)` **and its amount** before delivering. `isPaid`
  alone is not enough — a link is only paid for its exact amount.

### Agent registration

```
agent → registerAgent("kopi-agent")
anyone → agentAddress("kopi-agent") → 0x...
merchant → createLink(amount, desc, expiry, agentAddress)
```

Names are 3–32 chars, `[a-z0-9-]`, no leading/trailing dash, unique, one per
address. Registration is free apart from gas.

## Safety, trust and controls

- **Single payment per link.** `paid` is set before any external call
  (checks-effects-interactions) plus `nonReentrant` on `pay`,
  `payWithAuthorization` and `recover`.
- **Exact amount.** A link is paid for exactly `link.amount` — no
  under/overpayment, no partial payments.
- **Expiry.** Links expire (`expirySeconds` 1s–30d). Paying an expired link
  reverts.
- **Front-run rescue.** If a signed authorization is submitted directly to
  the token instead of through `payWithAuthorization`, the funds land in
  this contract and the link stays unpaid. `recover(linkId, authorizer)` lets
  the merchant claim the stuck funds and marks the link paid. This is a
  known griefing vector of EIP-3009 relaying; the rescue closes it without
  adding an admin role.
- **No admin keys.** No owner, no pausing, no fund custody beyond the
  instant between `receiveWithAuthorization` and the forward to the merchant
  inside one transaction (plus the `recover` case above).
- **Shanghai-safe bytecode.** Compiled with `evm_version = "shanghai"`;
  OpenZeppelin pinned to v4.9.6 because v5.7.0 emits Cancun `MCOPY`.
- **Legacy transactions.** Aevum tooling sends type-0 transactions; the
  deploy script and demo use `--legacy` / `{ type: 0 }`.

## Known limitations (honest)

- **Anyone can pay any link, with any amount, if they call the token
  directly** — that is inherent to EIP-3009 authorizations: the signature
  itself is the permission. The contract only marks a link paid when the
  exact amount arrives through its own functions. For production, key
  payments by `keccak256(payer, linkId)` or have the merchant sign each
  quote, and use unguessable link ids. (Same caveat as the starter kit's
  checkout.)
- **Front-running a gasless payment** can strand funds in the contract until
  the merchant calls `recover`. The funds are never lost — they are either
  forwarded immediately or recoverable by the merchant.
- **No relayer service is shipped.** The demo CLI acts as the relayer, and
  the web UI lets the connected wallet relay its own signature. A production
  relayer would need the rails the starter kit documents (allow-list the
  function, enforce the app's price, skip already-paid orders, rate limits,
  daily caps) — out of scope for this challenge entry.
- **The web UI is a prototype**, not a hosted product: it needs MetaMask and
  the deployed contract address filled in.
- **The Aevum RPC is flaky** (drops TLS connections, occasional outright
  outages). `tools/rpc-relay.mjs` works around the TLS part locally; the
  outage part has no workaround except retrying later.
