// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {WebAuthnEncoding} from "../src/WebAuthnEncoding.sol";
import {SafeSignatures} from "../src/SafeSignatures.sol";
import {PasskeyDeployments} from "../src/PasskeyDeployments.sol";
import {IWebAuthnSignerFactory} from "../src/Interfaces.sol";
import {SafeWebAuthnSignerProxy} from "safe-passkey/SafeWebAuthnSignerProxy.sol";

interface ITestWebAuthnLib {
    function encodeClientDataJson(bytes32 challenge, string calldata clientDataFields)
        external
        pure
        returns (string memory);
    function encodeSigningMessage(bytes32 challenge, bytes calldata authenticatorData, string calldata clientDataFields)
        external
        view
        returns (bytes memory);
}

/// @notice Our Signer-side encoder against the safe-modules WebAuthn library, plus the committed
/// test vectors against the singleton built from source.
contract WebAuthnEncodingTest is Test {
    ITestWebAuthnLib internal lib;
    IWebAuthnSignerFactory internal factory;

    function setUp() public {
        lib = ITestWebAuthnLib(vm.deployCode("TestWebAuthnLib.sol:TestWebAuthnLib"));
        factory = IWebAuthnSignerFactory(vm.deployCode("SafeWebAuthnSignerFactory.sol:SafeWebAuthnSignerFactory"));
        vm.etch(PasskeyDeployments.FCL_P256_VERIFIER, vm.deployCode("FCLP256Verifier.sol:FCLP256Verifier").code);
    }

    function test_base64UrlKnownAnswers() public pure {
        assertEq(WebAuthnEncoding.base64Url(bytes32(0)), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        assertEq(WebAuthnEncoding.base64Url(bytes32(type(uint256).max)), "__________________________________________8");
        // sha256("") in base64url, as produced by any standard encoder.
        assertEq(WebAuthnEncoding.base64Url(sha256("")), "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU");
    }

    function testFuzz_clientDataJsonMatchesLibrary(bytes32 challenge, string calldata fields) public view {
        assertEq(WebAuthnEncoding.clientDataJson(challenge, fields), lib.encodeClientDataJson(challenge, fields));
    }

    function testFuzz_signingMessageMatchesLibrary(bytes32 challenge, bytes calldata authData, string calldata fields)
        public
        view
    {
        assertEq(
            WebAuthnEncoding.signingMessage(challenge, authData, fields),
            lib.encodeSigningMessage(challenge, authData, fields)
        );
    }

    function test_signerAuthenticatorData() public pure {
        bytes memory a = WebAuthnEncoding.signerAuthenticatorData();
        assertEq(a.length, 37);
        assertEq(a[32], bytes1(0x05));
    }

    function testFuzz_normalizeS(uint256 s) public pure {
        s = bound(s, 1, WebAuthnEncoding.P256_N - 1);
        uint256 n = WebAuthnEncoding.normalizeS(s);
        assertTrue(WebAuthnEncoding.isLowS(n));
        assertTrue(n == s || n == WebAuthnEncoding.P256_N - s);
    }

    /// The signer address formula reproduces the factory's CREATE2 (with this build's proxy code).
    function testFuzz_signerAddressFormula(uint256 x, uint256 y, uint176 verifiers) public view {
        assertEq(
            PasskeyDeployments.signerAddress(
                address(factory), type(SafeWebAuthnSignerProxy).creationCode, factory.SINGLETON(), x, y, verifiers
            ),
            factory.getSigner(x, y, verifiers)
        );
    }

    function test_verifiersPacking() public pure {
        assertEq(PasskeyDeployments.defaultVerifiers(), uint176(0x0100445a0683e494ea0c5AF3E83c5159fBE47Cf9e765));
    }

    function test_safeSignaturesSortedWithDynamicTail() public pure {
        SafeSignatures.Entry[] memory e = new SafeSignatures.Entry[](3);
        e[0] = SafeSignatures.contractSig(address(0x30), hex"aabb");
        e[1] = SafeSignatures.eoa(address(0x20), 27, bytes32(uint256(1)), bytes32(uint256(2)));
        e[2] = SafeSignatures.contractSig(address(0x10), hex"cc");
        bytes memory packed = SafeSignatures.pack(e);
        bytes memory expected = abi.encodePacked(
            abi.encodePacked(bytes32(uint256(0x10)), bytes32(uint256(195)), uint8(0)), // 3 * 65 = 195
            abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27)),
            abi.encodePacked(bytes32(uint256(0x30)), bytes32(uint256(195 + 32 + 1)), uint8(0)),
            abi.encodePacked(uint256(1), hex"cc"),
            abi.encodePacked(uint256(2), hex"aabb")
        );
        assertEq(packed, expected);
    }

    /// Every committed vector: recompute it with our encoder and re-check it on the singleton.
    function test_committedVectors() public view {
        Vm.DirEntry[] memory entries = vm.readDir("../testvectors/webauthn");
        uint256 checked;
        for (uint256 i = 0; i < entries.length; i++) {
            if (!vm.contains(entries[i].path, ".json")) continue;
            _checkVector(vm.readFile(entries[i].path));
            checked++;
        }
        assertGe(checked, 2);
    }

    function _checkVector(string memory json) internal view {
        string memory name = vm.parseJsonString(json, ".name");
        bytes32 challenge = vm.parseJsonBytes32(json, ".challenge");
        bytes memory authData = vm.parseJsonBytes(json, ".authenticatorData");
        string memory fields = vm.parseJsonString(json, ".clientDataFields");
        uint256 x = uint256(vm.parseJsonBytes32(json, ".x"));
        uint256 y = uint256(vm.parseJsonBytes32(json, ".y"));
        bytes memory signature = vm.parseJsonBytes(json, ".signature");

        (uint256 px, uint256 py) = vm.publicKeyP256(uint256(vm.parseJsonBytes32(json, ".privateKey")));
        assertEq(px, x, name);
        assertEq(py, y, name);
        assertEq(vm.parseJsonString(json, ".clientDataJSON"), WebAuthnEncoding.clientDataJson(challenge, fields), name);
        assertEq(
            vm.parseJsonBytes32(json, ".signingDigest"),
            WebAuthnEncoding.signingDigest(challenge, authData, fields),
            name
        );
        assertEq(
            vm.parseJsonAddress(json, ".signerAddress"),
            PasskeyDeployments.canonicalSignerAddress(x, y, PasskeyDeployments.defaultVerifiers()),
            name
        );
        bool valid = factory.isValidSignatureForSigner(
                challenge, signature, x, y, PasskeyDeployments.defaultVerifiers()
            ) == bytes4(0x1626ba7e);
        assertEq(valid, vm.parseJsonBool(json, ".expectedValid"), name);
    }
}
