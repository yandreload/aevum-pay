# AevumPay — pay-links for agents

**Aevum Builder Challenge #1 (QDay / DoraHacks)** — a practical stablecoin
payment app on Aevum testnet. One flow, end to end, with the test stablecoin
**tUSD8**.

A merchant (or their agent) creates a **payment link** priced in tUSD8. A
buyer pays it exactly once — either the standard way (approve + pay) or
**gaslessly**: the buyer signs an EIP-3009 `ReceiveWithAuthorization`
off-chain and any relayer submits it, so an agent can pay without holding the
gas token. An on-chain **agent registry** maps human-readable agent names to
addresses (Confirmation of Payee — QDay's ERC-8004 registry is still in
internal testing, so the mapping lives in this contract, as the challenge docs
suggest).

- Tracks: **Decentralized Payments**, **Native AI Assistants**, **Confirmation of Payee**
- Prizes: $1,500 USDT (1st $800 / 2nd $500 / 3rd $200)
- Build period: 16 Nov – 11 Dec 2026. Submissions close **11 Dec 2026, 08:00 UTC (15:00 WIB)**.
- Challenge page: https://dorahacks.io/hackathon/qday/detail
- Docs used: https://aevum-starter-kit.vercel.app/docs

## Status (25 Nov 2026)

| Item | State |
| --- | --- |
| Contracts written + unit tests | ✅ 15/15 pass (`forge test`) |
| Fork tests vs the **real tUSD8** | ✅ 2/2 pass (standard + gasless) |
| Demo CLI (standard + gasless) | ✅ Runs end-to-end on a local Shanghai chain (tx hashes below) |
| Web prototype UI | ✅ `web/index.html` (MetaMask, no build step) |
| **Deployment to Aevum testnet** | ⏳ **BLOCKED — deployer wallet has 0 tQDAY / 0 tUSD8.** Needs the Discord faucet (see below). |
| GitHub repo | ⏳ Local repo ready; remote creation needs GitHub auth (see below). |
| DoraHacks registration / submission | ⏳ Not done — handled later with the project owner. |

Nothing here is a claim about the real testnet that isn't verified: the
testnet deployment is explicitly still pending, and the demo transactions
below are from a **local** chain, not Aevum testnet.

## Network

| | |
| --- | --- |
| Network | QDay Aevum Testnet |
| Chain ID | `44005` |
| RPC | `https://rpc-test.qday.info` (HTTPS only, no WebSocket) |
| Explorer | https://explorer-test.qday.info |
| Gas token | tQDAY (18 decimals), ~1 gwei |
| EVM version | **Shanghai** |
| tUSD8 | `0x456569838f1d43009A91ebA4263147Afd7233483` — 6 decimals, EIP-2612 `permit`, EIP-3009 signed transfers. EIP-712 domain `name: "tUSD8"`, `version: "2"`. |
| Multicall3 | `0xcA11bde05977b3631167028862bE2a173976CA11` |

## Contracts

`src/AevumPay.sol` (the only production contract; OpenZeppelin v4.9.6 for
`ReentrancyGuard`):

- `registerAgent(string name)` — claim a name (3–32 chars, `[a-z0-9-]`, unique,
  one per address). `agentName(address)` / `agentAddress(string)` resolve it.
- `createLink(uint256 amount, string description, uint256 expirySeconds, address agent)`
  → `linkId`. The `agent` must be a registered agent or `address(0)`. The
  link is payable once, until `expiry` (max 30 days).
- `pay(uint256 linkId)` — standard: buyer approves tUSD8, then pays; funds go
  straight to the merchant. Emits `Paid(..., gasless=false)`.
- `payWithAuthorization(uint256 linkId, address from, uint256 validAfter, uint256 validBefore, bytes signature)`
  — gasless: `from` signed an EIP-3009 authorization for exactly
  `link.amount` to this contract, with nonce `authorizationNonce(linkId)`.
  The nonce binds the signature to one link, so it cannot be replayed onto
  another link. Emits `Paid(..., gasless=true)`.
