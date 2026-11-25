#!/usr/bin/env bash
# Fund wallets with test tokens on a LOCAL anvil fork of Aevum only.
# NOTE: Foundry's `vm.deal` inside a broadcast script does NOT persist to a
# remote anvil node (it only affects the script's local simulation), so this
# script sets the state directly over anvil's JSON-RPC:
#   - tQDAY (gas): anvil_setBalance
#   - tUSD8: anvil_setStorageAt on the balances mapping (slot 11 — found with
#     test/SlotFinder.t.sol) at key keccak256(abi.encode(address, 11)).
# Usage: ./tools/fund-fork.sh [rpc-url]   (default http://127.0.0.1:8555)
# Funds the three throwaway wallets in .keys/ with 100 tUSD8 + 10 tQDAY each.
set -euo pipefail
FORK="${1:-http://127.0.0.1:8555}"
TUSD8=0x456569838f1d43009A91ebA4263147Afd7233483
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS="$SCRIPT_DIR/../.keys"

for name in deployer buyer relayer; do
  addr="$(cat "$KEYS/$name.address")"
  key="$(cast keccak "$(cast abi-encode "x(address,uint256)" "$addr" 11)")"
  cast rpc anvil_setBalance "$addr" 0x8ac7230489e80000 --rpc-url "$FORK" >/dev/null
  cast rpc anvil_setStorageAt "$TUSD8" "$key" \
    0x0000000000000000000000000000000000000000000000000000000005f5e100 \
    --rpc-url "$FORK" >/dev/null
  echo "funded $name $addr: 100 tUSD8 + 10 tQDAY (fork only)"
done
