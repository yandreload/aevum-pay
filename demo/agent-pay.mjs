#!/usr/bin/env node
/**
 * AevumPay agent demo — one end-to-end stablecoin payment on Aevum testnet.
 *
 * Roles (all throwaway testnet-only wallets):
 *   MERCHANT — creates a payment link (2.50 tUSD8, "kopi untuk agent").
 *   BUYER    — an agent that pays WITHOUT holding gas: it signs an EIP-3009
 *              ReceiveWithAuthorization off-chain and never sends a tx.
 *   RELAYER  — submits the buyer's signature on-chain (pays the gas).
 *
 * Modes:
 *   gasless  (default) — buyer signs, relayer calls payWithAuthorization.
 *   standard           — buyer approves tUSD8, then calls pay().
 *
 * Usage:
 *   # against the local fork (see README: start anvil fork, fund wallets,
 *   # deploy AevumPay, then run with the fork address):
 *   RPC_URL=http://127.0.0.1:8555 AEVUMPAY_ADDRESS=0x... \
 *     MERCHANT_PK=0x... BUYER_PK=0x... RELAYER_PK=0x... \
 *     node demo/agent-pay.mjs [--mode gasless|standard] [--amount 2.5]
 *
 *   # against the real testnet (needs funded wallets — see README):
 *   RPC_URL=https://rpc-test.qday.info AEVUMPAY_ADDRESS=0x... ... node demo/agent-pay.mjs
 *
 * Private keys are read from the environment only. Never commit them.
 */
import { ethers } from 'ethers';

const TUSD8_ADDRESS = process.env.TUSD8 ?? '0x456569838f1d43009A91ebA4263147Afd7233483';
const EXPLORER = 'https://explorer-test.qday.info';

const AEVUMPAY_ABI = [
  'function createLink(uint256 amount, string description, uint256 expirySeconds, address agent) returns (uint256)',
  'function pay(uint256 linkId)',
  'function payWithAuthorization(uint256 linkId, address from, uint256 validAfter, uint256 validBefore, bytes signature)',
  'function authorizationNonce(uint256 linkId) view returns (bytes32)',
  'function paymentOf(uint256 linkId) view returns (address merchant, address agent, uint256 amount, uint256 expiry, string description, bool paid, address payer)',
  'function registerAgent(string name)',
  'function agentName(address) view returns (string)',
  'event LinkCreated(uint256 indexed linkId, address indexed merchant, address indexed agent, uint256 amount, uint256 expiry, string description)',
  'event Paid(uint256 indexed linkId, address indexed payer, address indexed merchant, uint256 amount, bool gasless)',
];
const ERC20_ABI = [
  'function balanceOf(address) view returns (uint256)',
  'function approve(address spender, uint256 value) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)',
];

