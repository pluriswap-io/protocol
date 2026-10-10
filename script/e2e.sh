#!/usr/bin/env bash
# Deploy the whole stack in order, walk the Core catalogue, and ask the doctor whether the records
# still describe the chain.
#
# `forge test` exercises the contracts; nothing exercised the SCRIPTS until this existed, and two of
# them had been broken for months without anyone noticing: `Paths` still asserted that a timeout
# claim lands in RELEASED (CLAIMED became its own terminal on 2026-09-12), and `PoolDeal` still
# listed a Sponsor as a designated controller (the share vault rejects that). Both are the kind of
# rot that only a cold chain finds, so CI runs this on every push.
#
#   script/e2e.sh [port]              throwaway anvil on that port (the CI path)
#   RPC_URL=... DEPLOY_KEY=0x... script/e2e.sh
#                                     an existing chain. On Arbitrum Sepolia this also runs the
#                                     Stargate ramp, which cannot exist on anvil.
#                                     Add ETHERSCAN_API_KEY to verify the source on the explorer:
#                                     a testnet people are meant to poke at should not be a wall of
#                                     unverified bytecode.
#
# Pointing it at a real chain BROADCASTS. It is the same ordered run either way, which is the point:
# a testnet deploy should not be eight hand-typed commands in the right order.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -n "${RPC_URL:-}" ]; then
  RPC="$RPC_URL"
  KEY="${DEPLOY_KEY:?DEPLOY_KEY is required when RPC_URL is set}"
  echo "target: $RPC (broadcasting)"
else
  PORT="${1:-8545}"
  RPC="http://127.0.0.1:${PORT}"
  # Anvil's first account. A throwaway chain, a published key: never used anywhere else.
  KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
  anvil --silent --port "$PORT" &
  ANVIL=$!
  trap 'kill $ANVIL 2>/dev/null || true' EXIT
  until cast block-number --rpc-url "$RPC" >/dev/null 2>&1; do sleep 1; done
fi

CHAIN=$(cast chain-id --rpc-url "$RPC")

VERIFY=()
if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
  VERIFY=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
  echo "verification: on"
fi

# Order matters: each step reads the deployment record the previous one wrote.
STEPS=(
  "script/Deploy.s.sol:Deploy"
  "script/Paths.s.sol:Paths"
  "script/DeployPackages.s.sol:DeployPackages"
  "script/TrioDeal.s.sol:TrioDeal"
  "script/CatalogDeals.s.sol:CatalogDeals"
  # CASE-PAY-01: the ZK deal CatalogDeals left FUNDED, proven in its own run — the claim names the
  # activation clock, which only exists once the activation is mined.
  "script/ZkRelease.s.sol:ZkRelease"
  "script/DeployPoolFactory.s.sol:DeployPoolFactory"
  "script/PoolDeal.s.sol:PoolDeal"
  "script/DeployPrivate.s.sol:DeployPrivate"
  # The reputation package is a curve, not a transition: no single deal shows what it does, so this
  # walks the tiers, both refusals and the demotion. It is also the only on-chain coverage that the
  # cap, the concurrency check and the penalty have.
  "script/ReputationLadder.s.sol:ReputationLadder"
  # Everything downstream of a verdict, which Core cannot reach because Core has no tribunal: the two
  # slashes, the two stalemates, and what an abandoned dispute does with bonds on the table -- in a deal
  # WITH a tribunal, the only kind where abandonment still loses (Anexo R, 2026-09-24).
  "script/ArbitrationPaths.s.sol:ArbitrationPaths"
  # The first time the private layer runs on a chain rather than in a test: the sample account,
  # registered with the committed proofs. It leaves a leaf in the accounts tree, which is what the
  # prover's indexer needs to have something real to read.
  "script/PrivateRegister.s.sol:PrivateRegister"
)
# The ramp needs a Stargate V2 pool, which only exists on a real chain (StargateSepolia.sol pins the
# Arbitrum Sepolia one). It is the only component with no path on anvil, so it runs where it can.
if [ "$CHAIN" = "421614" ]; then
  STEPS+=("script/RampDeal.s.sol:RampDeal")
fi

failed=0
for step in "${STEPS[@]}"; do
  name="${step##*:}"
  if HOLDER_PRIVATE_KEY="$KEY" forge script "$step" \
      --rpc-url "$RPC" --broadcast --skip-simulation --private-key "$KEY" \
      "${VERIFY[@]+"${VERIFY[@]}"}" >"/tmp/e2e-$name.log" 2>&1; then
    echo "[OK]   $name"
  else
    echo "[FAIL] $name"
    tail -25 "/tmp/e2e-$name.log"
    failed=1
  fi
