<h1>PoC: Privacy-Preserving Auction</h1>
This is a Proof of Concept for a decentralized, private auction. 
<br>It uses Garbled Circuits to determine if a bid is successful without revealing the bidder's price or the seller's reserve.

## Project Structure
- `contract/`: Solidity smart contracts and Foundry tests for protocol stages and dispute/slashing logic.
- `off-chain-test/`: Shared Rust playground/prototype for garbling, Merkle proofs, and parity vectors.
- `off-chain-alice/`: Rust backend app skeleton for Alice-side off-chain flow.
- `off-chain-bob/`: Rust backend app skeleton for Bob-side off-chain flow.
- `scripts/`: Local helper scripts to start Anvil, run deploy + Bob deposit flow, and check balances.
