// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {WebAuthnEncoding} from "../src/WebAuthnEncoding.sol";
import {PasskeyDeployments} from "../src/PasskeyDeployments.sol";
import {SafeSignatures} from "../src/SafeSignatures.sol";

interface IVerifyForSigner {
    function isValidSignatureForSigner(
        bytes32 message,
        bytes calldata signature,
        uint256 x,
        uint256 y,
        uint176 verifiers
    ) external view returns (bytes4);
}

/// @notice Writes testvectors/webauthn/*.json. No RPC, no broadcast:
///   forge script script/GenerateWebAuthnVectors.s.sol
/// `expectedValid` is not hand-written: each vector is checked by the passkey v0.2.1 singleton
/// (built from lib/) with the default verifiers (0x100 precompile + FCL fallback etched at its
/// canonical address).
contract GenerateWebAuthnVectors is Script {
    string internal constant DIR = "../testvectors/webauthn/";

    struct Case {
        string name;
        string description;
        string keyLabel;
        bytes32 challenge; // what Safe passes to the signer (verifier side)
        bytes32 signedChallenge; // what was actually signed
        bytes1 flags;
        string fields; // clientDataFields sent on-chain
        string signedFields; // clientDataFields that were signed
        bool highS;
        bool padded;
    }

    IVerifyForSigner internal factory;

    function run() external {
        factory = IVerifyForSigner(vm.deployCode("SafeWebAuthnSignerFactory.sol:SafeWebAuthnSignerFactory"));
        vm.etch(PasskeyDeployments.FCL_P256_VERIFIER, vm.deployCode("FCLP256Verifier.sol:FCLP256Verifier").code);

        string memory f = WebAuthnEncoding.CLIENT_DATA_FIELDS;
        string memory other = '"origin":"https://example.test"';
        bytes32 c1 = keccak256("unipass-inkan/webauthn/vector-1");
        bytes32 c2 = keccak256("unipass-inkan/webauthn/vector-2");
        bytes32 zero = bytes32(0);
        bytes32 ones = bytes32(type(uint256).max);

        // forgefmt: disable-start
        _write(Case("valid-basic", "Signer default: flags UP|UV, default clientDataFields, low s.", "key-1", c1, c1, 0x05, f, f, false, false));
        _write(Case("valid-challenge-zero", "All-zero challenge: base64url is 43 x 'A'.", "key-2", zero, zero, 0x05, f, f, false, false));
        _write(Case("valid-challenge-ones", "All-ones challenge: exercises '_' and the final 4-bit group.", "key-2", ones, ones, 0x05, f, f, false, false));
        _write(Case("valid-uv-only", "Flags 0x04 (UV without UP) are accepted on-chain; the Signer still uses 0x05.", "key-1", c1, c1, 0x04, f, f, false, false));
        _write(Case("valid-other-fields", "Any clientDataFields work as long as they are what was signed.", "key-1", c2, c2, 0x05, other, other, false, false));
        _write(Case("high-s-accepted", "s replaced by n - s. Accepted on-chain (no malleability check) but NOT canonical: the Signer must never emit it.", "key-1", c1, c1, 0x05, f, f, true, false));
        _write(Case("invalid-flags-up-only", "Flags 0x01 (UP only): rejected, UV is required.", "key-1", c1, c1, 0x01, f, f, false, false));
        _write(Case("invalid-wrong-challenge", "Signed vector-2's challenge, verified against vector-1's.", "key-1", c1, c2, 0x05, f, f, false, false));
        _write(Case("invalid-tampered-fields", "clientDataFields changed after signing.", "key-1", c1, c1, 0x05, '"origin":"https://evil.example"', f, false, false));
        _write(Case("invalid-padded", "32 zero bytes appended to an otherwise valid signature: rejected by the length bound.", "key-1", c1, c1, 0x05, f, f, false, true));
        // forgefmt: disable-end
    }

    function _key(string memory label) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("unipass-inkan/testvector/p256/", label)))
            % (WebAuthnEncoding.P256_N - 1) + 1;
    }

    function _write(Case memory c) internal {
        uint256 key = _key(c.keyLabel);
        bytes memory authData = WebAuthnEncoding.authenticatorData(sha256(bytes(WebAuthnEncoding.RP_ID)), c.flags, 0);
        (uint256 r, uint256 s) = _sign(key, WebAuthnEncoding.signingDigest(c.signedChallenge, authData, c.signedFields));
        if (c.highS) s = WebAuthnEncoding.P256_N - s;
        bytes memory signature = WebAuthnEncoding.encodeSignature(authData, c.fields, r, s);
        if (c.padded) signature = abi.encodePacked(signature, bytes32(0));

        string memory json = string.concat("{\n", _kv("name", _str(c.name)), _kv("description", _str(c.description)));
        json = string.concat(json, _keyFields(key));
        json = string.concat(json, _kv("challenge", _hex(c.challenge)), _kv("signedChallenge", _hex(c.signedChallenge)));
        json = string.concat(json, _authFields(c.flags, authData));
        json = string.concat(json, _derivedFields(c.challenge, authData, c.fields));
        json = string.concat(json, _kv("r", _hex(bytes32(r))), _kv("s", _hex(bytes32(s))));
        json = string.concat(json, _kv("lowS", vm.toString(WebAuthnEncoding.isLowS(s))));
        json = string.concat(json, _kv("signature", _hex(signature)));
        json = string.concat(json, _safeFields(key, c.challenge, signature), "}\n");
        vm.writeFile(string.concat(DIR, c.name, ".json"), json);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (uint256 r, uint256 s) {
        (bytes32 r_, bytes32 s_) = vm.signP256(key, digest);
        return (uint256(r_), WebAuthnEncoding.normalizeS(uint256(s_)));
    }

    function _keyFields(uint256 key) internal pure returns (string memory) {
        (uint256 x, uint256 y) = vm.publicKeyP256(key);
        return
            string.concat(_kv("privateKey", _hex(bytes32(key))), _kv("x", _hex(bytes32(x))), _kv("y", _hex(bytes32(y))));
    }

    function _authFields(bytes1 flags, bytes memory authData) internal pure returns (string memory) {
        string memory out = string.concat(
            _kv("rpId", _str(WebAuthnEncoding.RP_ID)), _kv("rpIdHash", _hex(sha256(bytes(WebAuthnEncoding.RP_ID))))
        );
        return string.concat(
            out,
            _kv("flags", _hex(abi.encodePacked(flags))),
            _kv("signCount", "0"),
            _kv("authenticatorData", _hex(authData))
        );
    }

    /// @dev Verifier-side values recomputed from `challenge` and the on-chain fields.
    function _derivedFields(bytes32 challenge, bytes memory authData, string memory fields)
        internal
        pure
        returns (string memory out)
    {
        string memory cdj = WebAuthnEncoding.clientDataJson(challenge, fields);
        out = string.concat(
            _kv("clientDataFields", _str(fields)),
            _kv("challengeBase64Url", _str(WebAuthnEncoding.base64Url(challenge))),
            _kv("clientDataJSON", _str(cdj)),
            _kv("clientDataHash", _hex(sha256(bytes(cdj))))
        );
        out = string.concat(
            out,
            _kv("signingMessage", _hex(WebAuthnEncoding.signingMessage(challenge, authData, fields))),
            _kv("signingDigest", _hex(WebAuthnEncoding.signingDigest(challenge, authData, fields)))
        );
    }

    function _safeFields(uint256 key, bytes32 challenge, bytes memory signature)
        internal
        view
        returns (string memory out)
    {
        (uint256 x, uint256 y) = vm.publicKeyP256(key);
        uint176 verifiers = PasskeyDeployments.defaultVerifiers();
        address signer = PasskeyDeployments.canonicalSignerAddress(x, y, verifiers);
        SafeSignatures.Entry[] memory e = new SafeSignatures.Entry[](1);
        e[0] = SafeSignatures.contractSig(signer, signature);
        bool valid = factory.isValidSignatureForSigner(challenge, signature, x, y, verifiers) == bytes4(0x1626ba7e);

        out = string.concat(
            _kv("verifiers", _hex(abi.encodePacked(verifiers))),
            _kv("signerFactory", _str(vm.toString(PasskeyDeployments.SIGNER_FACTORY))),
            _kv("signerSingleton", _str(vm.toString(PasskeyDeployments.SIGNER_SINGLETON)))
        );
        out = string.concat(out, _kv("signerAddress", _str(vm.toString(signer))));
        out = string.concat(out, _kv("safeSignature", _hex(SafeSignatures.pack(e))));
        out = string.concat(out, '  "expectedValid": ', vm.toString(valid), "\n");
    }

    // ---------------------------------------------------------------- JSON

    /// @dev One `"key": value,` line; `v` is already JSON.
    function _kv(string memory k, string memory v) internal pure returns (string memory) {
        return string.concat('  "', k, '": ', v, ",\n");
    }

    function _hex(bytes32 v) internal pure returns (string memory) {
        return _str(vm.toString(v));
    }

    function _hex(bytes memory v) internal pure returns (string memory) {
        return _str(vm.toString(v));
    }

    /// @dev JSON string literal; our inputs only need `"` and `\` escaped.
    function _str(string memory v) internal pure returns (string memory) {
        bytes memory b = bytes(v);
        bytes memory out;
        for (uint256 i = 0; i < b.length; i++) {
            if (b[i] == '"' || b[i] == "\\") out = abi.encodePacked(out, "\\");
            out = abi.encodePacked(out, b[i]);
        }
        return string.concat('"', string(out), '"');
    }
}
