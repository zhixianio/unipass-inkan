// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {SafeWebAuthnBase} from "./SafeWebAuthnBase.sol";
import {LocalDeployment, SepoliaForkDeployment} from "./utils/Deployments.sol";
import {SafeDeployments} from "../src/SafeDeployments.sol";
import {PasskeyDeployments} from "../src/PasskeyDeployments.sol";
import {SafeSignatures} from "../src/SafeSignatures.sol";
import {ISafe, IWebAuthnSigner} from "../src/Interfaces.sol";

/// @notice Gas for a steady-state (nonce 1) 2-of-2 ETH transfer, EOA + passkey vs EOA + EOA.
/// Everything is prepared in setUp so the measured call starts with cold accounts/storage, like a
/// real transaction. `exec` is the callee's execution gas (vm.lastFrameGas); `tx` adds 21000 and
/// calldata cost (EIP-7623 floor included). The local EVM is Osaka: P256VERIFY costs 6900
/// (EIP-7951). On RIP-7212 L2s it costs 3450, so subtract 3450 there.
abstract contract WebAuthnGasBench is SafeWebAuthnBase {
    struct Bench {
        string label;
        ISafe safe;
        address signer;
        bytes signatures;
    }

    Bench[] internal benches;
    bytes32 internal sampleHash;

    function _afterSetUp() internal override {
        address fcl = fclVerifier;
        _addPasskey("precompile 0x100 + FCL fallback (default)", PasskeyDeployments.verifiers(0x0100, fcl));
        _addPasskey("FCL only (no precompile configured)", PasskeyDeployments.verifiers(0, fcl));
        // 0x0101 is an empty account: models a chain where 0x100 has no precompile yet.
        _addPasskey("precompile missing -> FCL fallback", PasskeyDeployments.verifiers(0x0101, fcl));
        if (PasskeyDeployments.DAIMO_P256_VERIFIER.code.length > 0) {
            _addPasskey("Daimo verifier only", PasskeyDeployments.verifiers(0, PasskeyDeployments.DAIMO_P256_VERIFIER));
        }
        ISafe s = _createSafe(_owners(eoaOwner, eoaOwner2), 2);
        benches.push(Bench("EOA + EOA baseline", s, address(0), ""));

        for (uint256 i = 0; i < benches.length; i++) {
            Bench storage b = benches[i];
            // Warm-up tx so the measured one is nonce 1 -> 2 (no zero-to-nonzero nonce write).
            assertTrue(_execTransfer(b.safe, 1, _sigs(b, _transferHash(b.safe, 1))));
            b.signatures = _sigs(b, _transferHash(b.safe, 1));
        }
        sampleHash = _transferHash(benches[0].safe, 1);
    }

    function _addPasskey(string memory label, uint176 verifiers) internal {
        address signer = signerFactory.createSigner(passkeyX, passkeyY, verifiers);
        benches.push(Bench(label, _createSafe(_owners(eoaOwner, signer), 2), signer, ""));
    }

    function _sigs(Bench storage b, bytes32 txHash) internal view returns (bytes memory) {
        if (b.signer != address(0)) return _eoaAndPasskey(b.signer, txHash, _passkeySignature(txHash));
        SafeSignatures.Entry[] memory e = new SafeSignatures.Entry[](2);
        e[0] = _eoaEntry(eoaOwner, eoaKey, txHash);
        e[1] = _eoaEntry(eoaOwner2, eoaKey2, txHash);
        return SafeSignatures.pack(e);
    }

    function test_gas_execTransaction() public {
        console2.log("Safe", expectedSafeVersion);
        for (uint256 i = 0; i < benches.length; i++) {
            Bench storage b = benches[i];
            bytes memory sigs = b.signatures;
            assertTrue(_execTransfer(b.safe, 1, sigs));
            uint256 exec = vm.lastFrameGas().gasTotalUsed;
            (uint256 std, uint256 floor) = _calldataGas(_execTransferCalldata(1, sigs));
            uint256 txGas = 21000 + (std + exec > floor ? std + exec : floor);
            console2.log(string.concat("  ", b.label));
            console2.log("    exec / calldata bytes / est. tx gas:", exec, _execTransferCalldata(1, sigs).length, txGas);
        }
    }

    function test_gas_isValidSignature() public view {
        for (uint256 i = 0; i < benches.length; i++) {
            if (benches[i].signer == address(0)) continue;
            bytes memory sig = _passkeySignature(sampleHash);
            uint256 g = gasleft();
            assertEq(IWebAuthnSigner(benches[i].signer).isValidSignature(sampleHash, sig), ERC1271_MAGIC);
            console2.log(string.concat("  isValidSignature, ", benches[i].label, ":"), g - gasleft());
        }
    }

    function test_gas_createSigner() public {
        (uint256 x, uint256 y) = vm.publicKeyP256(passkeyKey + 1);
        signerFactory.createSigner(x, y, _defaultVerifiers());
        console2.log("  createSigner (proxy deployment):", vm.lastFrameGas().gasTotalUsed);
    }
}

contract WebAuthnGasLocalTest is LocalDeployment, WebAuthnGasBench {}

contract WebAuthnGasFork130Test is SepoliaForkDeployment, WebAuthnGasBench {
    function _safeDeployment() internal pure override returns (SafeDeployments.Deployment memory) {
        return SafeDeployments.v130();
    }
}

contract WebAuthnGasFork141Test is SepoliaForkDeployment, WebAuthnGasBench {
    function _safeDeployment() internal pure override returns (SafeDeployments.Deployment memory) {
        return SafeDeployments.v141();
    }
}

contract WebAuthnGasFork150Test is SepoliaForkDeployment, WebAuthnGasBench {
    function _safeDeployment() internal pure override returns (SafeDeployments.Deployment memory) {
        return SafeDeployments.v150();
    }
}
