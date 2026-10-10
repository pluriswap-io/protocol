---
name: deploy-pool
description: >-
  Deploy an official PluriSwap share pool via the on-chain factory. Use when a
  trader asks to create a pool, vault, or sede de liquidez. Do not compile this
  repo or start Anvil. Do not register the pool on a backend.
---

# Deploy a Pool

The factory is already deployed. The trader sends one transaction. This skill does not run `forge` or Anvil.

## 1. Ask for params

- `sponsors` (one or more; immutable after create; default: connected wallet)
- `token` (settlement ERC-20)
- `controllers` (designated agent wallets; may be empty — sponsors are already agents)
- `openDeposits` (false = private; true = anyone can deposit)
- `depositors` (required if private; must be empty if open)
- `controllerFeeBps` (0–10000; reserved from idle per deal)

One settlement token per pool. Sponsors automatically can be Controllers of deals. An LP who is not a sponsor and not designated cannot.

## 2. Factory address

Read `deployments/<chain>-pool-factory.json` (Sepolia: `deployments/sepolia-pool-factory.json`).

Use:

- `factory`
- `escrow` — the one kernel every pool of this factory points at; the pool cannot choose another
- `officialCodehash`

If the file is missing, stop. The protocol team must run `script/DeployPoolFactory.s.sol` first.

This ABI is the **share vault** with the escrow pinned by the factory (2026-09-29). Do not call the old
`createPool(address[],address,address,address[],bool,address[],uint16)`, which took an escrow.

## 3. Create the pool

Do **not** compile Solidity. Call the factory with `cast` (or viem/ethers) against a public RPC:

```bash
cast send "$FACTORY" \
  "createPool(address[],address,address[],bool,address[],uint16)" \
  "$SPONSORS" "$TOKEN" "$CONTROLLERS" "$OPEN" "$DEPOSITORS" "$FEE_BPS" \
  --rpc-url "$RPC" --private-key "$KEY"
```

Parse the `PoolCreated(address pool, address token, address escrow, bool openDeposits)` log. That `pool` is the Holder.

## 4. Check official

```bash
cast keccak "$(cast code "$POOL" --rpc-url "$RPC")"
# or
cast call "$FACTORY" "isOfficial(address)(bool)" "$POOL" --rpc-url "$RPC"
```

Official = the factory says true: it made this pool, so it runs the published implementation AND points at the
factory's escrow. The codehash alone is not enough — anyone can clone the implementation and point it elsewhere.

Do not POST to a backend. Listing/registry is a later factory deploy, when that service exists.

## 5. Aftercare

To fund: an allowed depositor (or anyone, if open) `approve`s the pool, then `deposit(amount)`. First deposit ≥ `1e6`.

To bound what an agent can commit, a Sponsor calls `setLimits(maxPrincipal, maxControllerExposure, requireCourt)`
(0 = no bound). Without a tribunal, a fight nobody settles burns the pool's principal — `requireCourt` is how a
Sponsor rules that out.

To open a deal: an agent `authorize(ha, mods)` then `escrow.activate` with empty holder signature (EIP-1271). `mods` must name every module the signed `packageIds` refer to — the vault runs the same `Packages.resolve` as the kernel. Idle must cover `principal + controllerFee + activationFee` — the activation fee is the reputation's share plus, on a panel deal, the court's availability share — plus the contest reserve when `reimburseContest` is on. On a panel deal the pool also signs the panel: the agent registers the appointment digest with `approveCourtDigest(nonce, digest)` before activating.

While a live deal is disputed or in court, `deposit` and `redeem` revert `FightInFlight`: the NAV would price a principal the pool may lose. A deadlock that burns the principal pays the Controller no fee.

If the escrow could not push a payout to the pool (a paused or blacklisting token), anyone calls `pullEscrowCredit()`.

`reconcile(nonce)` is permissionless. It reads `dealOf` + `settlementOf` for the Holder nonce; it does not take provider/controller nonces or `returned`.

A kicked or runoff pending auth can `unlock(nonce)` before the HA deadline: the digest would no longer validate, so the reservation is dead. After a total consume (`nav == 0`), LPs `redeem` to burn worthless shares so the vault can close or take a new first deposit.

Fee to list and backend registry: not in this skill.
