# off-chain-bob

Minimal Bob backend entrypoint to call `deposit()` on `MillionairesProblem`.

## Required environment variables
- `CONTRACT_ADDRESS`: deployed `MillionairesProblem` address
- `BOB_PRIVATE_KEY`: private key for the Bob address configured in contract constructor

## Optional environment variables
- `RPC_URL`: defaults to `http://127.0.0.1:8545`
- `DEPOSIT_WEI`: defaults to `1000000000000000000` (1 ETH)

## Run
```bash
cd off-chain-bob
RPC_URL=http://127.0.0.1:8545 \
CONTRACT_ADDRESS=0x... \
BOB_PRIVATE_KEY=0x... \
cargo run
```

The program prints:
- stage before deposit
- configured Bob address from contract
- signer address derived from private key
- tx output from `cast send`
- Bob vault balance after deposit
- stage after deposit
