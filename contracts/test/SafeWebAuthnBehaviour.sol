// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {SafeWebAuthnBase} from "./SafeWebAuthnBase.sol";
import {WebAuthnEncoding} from "../src/WebAuthnEncoding.sol";
import {PasskeyDeployments} from "../src/PasskeyDeployments.sol";
import {SafeSignatures} from "../src/SafeSignatures.sol";
import {ISafe, IWebAuthnSigner} from "../src/Interfaces.sol";

/// @notice The M0 ① checks, run against every deployment (local source build and each Safe
/// version on a Sepolia fork).
abstract contract SafeWebAuthnBehaviour is SafeWebAuthnBase {
    address internal signer;
    ISafe internal safe;

    function _afterSetUp() internal override {
        signer = signerFactory.createSigner(passkeyX, passkeyY, _defaultVerifiers());
        // 2-of-3: EOA, passkey signer, a second EOA that does not sign.
        safe = _createSafe(_owners(eoaOwner, signer, eoaOwner2), 2);
    }

    function test_safeVersion() public view {
        assertEq(safe.VERSION(), expectedSafeVersion);
        assertEq(safe.getThreshold(), 2);
    }

    function test_signerConfiguration() public view {
        (uint256 x, uint256 y, uint176 v) = IWebAuthnSigner(signer).getConfiguration();
        assertEq(x, passkeyX);
        assertEq(y, passkeyY);
        assertEq(v, _defaultVerifiers());
        assertEq(signer, signerFactory.getSigner(passkeyX, passkeyY, _defaultVerifiers()));
    }

    /// The challenge the signer verifies is exactly safeTxHash, through both ERC-1271 flavours.
    function test_challengeIsSafeTxHash() public view {
        bytes32 txHash = _transferHash(safe, 1 ether);
        bytes memory sig = _passkeySignature(txHash);
        assertEq(IWebAuthnSigner(signer).isValidSignature(txHash, sig), ERC1271_MAGIC);
        // Legacy path (Safe <= 1.4.1 passes the EIP-712 preimage; the proxy keccaks it).
        bytes memory preimage = _safeTxPreimage(safe, 1 ether);
        assertEq(keccak256(preimage), txHash);
        assertEq(IWebAuthnSigner(signer).isValidSignature(preimage, sig), LEGACY_MAGIC);
    }

    function test_execTransaction_eoaAndPasskey() public {
        bytes32 txHash = _transferHash(safe, 1 ether);
        bytes memory sigs = _eoaAndPasskey(signer, txHash, _passkeySignature(txHash));
        uint256 nonceBefore = safe.nonce();
        uint256 balanceBefore = RECIPIENT.balance;
        assertTrue(_execTransfer(safe, 1 ether, sigs));
        assertEq(RECIPIENT.balance, balanceBefore + 1 ether);
        assertEq(safe.nonce(), nonceBefore + 1);
    }

    /// Passkey signature alone is not enough at threshold 2.
    function test_revert_passkeyAloneBelowThreshold() public {
        bytes32 txHash = _transferHash(safe, 1 ether);
        SafeSignatures.Entry[] memory e = new SafeSignatures.Entry[](1);
        e[0] = SafeSignatures.contractSig(signer, _passkeySignature(txHash));
        // GS020 / GS021 depending on version and signature length.
        vm.expectRevert();
        _execTransfer(safe, 1 ether, SafeSignatures.pack(e));
    }

    function test_revert_wrongChallenge() public {
        bytes32 txHash = _transferHash(safe, 1 ether);
        bytes32 otherHash = _transferHash(safe, 2 ether);
        bytes memory sigs = _eoaAndPasskey(signer, txHash, _passkeySignature(otherHash));
        vm.expectRevert(bytes("GS024"));
        _execTransfer(safe, 1 ether, sigs);
    }

    /// UP without UV is rejected: the singleton requires the UV bit (0x04).
    function test_revert_flagsWithoutUV() public {
        bytes32 txHash = _transferHash(safe, 1 ether);
        bytes memory sigs = _eoaAndPasskey(signer, txHash, _signWithFlags(txHash, WebAuthnEncoding.FLAG_UP));
        vm.expectRevert(bytes("GS024"));
        _execTransfer(safe, 1 ether, sigs);
    }

    /// UV alone (no UP) is accepted; only UV is checked on-chain.
    function test_flagsUVOnlyAccepted() public {
        bytes32 txHash = _transferHash(safe, 1 ether);
        bytes memory sigs = _eoaAndPasskey(signer, txHash, _signWithFlags(txHash, WebAuthnEncoding.FLAG_UV));
        assertTrue(_execTransfer(safe, 1 ether, sigs));
    }

    /// The signature covers the flags byte: flipping it after signing fails.
    function test_revert_flagsChangedAfterSigning() public {
        bytes32 txHash = _transferHash(safe, 1 ether);
        bytes memory authData = WebAuthnEncoding.signerAuthenticatorData();
        (uint256 r, uint256 s) = _passkeySign(txHash, authData, WebAuthnEncoding.CLIENT_DATA_FIELDS);
        authData[32] = 0x1d; // UP | UV | BE | BS
        bytes memory sigs = _eoaAndPasskey(
            signer, txHash, WebAuthnEncoding.encodeSignature(authData, WebAuthnEncoding.CLIENT_DATA_FIELDS, r, s)
        );
        vm.expectRevert(bytes("GS024"));
        _execTransfer(safe, 1 ether, sigs);
    }

    function test_revert_clientDataFieldsChangedAfterSigning() public {
        bytes32 txHash = _transferHash(safe, 1 ether);
        bytes memory authData = WebAuthnEncoding.signerAuthenticatorData();
        (uint256 r, uint256 s) = _passkeySign(txHash, authData, WebAuthnEncoding.CLIENT_DATA_FIELDS);
        bytes memory sigs = _eoaAndPasskey(
            signer, txHash, WebAuthnEncoding.encodeSignature(authData, '"origin":"https://evil.example"', r, s)
        );
        vm.expectRevert(bytes("GS024"));
        _execTransfer(safe, 1 ether, sigs);
    }

    /// High s is NOT rejected: the singleton calls `verifySignatureAllowMalleability`, and both the
    /// 0x100 precompile and the FCL fallback accept s > n/2. The Signer normalises to low s anyway.
    function test_highSAcceptedByContract() public {
        bytes32 txHash = _transferHash(safe, 1 ether);
        bytes memory authData = WebAuthnEncoding.signerAuthenticatorData();
        (uint256 r, uint256 s) = _passkeySign(txHash, authData, WebAuthnEncoding.CLIENT_DATA_FIELDS);
        uint256 highS = WebAuthnEncoding.P256_N - s;
        assertFalse(WebAuthnEncoding.isLowS(highS));
        bytes memory sigs = _eoaAndPasskey(
            signer, txHash, WebAuthnEncoding.encodeSignature(authData, WebAuthnEncoding.CLIENT_DATA_FIELDS, r, highS)
        );
        assertTrue(_execTransfer(safe, 1 ether, sigs));
    }

    /// Extra bytes beyond the standard ABI encoding are rejected (castSignature length bound).
    function test_revert_paddedSignature() public {
        bytes32 txHash = _transferHash(safe, 1 ether);
        bytes memory padded = abi.encodePacked(_passkeySignature(txHash), bytes32(0));
        bytes memory sigs = _eoaAndPasskey(signer, txHash, padded);
        vm.expectRevert(bytes("GS024"));
        _execTransfer(safe, 1 ether, sigs);
    }

    function test_revert_otherKey() public {
        bytes32 txHash = _transferHash(safe, 1 ether);
        uint256 savedKey = passkeyKey;
        passkeyKey = savedKey + 1;
        bytes memory sig = _passkeySignature(txHash);
        passkeyKey = savedKey;
        vm.expectRevert(bytes("GS024"));
        _execTransfer(safe, 1 ether, _eoaAndPasskey(signer, txHash, sig));
    }

    /// A Safe can list the signer's predicted address as owner before the proxy exists. Execution
    /// needs the proxy deployed; deploying it later (by anyone) makes the same signature valid.
    function test_ownerCanBeUndeployedSigner() public {
        uint256 otherKey = passkeyKey + 7;
        (uint256 x, uint256 y) = vm.publicKeyP256(otherKey);
        address predicted = signerFactory.getSigner(x, y, _defaultVerifiers());
        assertEq(predicted.code.length, 0);

        ISafe s = _createSafe(_owners(eoaOwner, predicted), 2);
        assertEq(s.getOwners().length, 2);

        passkeyKey = otherKey;
        bytes32 txHash = _transferHash(s, 1 ether);
        bytes memory sigs = _eoaAndPasskey(predicted, txHash, _passkeySignature(txHash));

        vm.expectRevert();
        _execTransfer(s, 1 ether, sigs);

        assertEq(signerFactory.createSigner(x, y, _defaultVerifiers()), predicted);
        assertTrue(_execTransfer(s, 1 ether, sigs));
    }

    /// One transaction from any EOA: MultiSendCallOnly → [factory.createSigner, proxyFactory.createProxyWithNonce].
    function test_oneTx_multiSendDeploysSignerThenSafe() public {
        (uint256 x, uint256 y) = vm.publicKeyP256(passkeyKey + 11);
        address predicted = signerFactory.getSigner(x, y, _defaultVerifiers());
        bytes memory init = _initializer(_owners(eoaOwner, predicted), 2, address(0), "");
        uint256 nonce_ = saltNonce++;
        address predictedSafe = _predictSafe(init, nonce_);

        bytes memory txs = abi.encodePacked(
            _multiSendTx(
                address(signerFactory), abi.encodeCall(signerFactory.createSigner, (x, y, _defaultVerifiers()))
            ),
            _multiSendTx(
                    address(proxyFactory),
                    abi.encodeCall(proxyFactory.createProxyWithNonce, (safeSingleton, init, nonce_))
                )
        );
        vm.prank(makeAddr("anyone"));
        multiSendCallOnly.multiSend(txs);

        assertGt(predicted.code.length, 0);
        assertGt(predictedSafe.code.length, 0);
        assertEq(ISafe(predictedSafe).getOwners()[1], predicted);
    }

    /// Also works the other way round (Safe first, signer second) in the same MultiSend.
    function test_oneTx_multiSendDeploysSafeThenSigner() public {
        (uint256 x, uint256 y) = vm.publicKeyP256(passkeyKey + 13);
        address predicted = signerFactory.getSigner(x, y, _defaultVerifiers());
        bytes memory init = _initializer(_owners(predicted, eoaOwner), 2, address(0), "");
        uint256 nonce_ = saltNonce++;
        bytes memory txs = abi.encodePacked(
            _multiSendTx(
                address(proxyFactory), abi.encodeCall(proxyFactory.createProxyWithNonce, (safeSingleton, init, nonce_))
            ),
            _multiSendTx(
                address(signerFactory), abi.encodeCall(signerFactory.createSigner, (x, y, _defaultVerifiers()))
            )
        );
        multiSendCallOnly.multiSend(txs);
        assertGt(predicted.code.length, 0);
        assertGt(_predictSafe(init, nonce_).code.length, 0);
    }

    /// One call to the Safe proxy factory: `setup` delegatecalls MultiSendCallOnly, which calls
    /// `createSigner`. The Safe and its passkey owner exist after a single createProxyWithNonce.
    function test_oneTx_setupDeploysSigner() public {
        uint256 key = passkeyKey + 17;
        (uint256 x, uint256 y) = vm.publicKeyP256(key);
        address predicted = signerFactory.getSigner(x, y, _defaultVerifiers());
        bytes memory deploySigner = abi.encodeCall(
            multiSendCallOnly.multiSend,
            (_multiSendTx(
                    address(signerFactory), abi.encodeCall(signerFactory.createSigner, (x, y, _defaultVerifiers()))
                ))
        );
        bytes memory init = _initializer(_owners(eoaOwner, predicted), 2, address(multiSendCallOnly), deploySigner);
        ISafe s = ISafe(proxyFactory.createProxyWithNonce(safeSingleton, init, saltNonce++));
        assertGt(predicted.code.length, 0);
        vm.deal(address(s), 1 ether);

        passkeyKey = key;
        bytes32 txHash = _transferHash(s, 1 ether);
        assertTrue(_execTransfer(s, 1 ether, _eoaAndPasskey(predicted, txHash, _passkeySignature(txHash))));
    }

    // ---------------------------------------------------------------- helpers

    function _signWithFlags(bytes32 challenge, bytes1 flags) internal view returns (bytes memory) {
        bytes memory authData = WebAuthnEncoding.authenticatorData(sha256(bytes(WebAuthnEncoding.RP_ID)), flags, 0);
        (uint256 r, uint256 s) = _passkeySign(challenge, authData, WebAuthnEncoding.CLIENT_DATA_FIELDS);
        return WebAuthnEncoding.encodeSignature(authData, WebAuthnEncoding.CLIENT_DATA_FIELDS, r, s);
    }

    /// @dev EIP-712 preimage `0x1901 || domainSeparator || safeTxStructHash` for a plain transfer.
    /// The SafeTx typehash is the same in 1.3.0 – 1.5.0.
    function _safeTxPreimage(ISafe s, uint256 value) internal view returns (bytes memory) {
        bytes32 typehash = keccak256(
            "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"
        );
        bytes32 structHash = keccak256(
            abi.encode(typehash, RECIPIENT, value, keccak256(""), 0, 0, 0, 0, address(0), address(0), s.nonce())
        );
        return abi.encodePacked(bytes1(0x19), bytes1(0x01), s.domainSeparator(), structHash);
    }
}
