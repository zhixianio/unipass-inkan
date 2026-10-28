// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {SafeWebAuthnBase} from "./SafeWebAuthnBase.sol";
import {LocalDeployment, SepoliaForkDeployment} from "./utils/Deployments.sol";
import {SafeDeployments} from "../src/SafeDeployments.sol";
import {PasskeyDeployments} from "../src/PasskeyDeployments.sol";
import {WebAuthnEncoding} from "../src/WebAuthnEncoding.sol";
import {ISafe, IWebAuthnSigner} from "../src/Interfaces.sol";

/// @notice Signatures produced by a real iPhone Secure Enclave through apps/signer.
abstract contract DeviceSignatureChecks is SafeWebAuthnBase {
    // Current Signer (rpId "unipass.xyz", Bundle ID xyz.unipass.signer). `signer-key.json` holds
    // the public key {x, y}; `signer-safetx.json` the device's signature over the logged safeTxHash.
    string internal constant CURRENT_KEY = "../testvectors/webauthn/device/signer-key.json";
    string internal constant CURRENT_SAFE_TX = "../testvectors/webauthn/device/signer-safetx.json";

    // Frozen: the device fixtures sign a safeTxHash of the Safe this salt deploys
    // (0xE8982BeA17b5959D7bDA9571f0c183914B8B06Db); a new salt would need new phone signatures.
    uint256 internal constant DEVICE_SAFE_SALT = 0x4987e70d0ef162a46d9d68a76d715e3780f27a8fe54f1d1db587964a5b899bc1;

    function _afterSetUp() internal override {}

    function _key(string memory path) internal view returns (uint256 x, uint256 y) {
        string memory json = vm.readFile(path);
        x = uint256(vm.parseJsonBytes32(json, ".x"));
        y = uint256(vm.parseJsonBytes32(json, ".y"));
    }

    function _checkShape(bytes memory sig) internal pure {
        (bytes memory authData, string memory fields, uint256 r, uint256 s) =
            abi.decode(sig, (bytes, string, uint256, uint256));
        assertEq(authData, WebAuthnEncoding.signerAuthenticatorData());
        assertEq(fields, WebAuthnEncoding.CLIENT_DATA_FIELDS);
        assertTrue(WebAuthnEncoding.isLowS(s));
        assertGt(r, 0);
        assertEq(sig, WebAuthnEncoding.encodeSignature(authData, fields, r, s), "standard ABI encoding");
    }

    /// 2-of-2 Safe 1.4.1 (test EOA + device signer) on the Sepolia fork, transfer 1 wei to 0xBEEF at
    /// nonce 0. Logs the safeTxHash; executes it when `sigPath` exists.
    function _deviceSafeTx(uint256 x, uint256 y, string memory sigPath) internal {
        address signer = signerFactory.createSigner(x, y, _defaultVerifiers());
        bytes memory init = _initializer(_owners(eoaOwner, signer), 2, address(0), "");
        address predicted = _predictSafe(init, DEVICE_SAFE_SALT);
        if (predicted.code.length == 0) proxyFactory.createProxyWithNonce(safeSingleton, init, DEVICE_SAFE_SALT);
        ISafe s = ISafe(predicted);
        vm.deal(address(s), 1 ether);
        // Pin the nonce: the real Sepolia Safe may have been used since.
        vm.store(address(s), bytes32(uint256(5)), bytes32(0));

        bytes32 txHash = _transferHash(s, 1);
        console2.log("device Safe (1.4.1, Sepolia):", address(s));
        console2.log("device signer:", signer);
        console2.log("transfer 1 wei to 0xBEEF, nonce 0, safeTxHash:");
        console2.logBytes32(txHash);

        if (!vm.exists(sigPath)) return;
        string memory json = vm.readFile(sigPath);
        assertEq(vm.parseJsonBytes32(json, ".challenge"), txHash, "device signed a different safeTxHash");
        bytes memory sig = vm.parseJsonBytes(json, ".proxySignature");
        _checkShape(sig);
        assertTrue(_execTransfer(s, 1, _eoaAndPasskey(signer, txHash, sig)));
        assertEq(s.nonce(), 1);
        console2.log("device-signed execTransaction succeeded");
    }

    function test_currentSignatureShape() public view {
        _checkShape(vm.parseJsonBytes(vm.readFile(CURRENT_SAFE_TX), ".proxySignature"));
    }

    function test_currentSignatureAcceptedByProxy() public {
        (uint256 x, uint256 y) = _key(CURRENT_KEY);
        address signer = signerFactory.createSigner(x, y, _defaultVerifiers());
        string memory json = vm.readFile(CURRENT_SAFE_TX);
        bytes32 challenge = vm.parseJsonBytes32(json, ".challenge");
        bytes memory sig = vm.parseJsonBytes(json, ".proxySignature");
        assertEq(IWebAuthnSigner(signer).isValidSignature(challenge, sig), ERC1271_MAGIC);
        assertEq(IWebAuthnSigner(signer).isValidSignature(challenge ^ bytes32(uint256(1)), sig), bytes4(0));
    }

    function test_currentDeviceSafeTx() public {
        if (block.chainid != 11155111 || !vm.exists(CURRENT_KEY)) return;
        (uint256 x, uint256 y) = _key(CURRENT_KEY);
        _deviceSafeTx(x, y, CURRENT_SAFE_TX);
    }
}

contract DeviceSignatureLocalTest is LocalDeployment, DeviceSignatureChecks {}

contract DeviceSignatureForkTest is SepoliaForkDeployment, DeviceSignatureChecks {
    function _safeDeployment() internal pure override returns (SafeDeployments.Deployment memory) {
        return SafeDeployments.v141();
    }

    function test_currentSignerAddressOffline() public {
        (uint256 x, uint256 y) = _key(CURRENT_KEY);
        assertEq(
            signerFactory.createSigner(x, y, _defaultVerifiers()),
            PasskeyDeployments.canonicalSignerAddress(x, y, _defaultVerifiers())
        );
    }
}
