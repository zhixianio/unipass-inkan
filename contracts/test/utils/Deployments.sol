// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {SafeWebAuthnBase} from "../SafeWebAuthnBase.sol";
import {PasskeyDeployments} from "../../src/PasskeyDeployments.sol";
import {SafeDeployments} from "../../src/SafeDeployments.sol";
import {ISafeProxyFactory, IMultiSend, IWebAuthnSignerFactory} from "../../src/Interfaces.sol";

/// @notice Safe 1.4.1 and passkey v0.2.1 built from the pinned sources in lib/. Always runs.
abstract contract LocalDeployment is SafeWebAuthnBase {
    function _deploy() internal override returns (bool) {
        safeSingleton = vm.deployCode("Safe.sol:Safe");
        proxyFactory = ISafeProxyFactory(vm.deployCode("SafeProxyFactory.sol:SafeProxyFactory"));
        fallbackHandler = vm.deployCode("CompatibilityFallbackHandler.sol:CompatibilityFallbackHandler");
        multiSendCallOnly = IMultiSend(vm.deployCode("MultiSendCallOnly.sol:MultiSendCallOnly"));
        signerFactory = IWebAuthnSignerFactory(vm.deployCode("SafeWebAuthnSignerFactory.sol:SafeWebAuthnSignerFactory"));
        fclVerifier = vm.deployCode("FCLP256Verifier.sol:FCLP256Verifier");
        expectedSafeVersion = "1.4.1";
        return true;
    }
}

/// @notice Canonical deployments on a Sepolia fork. Skipped unless SEPOLIA_RPC_URL is set;
/// SEPOLIA_FORK_BLOCK pins the block (needs an archive node for old blocks).
abstract contract SepoliaForkDeployment is SafeWebAuthnBase {
    function _safeDeployment() internal pure virtual returns (SafeDeployments.Deployment memory);

    function _deploy() internal override returns (bool) {
        string memory url = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(url).length == 0) return false;
        uint256 blockNumber = vm.envOr("SEPOLIA_FORK_BLOCK", uint256(0));
        if (blockNumber == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, blockNumber);
        require(block.chainid == 11155111, "not Sepolia");

        SafeDeployments.Deployment memory d = _safeDeployment();
        safeSingleton = d.singleton;
        proxyFactory = ISafeProxyFactory(d.proxyFactory);
        fallbackHandler = d.fallbackHandler;
        expectedSafeVersion = d.version;
        multiSendCallOnly = IMultiSend(SafeDeployments.MULTI_SEND_CALL_ONLY_141);
        signerFactory = IWebAuthnSignerFactory(PasskeyDeployments.SIGNER_FACTORY);
        fclVerifier = PasskeyDeployments.FCL_P256_VERIFIER;
        return true;
    }
}
