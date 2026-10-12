# syntax=docker/dockerfile:1
#
# One-shot lab deployer. Deploys every scenario contract to the local Anvil
# chain (chain ID 31337) and publishes `deployments/lab.json` onto the shared
# lab volume. The contracts tree -- including the vendored `lib/` -- is
# bind-mounted at /app by docker-compose.yml, so this image only needs to carry
# the pinned Foundry toolchain.
FROM ghcr.io/foundry-rs/foundry:v1.8.4

WORKDIR /app

# Anvil account #0 from the public default mnemonic; it starts unlocked, so
# `forge script --unlocked` can sign the deployment transactions with it.
ENV RPC_URL=http://anvil:8545 \
    DEPLOYER_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
    LAB_STATE_DIR=/lab

# `forge script` simulates the run, then broadcasts it; the JSON is copied onto
# the lab volume where the api and worker read it.
CMD ["sh", "-c", "forge script script/DeployLab.s.sol --rpc-url \"$RPC_URL\" --broadcast --slow --unlocked --sender \"$DEPLOYER_ADDRESS\" && mkdir -p \"$LAB_STATE_DIR\" && cp deployments/lab.json \"$LAB_STATE_DIR/lab.json\""]