- `recover(uint256 linkId, address authorizer)` — rescue path: if a signed
  authorization was submitted directly to the token (front-run) instead of
  through `payWithAuthorization`, the funds land in this contract and the link
  stays unpaid. The merchant can claim the stuck funds; the link is marked
  paid. See `docs/ARCHITECTURE.md`.
- `paymentOf(uint256 linkId)` — read a link + its paid status. The `Paid`
  event is the receipt.

`src/MockUSD8.sol` is **test-only**: an ERC-20 with 6 decimals, EIP-2612
permit and EIP-3009 `receiveWithAuthorization`, mirroring the real tUSD8
interface. It is never deployed to Aevum testnet.

## Quickstart

```shell
# 1. Install Foundry (forge, cast, anvil)
curl -sL https://foundry.paradigm.xyz | bash && foundryup

# 2. Build + unit tests (no network needed)
forge build
forge test --match-path test/AevumPay.t.sol   # 15/15 pass

# 3. Fork tests against the REAL tUSD8 on a local fork of Aevum
#    (needs the RPC relay — see "Aevum RPC quirks" below)
node tools/rpc-relay.mjs &                    # http://127.0.0.1:8545
AEVUM_RPC_URL=http://127.0.0.1:8545 forge test --match-path test/fork/AevumFork.t.sol  # 2/2 pass

# 4. Demo (local chain): start a plain Shanghai anvil, deploy MockUSD8 +
#    AevumPay, fund the demo wallets, run the agent demo
anvil --hardfork shanghai --port 8556 &
# ... see docs/DEMO.md for the exact commands
```

## Demo (verified 25 Nov 2026, local Shanghai chain 31337)

`demo/agent-pay.mjs` — the merchant creates a link for 2.50 tUSD8, the
buyer-agent pays, the relayer settles, the script verifies `paymentOf`.

- **Gasless mode** — buyer signs EIP-3009 off-chain, relayer submits:
  settled in block 14, tx
  `0x40ccd447e60a07b21318b81e1769803a96a12b63258e170383a4f55c0c97ba35`.
  Verified: `paid: true`, merchant +2.5 tUSD8, buyer 100 → 97.5.
- **Standard mode** — buyer approves + pays:
  settled in block 23, tx
  `0xb0b01f0f49f326d4b99e7ab03b11d8f2e8baf07a10ebf76b9fcd53d60c0b6e93`.
  Verified: `paid: true`, merchant 7.5, buyer 92.5 (cumulative over the demo runs).
- Local deployment used for the demo: AevumPay
  `0x6fcAf73b4e50D3705841a14084778BfEe8351444` (deploy tx
  `0xf5285a58220c0e82013df5adfcb8ac7ba65eb232c18a939060a90670b7f8ba56`),
  MockUSD8 `0x9D2E21EEdc2dC143a4b730e0087fF197c3030531`.

Full steps: `docs/DEMO.md`. Architecture, safety notes and known
limitations: `docs/ARCHITECTURE.md`.

## Deploying to Aevum testnet (pending)

The deployer is a fresh throwaway testnet-only wallet (keys in `.keys/`,
gitignored, never committed):

- **Deployer address: `0xdDF74b8D1305B4C5EC421bcA51f010a6bD368c95`**
- Balance on the real testnet (checked 25 Nov 2026 via the explorer API):
  **0 tQDAY, 0 tUSD8** — deployment is impossible until it is funded.

### How to fund it (one human step)

The web faucet cannot fund a fresh wallet: it requires a captcha **and**
≥ 0.0001 ETH (or ≥ 1 stablecoin unit) on Ethereum mainnet
(`GET faucet.qday.info/gasapi/eligibility` returns `{"eligible":false}` for
this address), and the tUSD8 faucet needs an email verification code. The
**Discord faucet** has neither requirement (recommended by the challenge
docs for participants):

1. Join the QDay Discord.
2. In `#verify`, react with ✅ to get the **Verified** role.
3. In `#faucet`, run `/faucet` and paste
   `0xdDF74b8D1305B4C5EC421bcA51f010a6bD368c95`.
4. You get **1 tQDAY + 5 tUSD8** (once per Discord account and once per address).

Deploying `AevumPay` costs well under 0.01 tQDAY, so 1 tQDAY is plenty.

