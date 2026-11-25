# AevumPay — demo & deploy steps

All commands run from `~/workspace/aevum-builder/` unless stated otherwise.
Testnet only. The three demo wallets are throwaway testnet-only keys in
`.keys/` (gitignored, mode 600) — never use them anywhere real.

## 1. Unit tests (no network)

```shell
forge build
forge test --match-path test/AevumPay.t.sol   # 15/15 pass
```

## 2. Fork tests vs the real tUSD8

The QDay RPC drops TLS connections without `close_notify`, which Foundry's
rustls stack rejects. Run the local relay first:

```shell
node tools/rpc-relay.mjs &   # listens on http://127.0.0.1:8545
AEVUM_RPC_URL=http://127.0.0.1:8545 forge test --match-path test/fork/AevumFork.t.sol
# 2/2 pass: standard pay + gasless EIP-3009 pay against the real tUSD8
# (verified 25 Nov 2026, fork block ~4,098,8xx)
```

## 3. Demo on a local chain (verified 25 Nov 2026)

A plain Shanghai anvil (no fork — the fork is too slow/flaky for
interactive use). The demo uses a `MockUSD8` there because the real tUSD8
does not exist on an empty chain; the fork tests above are the proof against
the real token.

```shell
# terminal 1: plain Shanghai anvil
anvil --hardfork shanghai --port 8556

# terminal 2:
export PLAIN=http://127.0.0.1:8556
DEPLOYER_KEY=$(python3 -c "import json;print(json.load(open('.keys/deployer.json'))['data'][0]['private_key'])")
BUYER=$(cat .keys/buyer.address)
RELAYER=$(cat .keys/relayer.address)

# fund the three wallets with gas (plain anvil, no fork)
for a in $(cat .keys/deployer.address) $BUYER $RELAYER; do
  cast rpc anvil_setBalance $a 0x8ac7230489e80000 --rpc-url $PLAIN
done

# deploy MockUSD8 + mint 100 to the buyer
MOCK=$(forge create src/MockUSD8.sol:MockUSD8 --rpc-url $PLAIN \
  --private-key $DEPLOYER_KEY --legacy --broadcast | grep -i "deployed to" | awk '{print $NF}')
cast send --rpc-url $PLAIN --private-key $DEPLOYER_KEY --legacy \
  $MOCK "mint(address,uint256)" $BUYER 100000000

# deploy AevumPay pointing at the mock
TUSD8=$MOCK forge script script/Deploy.s.sol --rpc-url $PLAIN \
  --broadcast --legacy --private-key $DEPLOYER_KEY
# note the deployed address from the output (PAY)

# run the demo (both modes)
cd demo && npm install   # ethers v6, once
export RPC_URL=$PLAIN TUSD8=$MOCK AEVUMPAY_ADDRESS=$PAY
export MERCHANT_PK=$DEPLOYER_KEY
export BUYER_PK=$(python3 -c "import json;print(json.load(open('../.keys/buyer.json'))['data'][0]['private_key'])")
export RELAYER_PK=$(python3 -c "import json;print(json.load(open('../.keys/relayer.json'))['data'][0]['private_key'])")
node agent-pay.mjs --mode standard
export TUSD8_NAME=MockUSD8 TUSD8_VERSION=1
node agent-pay.mjs --mode gasless
```

Verified 25 Nov 2026 on local chain 31337 (AevumPay
`0x6fcAf73b4e50D3705841a14084778BfEe8351444`, MockUSD8
`0x9D2E21EEdc2dC143a4b730e0087fF197c3030531`):

- Gasless: settled block 14, tx
  `0x40ccd447e60a07b21318b81e1769803a96a12b63258e170383a4f55c0c97ba35` —
  `paid: true`, merchant +2.5, buyer 100 → 97.5.
- Standard: settled block 23, tx
  `0xb0b01f0f49f326d4b99e7ab03b11d8f2e8baf07a10ebf76b9fcd53d60c0b6e93` —
  `paid: true`, merchant 7.5, buyer 92.5 (cumulative).

## 4. Deploy to Aevum testnet (pending faucet)

Deployer: `0xdDF74b8D1305B4C5EC421bcA51f010a6bD368c95` — balance 0 tQDAY /
0 tUSD8 (checked 25 Nov 2026 via the explorer API). Fund it first:

1. Join the QDay Discord → `#verify` react ✅ → `#faucet` run `/faucet`
   with the deployer address → 1 tQDAY + 5 tUSD8.
   (The web faucet cannot fund a fresh wallet: captcha + ≥ 0.0001 ETH on
   Ethereum mainnet required; the tUSD8 faucet needs an email code.)

Then:

```shell
forge script script/Deploy.s.sol \
  --rpc-url https://rpc-test.qday.info \
  --broadcast --legacy --private-key $DEPLOYER_KEY
```

Then update `AEVUMPAY_ADDRESS` in `demo/agent-pay.mjs` and `web/index.html`,
record the address + deploy tx hash in the README, and run the demo against
the real testnet:

```shell
export RPC_URL=https://rpc-test.qday.info AEVUMPAY_ADDRESS=<deployed>
# (same MERCHANT_PK / BUYER_PK / RELAYER_PK env as above; fund the buyer
#  with tUSD8 from the faucet first, and the relayer with a little tQDAY)
node demo/agent-pay.mjs --mode gasless
node demo/agent-pay.mjs --mode standard
```

## 5. Web prototype

```shell
# after deployment, set AEVUMPAY_ADDRESS in web/index.html, then:
docker build -t aevumpay . && docker run -p 8080:80 aevumpay
# open http://localhost:8080 — connect MetaMask, add Aevum testnet (the page
# has a button for it), create a link, pay it.
```

## 6. Local fork (optional, slow)

If you want a local copy of Aevum with the real tUSD8:

```shell
node tools/rpc-relay.mjs &
anvil --fork-url http://127.0.0.1:8545 --hardfork shanghai --port 8555
./tools/fund-fork.sh   # 100 tUSD8 + 10 tQDAY per demo wallet (fork only)
```

Notes: on a fork, `anvil_setBalance` is not honored for transaction
validation of accounts that already exist on the real chain (their upstream
0 balance wins) — use fresh wallets (the `.keys/` ones are fresh) or fund
them with a real on-fork transfer from an impersonated funded account. The
fork is also slow because every state fetch goes through the flaky upstream
RPC; prefer the plain anvil demo above for iteration.
