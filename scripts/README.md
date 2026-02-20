# Local Scripts

- `start_anvil.sh`: starts local Anvil node on `127.0.0.1:8545` (overridable with `HOST`/`PORT`).
- `local_bob_deposit.sh`: deploys `MillionairesProblem` and runs Bob `deposit()` through `off-chain-bob`.
- `check_balances.sh`: prints Alice/Bob wallet balances, vault balances, and contract balance.

## Quick Start

1. Start chain:
```bash
./start_anvil.sh
```

2. In another terminal run end-to-end flow:
```bash
./local_bob_deposit.sh
```

3. Check balances:
```bash
./check_balances.sh
```

## Optional Overrides

You can override defaults by exporting env vars before running:
- `RPC_URL`
- `ALICE_PK`
- `BOB_PK`
- `DEPOSIT_WEI`
- `CIRCUIT_ID`
- `LAYOUT_ROOT`
- `CONTRACT_ADDRESS` (for `check_balances.sh`; if missing, script tries `/tmp/local_bob_deploy.log`)
- `EXPECTED_CONTRACT_WEI` (default: `1000000000000000000`)
