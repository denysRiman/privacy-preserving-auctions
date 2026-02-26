//! Off-chain garbling toolkit for the privacy-preserving auction.
//! Modules are split by consensus rules, circuit garbling, Merkle proofs, and scenario wiring.

pub mod consensus;
pub mod cli;
pub mod evaluation;
pub mod garble;
pub mod ih;
pub mod labels;
pub mod merkle;
pub mod scenario;
pub mod types;
