// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {WebAuthnEncoding} from "../src/WebAuthnEncoding.sol";
import {SafeSignatures} from "../src/SafeSignatures.sol";
import {PasskeyDeployments} from "../src/PasskeyDeployments.sol";
import {ISafe, ISafeProxyFactory, IMultiSend, IWebAuthnSignerFactory, IWebAuthnSigner} from "../src/Interfaces.sol";

/// @notice Shared deployment handles and helpers. Concrete contracts fill in the deployment either
/// from source (local) or from canonical Sepolia addresses (fork).
abstract contract SafeWebAuthnBase is Test {
    bytes4 internal constant ERC1271_MAGIC = 0x1626ba7e;
    bytes4 internal constant LEGACY_MAGIC = 0x20c13b0b;

    // Deployment under test.
    address internal safeSingleton;
    ISafeProxyFactory internal proxyFactory;
    address internal fallbackHandler;
    IMultiSend internal multiSendCallOnly;
    IWebAuthnSignerFactory internal signerFactory;
    address internal fclVerifier;
    string internal expectedSafeVersion;

    // Deterministic test keys. Never use outside tests.
    uint256 internal passkeyKey;
    uint256 internal passkeyX;
    uint256 internal passkeyY;
    address internal eoaOwner;
    uint256 internal eoaKey;
    address internal eoaOwner2;
    uint256 internal eoaKey2;

    address payable internal constant RECIPIENT = payable(address(0xBEEF));
    uint256 internal saltNonce = 0x756e6970617373; // "unipass"

    /// @dev Sets every deployment handle above. Returns false when the test should be skipped.
    function _deploy() internal virtual returns (bool);

    /// @dev Per-suite fixtures, run after keys are derived.
    function _afterSetUp() internal virtual;

    function setUp() public {
        if (!_deploy()) {
            vm.skip(true);
            return;
        }
        passkeyKey = uint256(keccak256("unipass-inkan/m0/passkey-1")) % (WebAuthnEncoding.P256_N - 1) + 1;
        (passkeyX, passkeyY) = vm.publicKeyP256(passkeyKey);
        (eoaOwner, eoaKey) = makeAddrAndKey("eoa-owner-1");
        (eoaOwner2, eoaKey2) = makeAddrAndKey("eoa-owner-2");
        _afterSetUp();
    }

    function _defaultVerifiers() internal view returns (uint176) {
        return PasskeyDeployments.verifiers(PasskeyDeployments.P256_PRECOMPILE, fclVerifier);
    }

    // ---------------------------------------------------------------- deployment helpers

    function _initializer(address[] memory owners, uint256 threshold, address to, bytes memory data)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            ISafe.setup, (owners, threshold, to, data, fallbackHandler, address(0), 0, payable(address(0)))
        );
    }

    function _predictSafe(bytes memory initializer, uint256 nonce_) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), nonce_));
        bytes memory initCode = abi.encodePacked(proxyFactory.proxyCreationCode(), uint256(uint160(safeSingleton)));
        return vm.computeCreate2Address(salt, keccak256(initCode), address(proxyFactory));
    }

    function _createSafe(address[] memory owners, uint256 threshold) internal returns (ISafe safe) {
        safe = ISafe(
            proxyFactory.createProxyWithNonce(
                safeSingleton, _initializer(owners, threshold, address(0), ""), saltNonce++
            )
        );
        vm.deal(address(safe), 10 ether);
    }

    function _owners(address a, address b) internal pure returns (address[] memory o) {
        o = new address[](2);
        (o[0], o[1]) = (a, b);
    }

    function _owners(address a, address b, address c) internal pure returns (address[] memory o) {
        o = new address[](3);
        (o[0], o[1], o[2]) = (a, b, c);
    }

    // ---------------------------------------------------------------- signing helpers

    /// @dev Signs like the Signer: P-256 over sha256(authData || sha256(clientDataJSON)), low-s.
    function _passkeySign(bytes32 challenge, bytes memory authData, string memory fields)
        internal
        view
        returns (uint256 r, uint256 s)
    {
        bytes32 digest = WebAuthnEncoding.signingDigest(challenge, authData, fields);
        (bytes32 r_, bytes32 s_) = vm.signP256(passkeyKey, digest);
        (r, s) = (uint256(r_), WebAuthnEncoding.normalizeS(uint256(s_)));
    }

    function _passkeySignature(bytes32 challenge) internal view returns (bytes memory) {
        bytes memory authData = WebAuthnEncoding.signerAuthenticatorData();
        (uint256 r, uint256 s) = _passkeySign(challenge, authData, WebAuthnEncoding.CLIENT_DATA_FIELDS);
        return WebAuthnEncoding.encodeSignature(authData, WebAuthnEncoding.CLIENT_DATA_FIELDS, r, s);
    }

    function _eoaEntry(address owner, uint256 key, bytes32 hash) internal pure returns (SafeSignatures.Entry memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        return SafeSignatures.eoa(owner, v, r, s);
    }

    /// @dev EOA owner 1 + passkey signer, packed for Safe.
    function _eoaAndPasskey(address signer, bytes32 txHash, bytes memory passkeySig)
        internal
        view
        returns (bytes memory)
    {
        SafeSignatures.Entry[] memory e = new SafeSignatures.Entry[](2);
        e[0] = _eoaEntry(eoaOwner, eoaKey, txHash);
        e[1] = SafeSignatures.contractSig(signer, passkeySig);
        return SafeSignatures.pack(e);
    }

    // ---------------------------------------------------------------- tx helpers

    function _transferHash(ISafe safe, uint256 value) internal view returns (bytes32) {
        return safe.getTransactionHash(RECIPIENT, value, "", 0, 0, 0, 0, address(0), address(0), safe.nonce());
    }

    function _execTransfer(ISafe safe, uint256 value, bytes memory signatures) internal returns (bool) {
        return safe.execTransaction(RECIPIENT, value, "", 0, 0, 0, 0, address(0), payable(address(0)), signatures);
    }

    function _execTransferCalldata(uint256 value, bytes memory signatures) internal pure returns (bytes memory) {
        return abi.encodeCall(
            ISafe.execTransaction, (RECIPIENT, value, "", 0, 0, 0, 0, address(0), payable(address(0)), signatures)
        );
    }

    /// @dev Gas a transaction pays for its calldata, post-Prague (EIP-7623 floor included), on top
    /// of 21000 and execution: returns (standard 4/16 cost, floor 10/40 cost).
    function _calldataGas(bytes memory data) internal pure returns (uint256 standard, uint256 floor) {
        uint256 tokens;
        for (uint256 i = 0; i < data.length; i++) {
            tokens += data[i] == 0 ? 1 : 4;
        }
        return (tokens * 4, tokens * 10);
    }

    function _multiSendTx(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), data.length, data);
    }
}