function arg(name, fallback) {
  const i = process.argv.indexOf(name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
}

async function main() {
  const rpcUrl = process.env.RPC_URL ?? 'http://127.0.0.1:8555';
  const payAddress = process.env.AEVUMPAY_ADDRESS;
  if (!payAddress) throw new Error('Set AEVUMPAY_ADDRESS to the deployed AevumPay address.');
  for (const k of ['MERCHANT_PK', 'BUYER_PK', 'RELAYER_PK']) {
    if (!process.env[k]) throw new Error(`Set ${k} (testnet-only throwaway key).`);
  }
  const mode = arg('--mode', 'gasless');
  const amountTusd8 = arg('--amount', '2.5');
  const amount = ethers.parseUnits(amountTusd8, 6);

  const provider = new ethers.JsonRpcProvider(rpcUrl);
  const net = await provider.getNetwork();
  const chainId = Number(net.chainId);
  const merchant = new ethers.Wallet(process.env.MERCHANT_PK, provider);
  const buyer = new ethers.Wallet(process.env.BUYER_PK, provider);
  const relayer = new ethers.Wallet(process.env.RELAYER_PK, provider);
  const pay = new ethers.Contract(payAddress, AEVUMPAY_ABI, provider);
  const tusd8 = new ethers.Contract(TUSD8_ADDRESS, ERC20_ABI, provider);
  const txLink = (hash) => `${EXPLORER}/tx/${hash}`;

  console.log(`AevumPay agent demo — chain ${chainId}, mode ${mode}`);
  console.log(`  AevumPay: ${payAddress}`);
  console.log(`  merchant: ${merchant.address}`);
  console.log(`  buyer:    ${buyer.address} (agent, pays gaslessly)`);
  console.log(`  relayer:  ${relayer.address}`);
  console.log(`  buyer tUSD8 before: ${ethers.formatUnits(await tusd8.balanceOf(buyer.address), 6)}`);

  // 1. Merchant creates a payment link.
  console.log('\n[1/4] Merchant creates a payment link...');
  const createTx = await pay
    .connect(merchant)
    .createLink(amount, 'Demo: kopi untuk agent', 86400, ethers.ZeroAddress, { type: 0 });
  const createRc = await createTx.wait();
  const created = createRc.logs
    .map((l) => { try { return pay.interface.parseLog(l); } catch { return null; } })
    .find((e) => e && e.name === 'LinkCreated');
  const linkId = created.args.linkId;
  console.log(`  link #${linkId} for ${amountTusd8} tUSD8 — tx ${txLink(createTx.hash)}`);

  // 2. Buyer (agent) signs an EIP-3009 authorization off-chain — gasless mode only.
  // The token's EIP-712 domain comes from env so the demo can also run against
  // a local MockUSD8 (name "MockUSD8", version "1"); the real tUSD8 is
  // name "tUSD8", version "2".
  const nonce = await pay.authorizationNonce(linkId);
  const now = Math.floor(Date.now() / 1000);
  const validAfter = now - 60;
  const validBefore = now + 3600;
  let signature = null;
  if (mode === 'gasless') {
    console.log('\n[2/4] Buyer signs an EIP-3009 ReceiveWithAuthorization (off-chain, no gas)...');
    const domain = {
      name: process.env.TUSD8_NAME ?? 'tUSD8',
      version: process.env.TUSD8_VERSION ?? '2',
      chainId,
      verifyingContract: TUSD8_ADDRESS,
    };
    const types = {
      ReceiveWithAuthorization: [
        { name: 'from', type: 'address' },
        { name: 'to', type: 'address' },
        { name: 'value', type: 'uint256' },
        { name: 'validAfter', type: 'uint256' },
        { name: 'validBefore', type: 'uint256' },
        { name: 'nonce', type: 'bytes32' },
      ],
    };
    const message = {
      from: buyer.address,
      to: payAddress,
      value: amount,
      validAfter,
      validBefore,
      nonce,
    };
    signature = await buyer.signTypedData(domain, types, message);
    console.log(`  signed authorization, nonce ${nonce}`);
  } else {
    console.log('\n[2/4] Standard mode: buyer will approve + pay on-chain (no signature).');
  }

  // 3. Relayer submits it (gasless mode) or buyer pays the standard way.
  console.log('\n[3/4] Settling on-chain...');
  let settleTx;
  if (mode === 'gasless') {
    settleTx = await pay
      .connect(relayer)
      .payWithAuthorization(linkId, buyer.address, validAfter, validBefore, signature, { type: 0 });
  } else if (mode === 'standard') {
    const approveTx = await tusd8
      .connect(buyer)
      .approve(payAddress, amount, { type: 0 });
    await approveTx.wait();
    console.log(`  buyer approved ${amountTusd8} tUSD8 — tx ${txLink(approveTx.hash)}`);
    // Fetch the nonce explicitly: ethers' default nonce lookup can reuse the
    // approve's nonce when the two sends happen back-to-back on a fast chain.
    // Use 'latest' — 'pending' can return a stale count on this node.
    const payNonce = await provider.getTransactionCount(buyer.address, 'latest');
    settleTx = await pay.connect(buyer).pay(linkId, { type: 0, nonce: payNonce });
  } else {
    throw new Error(`Unknown --mode ${mode} (use gasless or standard).`);
  }
  const settleRc = await settleTx.wait();
  console.log(`  settled in block ${settleRc.blockNumber} — tx ${txLink(settleTx.hash)}`);

  // 4. Verify the payment on-chain.
  console.log('\n[4/4] Verifying...');
  const link = await pay.paymentOf(linkId);
  console.log(`  paid: ${link.paid}, payer: ${link.payer}, merchant: ${link.merchant}`);
  console.log(`  merchant tUSD8 after: ${ethers.formatUnits(await tusd8.balanceOf(merchant.address), 6)}`);
  console.log(`  buyer tUSD8 after:    ${ethers.formatUnits(await tusd8.balanceOf(buyer.address), 6)}`);
  if (!link.paid) throw new Error('Payment did not settle!');
  console.log('\nDone — one end-to-end tUSD8 payment on Aevum testnet.');
  console.log(`  AevumPay: ${EXPLORER}/address/${payAddress}`);
}

main().catch((e) => {
  console.error('Demo failed:', e.shortMessage ?? e.message ?? e);
  process.exit(1);
});
