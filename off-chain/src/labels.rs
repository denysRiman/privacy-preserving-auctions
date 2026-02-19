/// Reads the permutation bit (LSB of first label byte), same convention as Solidity.
pub fn get_permutation_bit(label: [u8; 16]) -> u8 {
    label[0] & 1
}
