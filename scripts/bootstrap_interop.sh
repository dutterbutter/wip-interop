#!/usr/bin/env bash
set -eEuo pipefail

########################################################################
# Configuration – adjust if needed
########################################################################
: "${REPO_URL:=git@github.com:matter-labs/zksync-era.git}"
: "${DIR:=zksync-era}"
: "${BRANCH:=kl/medium-interop-support}"

: "${L1_RPC_URL:=http://localhost:8545}"
: "${DB_URL:=postgres://postgres:notsecurepassword@localhost:5432}"
: "${DB_NAME:=zksync_server_localhost_era}"

########################################################################
# Helpers & cleanup
########################################################################
log()   { printf "\n\033[1;32m→ %s\033[0m\n" "$*"; }
warn()  { printf "\033[1;33m⚠️  %s\033[0m\n"  "$*"; }
error() { printf "\033[1;31m❌ %s\033[0m\n"  "$*"; }

cleanup() {
  error "Error encountered – cleaning up any running zkstack containers…"
  if [[ -d "$DIR" && -f "$DIR/zkstack.toml" ]]; then
    (cd "$DIR" && zkstack dev clean all) || warn "zkstack dev clean failed"
  fi
}
trap cleanup ERR

########################################################################
# 1. Clone or update repo
########################################################################
if [[ -d "$DIR" ]]; then
  if [[ -d "$DIR/.git" ]]; then
    log "Repo '$DIR' exists – fetching latest refs…"
    (cd "$DIR" && git fetch origin)
  else
    error "Directory '$DIR' exists but is not a git repository."
    exit 1
  fi
else
  log "Cloning '$REPO_URL' into '$DIR'…"
  git clone "$REPO_URL" "$DIR"
fi

########################################################################
# 2. Checkout branch & pull
########################################################################
log "Checking out branch '$BRANCH'…"
(
  cd "$DIR"
  git checkout "$BRANCH"
  git pull --ff-only origin "$BRANCH"
)

########################################################################
# 3. (Re)install zkstack CLI from local source
########################################################################
log "Installing zkstack CLI from local checkout…"
(
  cd "$DIR"
  zkstackup --local              # same flag you used previously
)

########################################################################
# 4. Bootstrap Elastic‑style multi‑chain environment
########################################################################
log "Bootstrapping chains – this will take a while…"
(
  cd "$DIR"

  # Ensure directories for logs exist
  mkdir -p zruns zlogs

  ######################################################################
  # Era dev chain
  ######################################################################
  zkstack dev clean containers
  zkstack up -o false
  zkstack dev contracts
  zkstack dev generate-genesis

  zkstack ecosystem init --deploy-paymaster --deploy-erc20 \
    --deploy-ecosystem --l1-rpc-url="$L1_RPC_URL" \
    --server-db-url="$DB_URL" \
    --server-db-name="$DB_NAME" \
    --ignore-prerequisites --observability=false \
    --chain era --update-submodules false

  ######################################################################
  # Validium chain
  ######################################################################
  zkstack chain create \
    --chain-name validium \
    --chain-id 260 \
    --prover-mode no-proofs \
    --wallet-creation localhost \
    --l1-batch-commit-data-generator-mode validium \
    --base-token-address 0x0000000000000000000000000000000000000001 \
    --base-token-price-nominator 1 \
    --base-token-price-denominator 1 \
    --set-as-default false \
    --evm-emulator false \
    --ignore-prerequisites --update-submodules false

  zkstack chain init \
    --deploy-paymaster \
    --l1-rpc-url="$L1_RPC_URL" \
    --server-db-url="$DB_URL" \
    --server-db-name=zksync_server_localhost_validium \
    --chain validium --update-submodules false \
    --validium-type no-da

  ######################################################################
  # Gateway chain
  ######################################################################
  zkstack chain create \
    --chain-name gateway \
    --chain-id 506 \
    --prover-mode no-proofs \
    --wallet-creation localhost \
    --l1-batch-commit-data-generator-mode rollup \
    --base-token-address 0x0000000000000000000000000000000000000001 \
    --base-token-price-nominator 1 \
    --base-token-price-denominator 1 \
    --set-as-default false \
    --evm-emulator false \
    --ignore-prerequisites --update-submodules false

  zkstack chain init \
    --deploy-paymaster \
    --l1-rpc-url="$L1_RPC_URL" \
    --server-db-url="$DB_URL" \
    --server-db-name=zksync_server_localhost_gateway \
    --chain gateway --update-submodules false

  ######################################################################
  # Bridge ETH + token to Era
  ######################################################################
  zkstack server --ignore-prerequisites --chain era &> ./zruns/era1.log &
  ./infrastructure/scripts/bridge_eth_to_era.sh 271
  ./infrastructure/scripts/bridge_token_to_era.sh 271

  zkstack server wait --ignore-prerequisites --verbose --chain era
  ./infrastructure/scripts/bridge_token_from_era.sh 271
  pkill -9 zksync_server
  sleep 10

  ######################################################################
  # Convert Gateway & migrate
  ######################################################################
  zkstack chain gateway convert-to-gateway --chain gateway --ignore-prerequisites
  zkstack dev config-writer --path etc/env/file_based/overrides/tests/gateway.yaml --chain gateway
  zkstack server --ignore-prerequisites --chain gateway &> ./zruns/gateway.log &
  zkstack server wait --ignore-prerequisites --verbose --chain gateway
  sleep 10

  zkstack chain gateway migrate-to-gateway --chain era --gateway-chain-name gateway
  zkstack chain gateway migrate-to-gateway --chain validium --gateway-chain-name gateway

  ######################################################################
  # Spin up all chains
  ######################################################################
  zkstack server --ignore-prerequisites --chain era &> ./zruns/era.log &
  zkstack server --ignore-prerequisites --chain validium &> ./zruns/validium.log &
  zkstack server wait --ignore-prerequisites --verbose --chain era
  zkstack server wait --ignore-prerequisites --verbose --chain validium

  ######################################################################
  # Final token balance migration & test wallet setup
  ######################################################################
  zkstack chain gateway migrate-token-balances --to-gateway --chain era --gateway-chain-name gateway

  zkstack dev init-test-wallet --chain era
  zkstack dev init-test-wallet --chain validium


log "✅ Environment ready - all tasks completed successfully."
