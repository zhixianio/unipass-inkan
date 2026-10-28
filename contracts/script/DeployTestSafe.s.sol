// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {PasskeyDeployments} from "../src/PasskeyDeployments.sol";
import {SafeDeployments} from "../src/SafeDeployments.sol";
import {ISafe, ISafeProxyFactory, IMultiSend, IWebAuthnSignerFactory} from "../src/Interfaces.sol";

/// @notice Deploys a test Safe on Sepolia in one transaction: MultiSendCallOnly →
/// [SafeWebAuthnSignerFactory.createSigner, SafeProxyFactory.createProxyWithNonce].
/// The Safe is SafeL2 1.4.1, 2-of-2: the Signer's WebAuthn proxy (public key from
/// testvectors/webauthn/device/signer-key.json, canonical verifiers) and the broadcasting EOA.
///
/// Signing only through a Foundry keystore (`--account <name>`); this script never reads a key.
/// See contracts/README.md, "在 Sepolia 部署测试 Safe".
///
/// Run with `--evm-version amsterdam`: Sepolia's current fork prices contract creation far above
/// Osaka (foundry.toml's default), and an Osaka simulation sets a gas limit that runs out.
///
/// Optional: SAFE_SALT_NONCE (default 0) to deploy another Safe with the same owners.
contract DeployTestSafe is Script {
    string internal constant SIGNER_KEY = "../testvectors/webauthn/device/signer-key.json";
    uint256 internal constant SEPOLIA = 11155111;

    struct Result {
        address deployer;
        address signer;
        address safe;
    }

    function run() external returns (Result memory r) {
        require(block.chainid == SEPOLIA, "DeployTestSafe: Sepolia only");
        string memory json = vm.readFile(SIGNER_KEY);
        uint256 x = uint256(vm.parseJsonBytes32(json, ".x"));
        uint256 y = uint256(vm.parseJsonBytes32(json, ".y"));
        uint176 verifiers = PasskeyDeployments.defaultVerifiers();
        uint256 saltNonce = vm.envOr("SAFE_SALT_NONCE", uint256(0));

        IWebAuthnSignerFactory signerFactory = IWebAuthnSignerFactory(PasskeyDeployments.SIGNER_FACTORY);
        SafeDeployments.Deployment memory d = SafeDeployments.v141();
        ISafeProxyFactory proxyFactory = ISafeProxyFactory(d.proxyFactory);

        // The broadcasting account (from --account); nothing is sent in this first session.
        vm.startBroadcast();
        (, r.deployer,) = vm.readCallers();
        vm.stopBroadcast();
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            require(r.deployer != DEFAULT_SENDER, "DeployTestSafe: pass --account <keystore name>");
        }

        // Owners and addresses, all computed before anything is sent.
        r.signer = PasskeyDeployments.canonicalSignerAddress(x, y, verifiers);
        require(r.signer == signerFactory.getSigner(x, y, verifiers), "DeployTestSafe: offline signer address mismatch");
        address[] memory owners = new address[](2);
        (owners[0], owners[1]) = (r.signer, r.deployer);
        bytes memory initializer = abi.encodeCall(
            ISafe.setup, (owners, 2, address(0), "", d.fallbackHandler, address(0), 0, payable(address(0)))
        );
        r.safe = _predictSafe(proxyFactory, SafeDeployments.SAFE_L2_141, initializer, saltNonce);
        require(r.safe.code.length == 0, "DeployTestSafe: Safe already deployed, set SAFE_SALT_NONCE");

        console2.log("deployer (owner, EOA):", r.deployer);
        console2.log("signer proxy (owner): ", r.signer, r.signer.code.length == 0 ? "(new)" : "(exists)");
        console2.log("Safe (predicted):     ", r.safe);

        // createSigner is a no-op when the proxy already exists.
        bytes memory createSigner = abi.encodeCall(signerFactory.createSigner, (x, y, verifiers));
        bytes memory createSafe =
            abi.encodeCall(proxyFactory.createProxyWithNonce, (SafeDeployments.SAFE_L2_141, initializer, saltNonce));
        vm.startBroadcast(r.deployer);
        IMultiSend(SafeDeployments.MULTI_SEND_CALL_ONLY_141)
            .multiSend(
                abi.encodePacked(
                    _multiSendTx(address(signerFactory), createSigner), _multiSendTx(address(proxyFactory), createSafe)
                )
            );
        vm.stopBroadcast();

        _check(r);
        console2.log("");
        console2.log("Deployment summary:");
        console2.log("  chainId 11155111, SafeL2 1.4.1, threshold 2");
        console2.log("  Safe:         ", r.safe);
        console2.log("  signer proxy: ", r.signer);
        console2.log("  EOA owner:    ", r.deployer);
        console2.log(
            "  tx hash: see the [Success] line below (or broadcast/DeployTestSafe.s.sol/11155111/run-latest.json)"
        );
    }

    function _predictSafe(ISafeProxyFactory factory, address singleton, bytes memory initializer, uint256 saltNonce)
        internal
        pure
        returns (address)
    {
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), saltNonce));
        bytes memory initCode = abi.encodePacked(factory.proxyCreationCode(), uint256(uint160(singleton)));
        return vm.computeCreate2Address(salt, keccak256(initCode), address(factory));
    }

    function _multiSendTx(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), data.length, data);
    }

    function _check(Result memory r) internal view {
        require(r.signer.code.length > 0, "DeployTestSafe: signer proxy not deployed");
        require(r.safe.code.length > 0, "DeployTestSafe: Safe not deployed");
        ISafe safe = ISafe(r.safe);
        address[] memory owners = safe.getOwners();
        require(owners.length == 2 && owners[0] == r.signer && owners[1] == r.deployer, "DeployTestSafe: owners");
        require(safe.getThreshold() == 2, "DeployTestSafe: threshold");
        require(keccak256(bytes(safe.VERSION())) == keccak256("1.4.1"), "DeployTestSafe: version");
    }
}
