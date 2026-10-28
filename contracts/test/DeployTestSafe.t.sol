// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployTestSafe} from "../script/DeployTestSafe.s.sol";
import {PasskeyDeployments} from "../src/PasskeyDeployments.sol";
import {ISafe, IWebAuthnSigner} from "../src/Interfaces.sol";

/// @notice Fork-only dry run of script/DeployTestSafe.s.sol (skipped without SEPOLIA_RPC_URL).
contract DeployTestSafeForkTest is Test {
    DeployTestSafe internal script;

    function setUp() public {
        string memory url = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(url).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(url);
        script = new DeployTestSafe();
    }

    function test_deploysSignerAndSafeInOneTx() public {
        string memory json = vm.readFile("../testvectors/webauthn/device/signer-key.json");
        uint256 x = uint256(vm.parseJsonBytes32(json, ".x"));
        uint256 y = uint256(vm.parseJsonBytes32(json, ".y"));

        DeployTestSafe.Result memory r = script.run();

        // Independent of the script: offline address of the device signer, and its on-chain config.
        assertEq(r.signer, PasskeyDeployments.canonicalSignerAddress(x, y, PasskeyDeployments.defaultVerifiers()));
        assertEq(r.signer, 0xc8F9e2ba66e640B05D6d8DA4f00f567679bc9A06);
        (uint256 cx, uint256 cy, uint176 cv) = IWebAuthnSigner(r.signer).getConfiguration();
        assertEq(cx, x);
        assertEq(cy, y);
        assertEq(cv, PasskeyDeployments.defaultVerifiers());

        ISafe safe = ISafe(r.safe);
        assertEq(safe.getThreshold(), 2);
        assertEq(safe.getOwners()[0], r.signer);
        assertEq(safe.getOwners()[1], r.deployer);
        assertEq(safe.nonce(), 0);
    }

    function test_rerunNeedsNewSaltNonce() public {
        script.run();
        vm.expectRevert(bytes("DeployTestSafe: Safe already deployed, set SAFE_SALT_NONCE"));
        script.run();
        vm.setEnv("SAFE_SALT_NONCE", "1");
        DeployTestSafe.Result memory r = script.run();
        assertGt(r.safe.code.length, 0);
    }
}