done
[ "$failed" -eq 0 ] || { echo "e2e: a deploy or catalog script failed"; exit 1; }

# The scripts' own `require`s run locally; this checks what actually LANDED on the chain.
ESCROW=$(python3 -c "import json;print(json.load(open('deployments/${CHAIN/421614/sepolia}-paths.json'))['escrow'])" 2>/dev/null \
  || python3 -c "import json;print(json.load(open('deployments/$CHAIN-paths.json'))['escrow'])")
cast logs --rpc-url "$RPC" --address "$ESCROW" \
  "Settled(bytes32,uint8,uint256,uint256)" --from-block 0 --json \
  | python3 -c '
import json, sys
NAMES = ["NONE","FUNDED","FIAT_SENT","DISPUTED","RELEASED","RESOLVED_SPLIT","STALEMATE",
         "CANCELLED","ARBITRATION_ACTIVE","RESOLVED_BY_ARBITRATION","CLAIMED","ABANDONED"]
# CASE-CORE-03..15, as PROTOCOLO.md §E.3.9 lists them.
EXPECTED = {"CANCELLED": 6, "RELEASED": 3, "CLAIMED": 1, "RESOLVED_SPLIT": 1, "STALEMATE": 1}
PRINCIPAL = 1_000_000
rows = json.load(sys.stdin)
got = {}
for row in rows:
    d = row["data"][2:]
    w = [d[i:i+64] for i in range(0, len(d), 64)]
    status, holder, provider = NAMES[int(w[0],16)], int(w[1],16), int(w[2],16)  # dealId is topic 1
    got[status] = got.get(status, 0) + 1
    if status == "STALEMATE":
        # Core has no tribunal: a dispute nobody settles is a deadlock and burns the principal (Anexo R,
        # 2026-09-24). It pays nobody; the burn itself is PrincipalBurned, checked below.
        assert holder == 0 and provider == 0, f"a Core deadlock paid {holder}/{provider}"
        continue
    assert holder + provider == PRINCIPAL, f"{status} does not conserve principal: {holder}+{provider}"
assert got == EXPECTED, f"terminal histogram {got} != {EXPECTED}"
print(f"[OK]   {len(rows)} Core terminals on chain, principal conserved in every one")
'

# The one Core terminal that conserves nothing: the deadlock's principal must have left to the burn address,
# exactly once and whole.
cast logs --rpc-url "$RPC" --address "$ESCROW" "PrincipalBurned(bytes32,uint256)" --from-block 0 --json \
  | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert len(rows) == 1, f"expected one burned principal in the Core catalog, got {len(rows)}"
amount = int(rows[0]["data"][2:], 16)
assert amount == 1_000_000, f"the deadlock burned {amount}, not the principal"
print("[OK]   the Core deadlock burned the principal, whole")
'

# The prover's chain reader and the recovery property, against the tree the run just put a leaf in.
# Skips itself if bun is absent; the point is that both are checked against a REAL tree rather than
# a fixture -- a fixture cannot show that a secret finds its own leaf in a tree a contract owns.
if command -v bun >/dev/null 2>&1; then
  TREE=$(python3 -c "import json;print(json.load(open('deployments/${CHAIN/421614/sepolia}-private.json'))['accountTree'])" 2>/dev/null \
    || python3 -c "import json;print(json.load(open('deployments/$CHAIN-private.json'))['accountTree'])")
  ESCROW_PRIV=$(python3 -c "import json;print(json.load(open('deployments/${CHAIN/421614/sepolia}-private.json'))['escrow'])" 2>/dev/null \
    || python3 -c "import json;print(json.load(open('deployments/$CHAIN-private.json'))['escrow'])")
  PLURI_RPC="$RPC" PLURI_TREE="$TREE" PLURI_ESCROW="$ESCROW_PRIV" \
    bun test circuits/js/lib/indexer.test.ts circuits/js/lib/account.test.ts 2>&1 | tail -6
fi

# Finally, ask the doctor whether the records just written still describe the chain. On a chain built
# ten seconds ago every answer must be yes, which is what makes the same script trustworthy when it
# is pointed at a testnet that has been drifting for months.
forge script script/Doctor.s.sol:Doctor --rpc-url "$RPC" -vv 2>&1 | sed -n '/^== Logs ==/,/^$/p'
echo "e2e: green"
