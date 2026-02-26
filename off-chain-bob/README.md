# off-chain-bob

Bob backend CLI for the protocol flow:
- on-chain actions (`deposit`, `choose`, `dispute`)
- off-chain dispute packet preparation (`prepare-dispute`) using `off-chain-common` consensus logic

## Required environment variables (for on-chain commands)
- `CONTRACT_ADDRESS`: deployed `MillionairesProblem` address
- `BOB_PRIVATE_KEY`: Bob private key

## Optional environment variables
- `RPC_URL`: defaults to `http://127.0.0.1:8545`
- `DEPOSIT_WEI`: defaults to `1000000000000000000` (1 ETH), used by `deposit`

## Commands
- `deposit` (default if no command is provided)
- `choose --m <index>`
- `prepare-dispute --instance-id <id> --seed <0x..32> --claimed-leaves-file <path> [--bit-width <bits>] [--gate-index <k>] [--circuit-id <0x..32>] [--expected-root-gc <0x..32>] [--allow-false-challenge]`
- `dispute --instance-id <id> --seed <0x..32> --gate-index <k> --gate-type <0|1|2> --wire-a <u16> --wire-b <u16> --wire-c <u16> --leaf-bytes <0x..71> --ih-proof <0x..,0x..> --layout-proof <0x..,0x..>`

## Typical usage
```bash
cd off-chain-bob

# 1) Bob deposit
RPC_URL=http://127.0.0.1:8545 \
CONTRACT_ADDRESS=0x... \
BOB_PRIVATE_KEY=0x... \
cargo run --offline -- deposit

# 2) Bob chooses m
RPC_URL=http://127.0.0.1:8545 \
CONTRACT_ADDRESS=0x... \
BOB_PRIVATE_KEY=0x... \
cargo run --offline -- choose --m 7

# 3) Bob prepares dispute packet from claimed GC leaves of one opened instance
cargo run --offline -- prepare-dispute \
  --instance-id 0 \
  --seed 0x... \
  --claimed-leaves-file /path/to/instance0_leaves.txt \
  --bit-width 8
```

`prepare-dispute` prints:
- mismatch summary (`mismatch_indices`)
- selected gate descriptor and leaf bytes
- `ihProof` and `layoutProof`
- ready-to-run `cast send` template for `disputeGarbledTable`

## Claimed leaves file format
- one 71-byte leaf hex per line
- `0x...` prefix supported
- empty lines and `# comments` are ignored
