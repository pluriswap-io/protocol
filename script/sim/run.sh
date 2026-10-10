#!/usr/bin/env bash
# The ecosystem simulation (script/sim/ecosystem.ts) on a throwaway anvil: deploy the kernel and the
# packaged stack exactly as e2e.sh does, then let a population of agents trade against it.
#
#   script/sim/run.sh [port]              default 8546, so it never collides with an e2e run on 8545
#   script/sim/run.sh [port] --longrun    the evolutionary long run (script/sim/longrun.ts)
#   script/sim/run.sh [port] --tribunal   an imperfect tribunal in the long run (script/sim/tribunal.ts)
#
# Everything the agents do goes through the deployed contracts; the only off-chain piece is the fiat
# leg, which is a ledger (the protocol never sees fiat, and neither should its simulation).
set -euo pipefail
cd "$(dirname "$0")/../.."

PORT="${1:-8546}"
RPC="http://127.0.0.1:${PORT}"
KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 # anvil's first account

anvil --silent --port "$PORT" --gas-limit 300000000 &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
until cast block-number --rpc-url "$RPC" >/dev/null 2>&1; do sleep 1; done

for step in "script/Deploy.s.sol:Deploy" "script/DeployPackages.s.sol:DeployPackages"; do
  if ! HOLDER_PRIVATE_KEY="$KEY" forge script "$step" --rpc-url "$RPC" --broadcast --skip-simulation \
      --private-key "$KEY" >"/tmp/sim-${step##*:}.log" 2>&1; then
    echo "[FAIL] ${step##*:}"; tail -25 "/tmp/sim-${step##*:}.log"; exit 1
  fi
  echo "[OK]   ${step##*:}"
done

if [ "${2:-}" = "--longrun" ]; then
  RPC="$RPC" bun script/sim/longrun.ts
elif [ "${2:-}" = "--tribunal" ]; then
  RPC="$RPC" bun script/sim/tribunal.ts
else
  RPC="$RPC" bun script/sim/ecosystem.ts "${@:2}"
fi
