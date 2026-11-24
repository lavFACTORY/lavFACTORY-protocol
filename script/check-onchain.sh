#!/usr/bin/env bash
# Verifies onchain protocol state for lavFACTORY on Robinhood Chain (chainid 4663).
set -euo pipefail

RPC="${ROBINHOOD_RPC_URL:?set ROBINHOOD_RPC_URL}"

FACTORY=0x262d4d478eFe72Eb1731310a4f7A252644aA4B5F
TREASURY=0xeDbc87E40491b9edF65940acF63A5c0E81d8a4f1
REGISTRY=0x000000006551c19487814612e58FE06813775758
IMPL=0xC55D74fba44eb126ef5F6FbCcb93e443d4f40902

# Getters verified against LavFactory.sol
GET_TREASURY='protocolTreasury()(address)'
GET_REGISTRY='erc6551Registry()(address)'
GET_IMPL='erc6551Implementation()(address)'
GET_FEE='CREATION_FEE()(uint256)'
GET_IS_VAULT='isVault(address)(bool)'
GET_VAULT_AT='allVaults(uint256)(address)'

EXPECTED_FEE=2000000000000000   # 0.002 ETH
EXPECTED_THRESHOLD=2
EXPECTED_OWNERS=3
ZERO=0x0000000000000000000000000000000000000000

lc() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
fail=0
ok()  { echo "OK    $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { [[ "$(lc "$2")" == "$(lc "$3")" ]] && ok "$1" || bad "$1: got $2, expected $3"; }
call() { cast call "$1" "$2" "${@:3}" --rpc-url "$RPC"; }

# 1. Immutable factory wiring
check protocolTreasury      "$(call $FACTORY "$GET_TREASURY")" "$TREASURY"
check erc6551Registry       "$(call $FACTORY "$GET_REGISTRY")" "$REGISTRY"
check erc6551Implementation "$(call $FACTORY "$GET_IMPL")"     "$IMPL"

# 2. Anti-spam creation fee
check CREATION_FEE "$(call $FACTORY "$GET_FEE" | awk '{print $1}')" "$EXPECTED_FEE"

# 3. Vault registry consistency
if FIRST=$(call $FACTORY "$GET_VAULT_AT" 0 2>/dev/null); then
  check "isVault(allVaults[0])" "$(call $FACTORY "$GET_IS_VAULT" "$FIRST")" true
  [[ "$(cast code "$FIRST" --rpc-url "$RPC")" != "0x" ]] && ok "allVaults[0] has code" || bad "allVaults[0] has no code"
else
  echo "SKIP  allVaults(0): no vaults yet"
fi
check "isVault(0x0) == false" "$(call $FACTORY "$GET_IS_VAULT" "$ZERO")" false

# 4. Autonomous core (no owner / no admin functions)
for sig in 'owner()(address)' 'admin()(address)'; do
  call $FACTORY "$sig" >/dev/null 2>&1 && bad "factory exposes ${sig%%(*}" || ok "factory has no ${sig%%(*}()"
done

# 5. Bytecode presence across all singletons
for a in $FACTORY $REGISTRY $IMPL $TREASURY; do
  [[ "$(cast code $a --rpc-url "$RPC")" != "0x" ]] && ok "code at $a" || bad "no code at $a"
done

# 6. Protocol Treasury Safe threshold (2-of-3)
check safe-threshold "$(call $TREASURY 'getThreshold()(uint256)' | awk '{print $1}')" "$EXPECTED_THRESHOLD"
check safe-owners    "$(call $TREASURY 'getOwners()(address[])' | tr ',' '\n' | grep -c 0x)" "$EXPECTED_OWNERS"

exit $fail
