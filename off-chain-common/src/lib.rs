//! Off-chain garbling toolkit for the privacy-preserving auction.
//! Modules are split by consensus rules, circuit garbling, Merkle proofs, and scenario wiring.

pub mod auction_outcome;
pub mod cli;
pub mod consensus;
pub mod eip4844;
pub mod eval_blob;
pub mod evaluation;
pub mod garble;
pub mod ih;
pub mod labels;
pub mod merkle;
pub mod ot;
pub mod scenario;
pub mod settlement;
pub mod types;
