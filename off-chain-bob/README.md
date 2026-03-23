# off-chain-bob

Bob backend CLI for the protocol flow:
- on-chain actions (`deposit`, `commit-verifier-seed`, `choose`, `dispute`, `dispute-ot`)
- off-chain dispute packet preparation (`prepare-dispute`, `prepare-ot-dispute`) using `off-chain-common` consensus logic

## Required environment variables (for on-chain commands)
- `CONTRACT_ADDRESS`: deployed `MillionairesProblem` address
- `BOB_PRIVATE_KEY`: Bob private key

## Optional environment variables
- `RPC_URL`: defaults to `http://127.0.0.1:8545`
- `DEPOSIT_WEI`: defaults to `1000000000000000000` (1 ETH), used by `deposit`

## Commands
- `deposit` (default if no command is provided)
- `commit-verifier-seed [--seed <0x..32>]`
- `choose --m <index>`
- `evaluate-m --y <u64> [--payload-file <path>] [--eval-dir <path>] [--alice-labels-file <path>]`
- `prepare-dispute --instance-id <id> --seed <0x..32> --claimed-leaves-file <path> [--bit-width <bits>] [--gate-index <k>] [--circuit-id <0x..32>] [--expected-root-gc <0x..32>] [--allow-false-challenge]`
- `prepare-ot-dispute --instance-id <id> --verifier-seed <0x..32> [--garbler-seed <0x..32> | --seed <0x..32>] [--bit-width <bits>] [--input-bit <n> --round <0|1|2>] [--circuit-id <0x..32>] [--expected-root-ot <0x..32>] [--allow-false-challenge]`
- `dispute --instance-id <id> --seed <0x..32> --gate-index <k> --gate-type <0|1|2> --wire-a <u16> --wire-b <u16> --wire-c <u16> --leaf-bytes <0x..71> --ih-proof <0x..,0x..> --layout-proof <0x..,0x..>`
- `dispute-ot --instance-id <id> --verifier-seed <0x..32> --input-bit <n> --round <0|1|2>`

## Typical usage
```bash
cd off-chain-bob

# 1) Bob deposit
RPC_URL=http://127.0.0.1:8545 \
CONTRACT_ADDRESS=0x... \
BOB_PRIVATE_KEY=0x... \
cargo run --offline -- deposit

# 2) Bob commits verifier randomness for OT replay
RPC_URL=http://127.0.0.1:8545 \
CONTRACT_ADDRESS=0x... \
BOB_PRIVATE_KEY=0x... \
cargo run --offline -- commit-verifier-seed --seed 0x...

# 3) Bob chooses m
RPC_URL=http://127.0.0.1:8545 \
CONTRACT_ADDRESS=0x... \
BOB_PRIVATE_KEY=0x... \
cargo run --offline -- choose --m 7

# 4) Bob prepares dispute packet from claimed GC leaves of one opened instance
cargo run --offline -- prepare-dispute \
  --instance-id 0 \
  --seed 0x... \
  --claimed-leaves-file /path/to/instance0_leaves.txt \
  --bit-width 8

# 5) Bob prepares OT dispute packet from OT payload hashes already published on-chain by Alice
cargo run --offline -- prepare-ot-dispute \
  --instance-id 0 \
  --garbler-seed 0x... \
  --verifier-seed 0x... \
  --bit-width 8

# 6) Evaluate the chosen m from canonical blob payload + Alice labels
cargo run --offline -- evaluate-m \
  --payload-file /tmp/eval/eval-m-blob.bin \
  --alice-labels-file /tmp/eval/alice-x-labels16.txt \
  --y 42
```

`prepare-dispute` prints:
- mismatch summary (`mismatch_indices`)
- selected gate descriptor and leaf bytes
- `ihProof` and `layoutProof`
- ready-to-run `cast send` template for `disputeGarbledTable`

`prepare-ot-dispute` prints:
- mismatch summary (`mismatch_locations`)
- selected OT `(inputBit, round, author)`
- `rootOT`, selected `payloadHash`, and `otProof`
- values derived from OT payload hashes already published on-chain by Alice
- ready-to-run `cast send` template for `disputePublishedObliviousTransfer`

## Claimed leaves file format
- one 71-byte leaf hex per line
- `0x...` prefix supported
- empty lines and `# comments` are ignored

## Notes
- OT dispute evidence is single-mode in this repo: Alice publishes opened OT payload hashes on-chain.
- Use `prepare-ot-dispute + dispute-ot` for the OT dispute flow.
- `evaluate-m` prefers canonical blob payload (`eval-m-blob.bin` / `--payload-file`) and falls back to legacy split files when blob payload is absent.
