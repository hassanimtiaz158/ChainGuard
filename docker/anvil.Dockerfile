# syntax=docker/dockerfile:1
#
# Local lab chain. Anvil is pinned to the release the repository is developed
# against; the chain ID is passed as a command-line flag in docker-compose.yml
# and must remain 31337 (the only network ChainGuard ever talks to).
FROM ghcr.io/foundry-rs/foundry:v1.8.4

# Test accounts and balances are Anvil's public defaults.
EXPOSE 8545