#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

########################################################################
# Configuration — adjust as needed
########################################################################
: "${REPO_URL:=git@github.com:matter-labs/zksync-era.git}"
: "${DIR:=zksync-era}"
: "${BRANCH:=kl/medium-interop-support}"

: "${L1_RPC_URL:=http://localhost:8545}"
: "${DB_URL:=postgres://postgres:notsecurepassword@localhost:5432}"
: "${DB_NAME:=zksync_server_localhost_era}"

# Chain IDs
: "${ERA_CHAIN_ID:=271}"
: "${VALIDIUM_CHAIN_ID:=260}"
: "${GATEWAY_CHAIN_ID:=506}"

# RPC Ports
: "${ERA_PORT:=3050}"
: "${VALIDIUM_PORT:=3070}"
: "${GATEWAY_PORT:=3150}"

########################################################################
# Helpers & cleanup
########################################################################
log()   { printf "\n\033[1;32m→ %s\033[0m\n" "$*"; }
warn()  { printf "\033[1;33m⚠️  %s\033[0m\n" "$*"; }
error() { printf "\033[1;31m❌ %s\033[0m\n" "$*"; }

cleanup() {
  error "Cleanup: stopping zkstack containers"
  if [[ -d "$DIR" && -f "$DIR/zkstack.toml" ]]; then
    pushd "$DIR" >/dev/null
    zkstack dev clean all || warn "zkstack dev clean failed"
    popd >/dev/null
  fi
}
trap cleanup INT TERM

########################################################################
# Step functions
########################################################################

clone_or_update_repo() {
  if [[ -d "$DIR/.git" ]]; then
    log "Updating existing repo in '$DIR'"
    pushd "$DIR" >/dev/null
    git fetch origin && git reset --hard origin/$BRANCH
    git submodule update --init --recursive
    popd >/dev/null
  else
    log "Cloning '$REPO_URL' into '$DIR'"
    git clone "$REPO_URL" "$DIR"
    pushd "$DIR" >/dev/null
    git checkout "$BRANCH"
    git submodule update --init --recursive
    popd >/dev/null
  fi
}

checkout_branch() {
  log "Checking out branch '$BRANCH'"
  pushd "$DIR" >/dev/null
  git checkout "$BRANCH"
  git pull --ff-only origin "$BRANCH"
  popd >/dev/null
}

install_zkstack_cli() {
  log "Installing zkstack CLI from local source"
  pushd "$DIR" >/dev/null
  zkstackup --local
  popd >/dev/null
}

bootstrap_era() {
  log "Bootstrapping Era dev chain (chainID=$ERA_CHAIN_ID, port=$ERA_PORT)"
  mkdir -p "$DIR/zruns" "$DIR/zlogs"
  pushd "$DIR" >/dev/null

  zkstack dev clean containers
  zkstack up -o false
  zkstack dev contracts

  # Try ecosystem init; if it fails, regenerate genesis and retry
  if ! zkstack ecosystem init \
      --deploy-paymaster --deploy-erc20 --deploy-ecosystem \
      --l1-rpc-url="$L1_RPC_URL" \
      --server-db-url="$DB_URL" --server-db-name="$DB_NAME" \
      --ignore-prerequisites --observability=false --chain era \
      --update-submodules false; then
    warn "'zkstack ecosystem init' failed; regenerating genesis and retrying"
    zkstack dev generate-genesis
    zkstack ecosystem init \
      --deploy-paymaster --deploy-erc20 --deploy-ecosystem \
      --l1-rpc-url="$L1_RPC_URL" \
      --server-db-url="$DB_URL" --server-db-name="$DB_NAME" \
      --ignore-prerequisites --observability=false --chain era \
      --update-submodules false
  fi

  popd >/dev/null
}

bootstrap_validium() {
  log "Creating Validium chain (chainID=$VALIDIUM_CHAIN_ID, port=$VALIDIUM_PORT)"
  pushd "$DIR" >/dev/null
  zkstack chain create \
    --chain-name validium --chain-id $VALIDIUM_CHAIN_ID --prover-mode no-proofs \
    --wallet-creation localhost --l1-batch-commit-data-generator-mode validium \
    --base-token-address 0x0000000000000000000000000000000000000001 \
    --base-token-price-nominator 1 --base-token-price-denominator 1 \
    --set-as-default false --evm-emulator false \
    --ignore-prerequisites --update-submodules false
  zkstack chain init \
    --deploy-paymaster --l1-rpc-url="$L1_RPC_URL" \
    --server-db-url="$DB_URL" --server-db-name=zksync_server_localhost_validium \
    --chain validium --update-submodules false --validium-type no-da
  popd >/dev/null
}

