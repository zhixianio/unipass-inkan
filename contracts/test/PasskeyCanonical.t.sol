// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {SepoliaForkDeployment} from "./utils/Deployments.sol";
import {SafeDeployments} from "../src/SafeDeployments.sol";
import {PasskeyDeployments} from "../src/PasskeyDeployments.sol";
import {WebAuthnEncoding} from "../src/WebAuthnEncoding.sol";
import {ISafe} from "../src/Interfaces.sol";

/// @notice Fork-only: the constants in src/ match what is deployed on Sepolia.
contract PasskeyCanonicalForkTest is SepoliaForkDeployment {
    function _safeDeployment() internal pure override returns (SafeDeployments.Deployment memory) {
        return SafeDeployments.v141();
    }

    function _afterSetUp() internal override {}

    function test_factorySingleton() public view {
        assertEq(signerFactory.SINGLETON(), PasskeyDeployments.SIGNER_SINGLETON);
    }

    /// The proxy creation code extracted from the factory reproduces getSigner offline.
    function test_offlineSignerAddress() public view {
        uint176[3] memory vs = [
            PasskeyDeployments.defaultVerifiers(),
            PasskeyDeployments.verifiers(0, PasskeyDeployments.FCL_P256_VERIFIER),
            uint176(0)
        ];
        for (uint256 i = 0; i < vs.length; i++) {
            assertEq(
                PasskeyDeployments.canonicalSignerAddress(passkeyX, passkeyY, vs[i]),
                signerFactory.getSigner(passkeyX, passkeyY, vs[i])
            );
        }
    }

    function test_safeVersions() public view {
        assertEq(ISafe(SafeDeployments.v130().singleton).VERSION(), "1.3.0");
        assertEq(ISafe(SafeDeployments.v141().singleton).VERSION(), "1.4.1");
        assertEq(ISafe(SafeDeployments.v150().singleton).VERSION(), "1.5.0");
    }

    /// 0x100 (EIP-7951) and both Solidity verifiers accept a valid signature and its high-s twin.
    function test_verifiersAcceptBothS() public view {
        bytes32 digest = sha256("unipass-inkan");
        (bytes32 r, bytes32 s_) = vm.signP256(passkeyKey, digest);
        uint256 s = WebAuthnEncoding.normalizeS(uint256(s_));
        address[3] memory verifiers = [
            address(uint160(PasskeyDeployments.P256_PRECOMPILE)),
            PasskeyDeployments.FCL_P256_VERIFIER,
            PasskeyDeployments.DAIMO_P256_VERIFIER
        ];
        for (uint256 i = 0; i < verifiers.length; i++) {
            assertTrue(_verify(verifiers[i], digest, uint256(r), s, passkeyX, passkeyY), "low s");
            assertTrue(
                _verify(verifiers[i], digest, uint256(r), WebAuthnEncoding.P256_N - s, passkeyX, passkeyY), "high s"
            );
            assertFalse(_verify(verifiers[i], digest, uint256(r), s, passkeyX, passkeyY + 1), "wrong key");
        }
    }

    function _verify(address verifier, bytes32 digest, uint256 r, uint256 s, uint256 x, uint256 y)
        internal
        view
        returns (bool)
    {
        (bool ok, bytes memory ret) = verifier.staticcall(abi.encode(digest, r, s, x, y));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
    }
}
