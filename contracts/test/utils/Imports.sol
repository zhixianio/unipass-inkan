// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

// Pulls the upstream contracts into the build so tests can deploy them with `vm.deployCode`.
// Nothing here is modified; these are the sources pinned in lib/.
import {Safe} from "safe-smart-account/Safe.sol";
import {SafeProxyFactory} from "safe-smart-account/proxies/SafeProxyFactory.sol";
import {MultiSendCallOnly} from "safe-smart-account/libraries/MultiSendCallOnly.sol";
import {CompatibilityFallbackHandler} from "safe-smart-account/handler/CompatibilityFallbackHandler.sol";
import {SafeWebAuthnSignerFactory} from "safe-passkey/SafeWebAuthnSignerFactory.sol";
import {FCLP256Verifier} from "safe-passkey/verifiers/FCLP256Verifier.sol";
import {TestWebAuthnLib} from "safe-passkey/test/TestWebAuthnLib.sol";
