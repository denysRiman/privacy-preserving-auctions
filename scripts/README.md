# Local Scripts

- `start_anvil.sh`: starts local Anvil node on `127.0.0.1:8545` with zero-gas defaults (`base_fee=0`, `gas_price=0`).
- `demo_protocol_cases.sh`: pretty CLI demo of 3 protocol scenarios with 5-second phase pauses.

## Demo Run

1. Start chain:
```bash
./start_anvil.sh
```

2. In another terminal run all scenarios:
```bash
./demo_protocol_cases.sh all
```

Scenarios:
- `success`: normal happy path, protocol completes and settles.
- `alice-cheat`: Alice commits tampered garbling, Bob disputes and slashes Alice.
- `bob-cheat`: Bob false-challenges honest Alice, Bob is slashed and Alice gets collateral.

For every scenario, the script deploys contract, then resets balances before Phase 1:
- Alice starts with `3 ETH`
- Bob starts with `5 ETH`

The demo enforces exact final balances by default (`STRICT_BALANCE_CHECK=1`):
- `success` -> Bob `5 ETH`, Alice `3 ETH`
- `alice-cheat` -> Bob `6 ETH`, Alice `2 ETH`
- `bob-cheat` -> Bob `4 ETH`, Alice `4 ETH`

## Run One Scenario

```bash
./demo_protocol_cases.sh success
./demo_protocol_cases.sh alice-cheat
./demo_protocol_cases.sh bob-cheat
```

## Optional Overrides

You can override defaults by exporting env vars before running:
- `RPC_URL`
- `ALICE_PK`
- `BOB_PK`
- `BIT_WIDTH`
- `M_CHOICE` (`random` by default, or fixed integer `0..9`)
- `DEPOSIT_WEI`
- `PAUSE_SECONDS` (default: `5`)
- `WORK_ROOT` (default: `/tmp/auction-demo-cases`)
- `ALICE_START_BALANCE_HEX` (default: `0x29a2241af62c0000`, 3 ETH)
- `BOB_START_BALANCE_HEX` (default: `0x4563918244f40000`, 5 ETH)
- `TX_LEGACY` (default: `1`)
- `TX_GAS_PRICE_WEI` (default: `0`)
- `STRICT_BALANCE_CHECK` (default: `1`)
- `BASE_FEE_WEI`/`GAS_PRICE_WEI` for `start_anvil.sh` (both default `0`)