bootstrap_gateway() {
  log "Creating Gateway chain (chainID=$GATEWAY_CHAIN_ID, port=$GATEWAY_PORT)"
  pushd "$DIR" >/dev/null
  zkstack chain create \
    --chain-name gateway --chain-id $GATEWAY_CHAIN_ID --prover-mode no-proofs \
    --wallet-creation localhost --l1-batch-commit-data-generator-mode rollup \
    --base-token-address 0x0000000000000000000000000000000000000001 \
    --base-token-price-nominator 1 --base-token-price-denominator 1 \
    --set-as-default false --evm-emulator false \
    --ignore-prerequisites --update-submodules false
  zkstack chain init \
    --deploy-paymaster --l1-rpc-url="$L1_RPC_URL" \
    --server-db-url="$DB_URL" --server-db-name=zksync_server_localhost_gateway \
    --chain gateway --update-submodules false
  popd >/dev/null
}

bridge_to_era() {
  log "Bridging ETH + token to Era"
  pushd "$DIR" >/dev/null
  zkstack server --ignore-prerequisites --chain era &> zruns/era1.log &
  ERA_PID=$!
  ./infrastructure/scripts/bridge_eth_to_era.sh $ERA_CHAIN_ID
  ./infrastructure/scripts/bridge_token_to_era.sh $ERA_CHAIN_ID
  zkstack server wait --ignore-prerequisites --verbose --chain era
  kill "$ERA_PID" || true
  sleep 10
  popd >/dev/null
}

convert_and_migrate() {
  log "Converting Gateway & migrating chains"
  pushd "$DIR" >/dev/null
  zkstack chain gateway convert-to-gateway --chain gateway --ignore-prerequisites
  zkstack dev config-writer --path etc/env/file_based/overrides/tests/gateway.yaml --chain gateway
  zkstack server --ignore-prerequisites --chain gateway &> zruns/gateway.log &
  GATEWAY_PID=$!
  zkstack server wait --ignore-prerequisites --verbose --chain gateway
  sleep 10
  zkstack chain gateway migrate-to-gateway --chain era --gateway-chain-name gateway
  zkstack chain gateway migrate-to-gateway --chain validium --gateway-chain-name gateway
  kill "$GATEWAY_PID" || true
  popd >/dev/null
}

spin_up_chains() {
  log "Spinning up Era & Validium services"
  pushd "$DIR" >/dev/null
  zkstack server --ignore-prerequisites --chain era &> zruns/era.log &
  PID_ERA=$!
  zkstack server --ignore-prerequisites --chain validium &> zruns/validium.log &
  PID_VALIDIUM=$!
  zkstack server wait --ignore-prerequisites --verbose --chain era
  zkstack server wait --ignore-prerequisites --verbose --chain validium
  popd >/dev/null
}

final_setup() {
  log "Final token migration & test wallet init"
  pushd "$DIR" >/dev/null
  zkstack chain gateway migrate-token-balances --to-gateway --chain era --gateway-chain-name gateway
  zkstack dev init-test-wallet --chain era
  zkstack dev init-test-wallet --chain validium
  popd >/dev/null
}

main() {
  clone_or_update_repo
  checkout_branch
  install_zkstack_cli
  bootstrap_era
  bootstrap_validium
  bootstrap_gateway
  bridge_to_era
  convert_and_migrate
  spin_up_chains
  final_setup

  log "✅ Environment ready — all tasks completed successfully."
  log "Chain endpoints & logs:"
  printf "  Era      (chainID=%s)      -> http://localhost:%s    Logs: %s/zruns/era.log\n" "$ERA_CHAIN_ID" "$ERA_PORT" "$DIR"
  printf "  Validium (chainID=%s)      -> http://localhost:%s    Logs: %s/zruns/validium.log\n" "$VALIDIUM_CHAIN_ID" "$VALIDIUM_PORT" "$DIR"
  printf "  Gateway  (chainID=%s)      -> http://localhost:%s    Logs: %s/zruns/gateway.log\n" "$GATEWAY_CHAIN_ID" "$GATEWAY_PORT" "$DIR"
  log "Your funded rich account is 0x36615cf349d7f6344891b1e7ca7c72883f5dc049"
  log "To stream logs, run: tail -f <path/to/log>"
  log "To stop all services, run: zkstack dev clean all"
  log "To clean up, run: zkstack dev clean containers"
}

main "$@"