### Deploy command (after funding)

```shell
# Private key from .keys/deployer.json (never commit it, never paste it in chat)
forge script script/Deploy.s.sol \
  --rpc-url https://rpc-test.qday.info \
  --broadcast --legacy --private-key $DEPLOYER_KEY
# Then update AEVUMPAY_ADDRESS in demo/agent-pay.mjs + web/index.html,
# and record the address + tx hash here.
```

Note: the challenge's explorer does not support contract verification yet,
so share the contract addresses + the exact deployed commit instead
(see the challenge docs).

## Web prototype

`web/index.html` is a single-file UI (ethers v6 from CDN, MetaMask only, no
build step): connect wallet, add Aevum testnet, create a link, pay standard
or gaslessly, look a link up, register/resolve an agent name. Serve it with
the included `Dockerfile` (`docker build -t aevumpay . && docker run -p 8080:80 aevumpay`)
or any static host. **Set `AEVUMPAY_ADDRESS` in the file after deployment —
it is currently the zero address on purpose.**

## Aevum RPC quirks (found while building)

- The RPC (`rpc-test.qday.info`) intermittently drops TLS connections
  without `close_notify`, which Foundry's rustls stack rejects
  (`cast` via curl/OpenSSL tolerates it). `tools/rpc-relay.mjs` is a tiny
  localhost JSON-RPC relay (Node https → local HTTP, with retries) that works
  around it for `forge test --fork-url` and `anvil --fork-url`. It was also
  observed completely unresponsive for a stretch on 25 Nov 2026 — the RPC
  itself is flaky, not just the TLS handling. (At ~15:45 UTC on 25 Nov 2026
  it was unreachable even for plain curl; the fork tests above passed
  earlier the same day when it was up. If `forge test --fork-url` fails with
  a connection error, retry later — the contracts are unchanged.)
- Aevum is **Shanghai**: OpenZeppelin v5.7.0 does not compile for Shanghai
  (it uses Cancun `MCOPY` in `Bytes.sol`), so this repo pins
  **OpenZeppelin v4.9.6**. `evm_version = "shanghai"` is set in
  `foundry.toml`.
- On a fork, `anvil_setBalance` is not honored for transaction validation of
  accounts that already exist on the real chain (their upstream 0 balance
  wins); `vm.deal` inside a broadcast script does not persist to the node
  either. `tools/fund-fork.sh` funds fork wallets by writing the tUSD8
  balance directly into storage (balances mapping is at slot 11 — see
  `test/SlotFinder.t.sol`) plus `anvil_setBalance` for gas.
- Ethers v6 `getTransactionCount(..., 'pending')` can return a stale nonce
  on a fast local chain when two sends happen back-to-back; the demo fetches
  the nonce with `'latest'` explicitly (see `demo/agent-pay.mjs`).

## Project structure

```
src/AevumPay.sol        # the payment-link contract (+ agent registry)
src/MockUSD8.sol        # test-only tUSD8 stand-in (permit + EIP-3009)
test/AevumPay.t.sol     # 15 unit tests (mock token)
test/fork/AevumFork.t.sol  # 2 fork tests vs the real tUSD8
test/SlotFinder.t.sol   # dev utility: finds tUSD8's balances storage slot
script/Deploy.s.sol     # deploy AevumPay (legacy txs, --legacy)
demo/agent-pay.mjs      # agent demo CLI (ethers v6): gasless + standard
demo/package.json
web/index.html          # prototype UI (MetaMask)
tools/rpc-relay.mjs     # localhost JSON-RPC relay around the flaky RPC
tools/fund-fork.sh      # fund wallets on a local anvil fork
docs/ARCHITECTURE.md    # design, flows, safety, limitations
docs/DEMO.md            # exact demo + deploy steps
```

## License & credits

MIT — see `LICENSE`. OpenZeppelin contracts are MIT licensed (v4.9.6).
The Aevum starter-kit docs (https://aevum-starter-kit.vercel.app/docs) were
used as a reference for the EIP-3009 design (nonce bound to the order,
`receiveWithAuthorization` to the contract); the contracts in this repo are
original code written for this challenge, not a copy of the kit.
