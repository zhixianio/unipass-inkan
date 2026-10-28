// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title What the UniPass Signer builds before asking the Secure Enclave to sign
/// @notice An independent re-implementation of the Signer side of docs/webauthn-signature.md.
/// It does not reuse safe-modules code, so tests comparing it with the on-chain library are a
/// real cross-check.
library WebAuthnEncoding {
    /// @dev P-256 group order.
    uint256 internal constant P256_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551;

    bytes1 internal constant FLAG_UP = 0x01;
    bytes1 internal constant FLAG_UV = 0x04;
    /// @dev UP | UV. The contract only requires UV; UP is set because the SE key requires biometry.
    bytes1 internal constant SIGNER_FLAGS = 0x05;

    string internal constant RP_ID = "unipass.xyz";
    string internal constant CLIENT_DATA_FIELDS = '"origin":"unipass-signer://secure-enclave","crossOrigin":false';

    bytes internal constant _B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    /// @notice base64url without padding of a 32-byte value (always 43 characters).
    function base64Url(bytes32 value) internal pure returns (string memory) {
        bytes memory out = new bytes(43);
        uint256 v = uint256(value);
        // 42 full 6-bit groups cover the top 252 bits; the last 4 bits are left-aligned in a 6-bit group.
        for (uint256 i = 0; i < 42; i++) {
            out[i] = _B64URL[(v >> (250 - 6 * i)) & 0x3f];
        }
        out[42] = _B64URL[(v & 0x0f) << 2];
        return string(out);
    }

    /// @notice `rpIdHash(32) || flags(1) || signCount(4, big endian)`.
    function authenticatorData(bytes32 rpIdHash, bytes1 flags, uint32 signCount) internal pure returns (bytes memory) {
        return abi.encodePacked(rpIdHash, flags, signCount);
    }

    function signerAuthenticatorData() internal pure returns (bytes memory) {
        return authenticatorData(sha256(bytes(RP_ID)), SIGNER_FLAGS, 0);
    }

    /// @notice `{"type":"webauthn.get","challenge":"<b64url>",<fields>}`
    function clientDataJson(bytes32 challenge, string memory fields) internal pure returns (string memory) {
        return string.concat('{"type":"webauthn.get","challenge":"', base64Url(challenge), '",', fields, "}");
    }

    /// @notice The bytes an authenticator signs: `authenticatorData || sha256(clientDataJSON)`.
    /// CryptoKit's `P256.Signing.PrivateKey.signature(for:)` hashes this with SHA-256 itself.
    function signingMessage(bytes32 challenge, bytes memory authData, string memory fields)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(authData, sha256(bytes(clientDataJson(challenge, fields))));
    }

    /// @notice The digest that ECDSA actually signs (and that P256VERIFY receives).
    function signingDigest(bytes32 challenge, bytes memory authData, string memory fields)
        internal
        pure
        returns (bytes32)
    {
        return sha256(signingMessage(challenge, authData, fields));
    }

    function isLowS(uint256 s) internal pure returns (bool) {
        return s <= P256_N / 2;
    }

    function normalizeS(uint256 s) internal pure returns (uint256) {
        return isLowS(s) ? s : P256_N - s;
    }

    /// @notice The signature bytes `SafeWebAuthnSignerProxy` expects:
    /// `abi.encode(bytes authenticatorData, string clientDataFields, uint256 r, uint256 s)`.
    function encodeSignature(bytes memory authData, string memory fields, uint256 r, uint256 s)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(authData, fields, r, s);
    }
}
