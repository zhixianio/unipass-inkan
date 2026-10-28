// SPDX-License-Identifier: LGPL-3.0-only
// This file embeds the SafeWebAuthnSignerProxy creation code compiled from safe-modules (LGPL-3.0-only),
// so it keeps the upstream license. The rest of this repository is Apache-2.0; see NOTICE.
pragma solidity ^0.8.26;

/// @title Canonical safe-modules passkey deployments (v0.2.1)
/// @notice Addresses are deterministic (same on every chain where they are deployed). Checked on
/// Sepolia; the fork tests assert them again.
library PasskeyDeployments {
    address internal constant SIGNER_FACTORY = 0x1d31F259eE307358a26dFb23EB365939E8641195;
    /// @dev `SafeWebAuthnSignerFactory(SIGNER_FACTORY).SINGLETON()`
    address internal constant SIGNER_SINGLETON = 0x4E27b51350e6c2083EE19011120F50DAfEc5CA50;
    address internal constant SHARED_SIGNER = 0x94a4F6affBd8975951142c3999aEAB7ecee555c2;
    /// @dev Fallback Solidity verifiers implementing the EIP-7212 call interface.
    address internal constant FCL_P256_VERIFIER = 0x445a0683e494ea0c5AF3E83c5159fBE47Cf9e765;
    address internal constant DAIMO_P256_VERIFIER = 0xc2b78104907F722DABAc4C69f826a522B2754De4;
    /// @dev EIP-7951 (L1, Fusaka) and RIP-7212 (L2s) share this precompile address.
    uint16 internal constant P256_PRECOMPILE = 0x0100;

    /// @notice `type(SafeWebAuthnSignerProxy).creationCode` exactly as embedded in the canonical
    /// factory's runtime code (bytes 1653..2090). Needed to compute signer addresses offline.
    bytes internal constant SIGNER_PROXY_CREATION_CODE = hex"610100346100ad57601f6101b538819003918201601f19168301916001600160401b038311848410176100b257808492"
        hex"6080946040528339810103126100ad578051906001600160a01b03821682036100ad5760208101516040820151606090"
        hex"920151926001600160b01b03841684036100ad5760805260a05260c05260e05260405160ec90816100c9823960805181"
        hex"6082015260a05181604d015260c051816027015260e0518160010152f35b600080fd5b634e487b7160e01b6000526041"
        hex"60045260246000fdfe7f000000000000000000000000000000000000000000000000000000000000000060b63601527f"
        hex"000000000000000000000000000000000000000000000000000000000000000060a03601527f00000000000000000000"
        hex"0000000000000000000000000000000000000000000036608001523660006080376000806056360160807f0000000000"
        hex"0000000000000000000000000000000000000000000000000000005af43d600060803e60b1573d6080fd5b3d6080f3fe"
        hex"a26469706673582212201660515548d15702d720bbc046b457ca85e941a4559ab9f9518488e4c82e5ee964736f6c6343"
        hex"00081a0033";

    /// @notice Packs the `P256.Verifiers` value: `uint16(precompile) << 160 | uint160(fallback)`.
    function verifiers(uint16 precompile, address fallbackVerifier) internal pure returns (uint176) {
        return (uint176(precompile) << 160) | uint176(uint160(fallbackVerifier));
    }

    /// @notice The recommended configuration: 0x100 precompile with the FCL verifier as fallback.
    function defaultVerifiers() internal pure returns (uint176) {
        return verifiers(P256_PRECOMPILE, FCL_P256_VERIFIER);
    }

    /// @notice Mirrors `SafeWebAuthnSignerFactory.getSigner`: CREATE2 with salt 0 over
    /// `creationCode || singleton || x || y || verifiers` (each constructor arg a 32-byte word).
    function signerAddress(
        address factory,
        bytes memory proxyCreationCode,
        address singleton,
        uint256 x,
        uint256 y,
        uint176 verifiers_
    ) internal pure returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(proxyCreationCode, uint256(uint160(singleton)), x, y, uint256(verifiers_))
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", factory, bytes32(0), initCodeHash)))));
    }

    function canonicalSignerAddress(uint256 x, uint256 y, uint176 verifiers_) internal pure returns (address) {
        return signerAddress(SIGNER_FACTORY, SIGNER_PROXY_CREATION_CODE, SIGNER_SINGLETON, x, y, verifiers_);
    }
}
