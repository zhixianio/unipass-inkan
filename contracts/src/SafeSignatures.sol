// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title Packs owner signatures into Safe's `signatures` bytes
/// @notice Layout (Safe 1.3.0 – 1.5.0): one 65-byte static slot per signature, sorted by owner
/// address ascending, followed by the dynamic parts of contract signatures.
///   - EOA:      r(32) || s(32) || v(1)
///   - contract: bytes32(owner) || bytes32(offset) || 0x00, and at `offset` (counted from the start
///               of `signatures`): uint256(len) || data
library SafeSignatures {
    struct Entry {
        address owner;
        /// @dev 65-byte ECDSA signature for an EOA; for a contract owner, the bytes passed to its
        /// `isValidSignature` (for a WebAuthn signer: the ABI-encoded WebAuthn signature).
        bytes data;
        bool isContract;
    }

    function pack(Entry[] memory entries) internal pure returns (bytes memory signatures) {
        _sort(entries);
        bytes memory statics;
        bytes memory dynamics;
        uint256 offset = entries.length * 65;
        for (uint256 i = 0; i < entries.length; i++) {
            Entry memory e = entries[i];
            if (e.isContract) {
                statics = abi.encodePacked(statics, bytes32(uint256(uint160(e.owner))), bytes32(offset), uint8(0));
                dynamics = abi.encodePacked(dynamics, e.data.length, e.data);
                offset += 32 + e.data.length;
            } else {
                require(e.data.length == 65, "SafeSignatures: bad ECDSA length");
                statics = abi.encodePacked(statics, e.data);
            }
        }
        signatures = abi.encodePacked(statics, dynamics);
    }

    function eoa(address owner, uint8 v, bytes32 r, bytes32 s) internal pure returns (Entry memory) {
        return Entry(owner, abi.encodePacked(r, s, v), false);
    }

    function contractSig(address owner, bytes memory data) internal pure returns (Entry memory) {
        return Entry(owner, data, true);
    }

    function _sort(Entry[] memory entries) private pure {
        for (uint256 i = 1; i < entries.length; i++) {
            Entry memory key = entries[i];
            uint256 j = i;
            while (j > 0 && entries[j - 1].owner > key.owner) {
                entries[j] = entries[j - 1];
                j--;
            }
            entries[j] = key;
        }
    }
}
