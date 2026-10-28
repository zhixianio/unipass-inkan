// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @title Canonical Safe deployments used by the fork tests
/// @notice From safe-deployments; checked on Sepolia (`VERSION()` and code present).
library SafeDeployments {
    struct Deployment {
        string version;
        address singleton; // L1 `Safe` / `GnosisSafe` (SafeL2 differs only in events)
        address proxyFactory;
        address fallbackHandler; // CompatibilityFallbackHandler
    }

    address internal constant MULTI_SEND_CALL_ONLY_141 = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    /// @dev `SafeL2` 1.4.1: same signature checks as `Safe`, plus events that event-based indexers
    /// (Safe Transaction Service on L2s and testnets) rely on.
    address internal constant SAFE_L2_141 = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;

    function v130() internal pure returns (Deployment memory) {
        return Deployment(
            "1.3.0",
            0xd9Db270c1B5E3Bd161E8c8503c55cEABeE709552,
            0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2,
            0xf48f2B2d2a534e402487b3ee7C18c33Aec0Fe5e4
        );
    }

    function v141() internal pure returns (Deployment memory) {
        return Deployment(
            "1.4.1",
            0x41675C099F32341bf84BFc5382aF534df5C7461a,
            0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67,
            0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99
        );
    }

    function v150() internal pure returns (Deployment memory) {
        return Deployment(
            "1.5.0",
            0xFf51A5898e281Db6DfC7855790607438dF2ca44b,
            0x14F2982D601c9458F93bd70B218933A6f8165e7b,
            0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4
        );
    }
}
