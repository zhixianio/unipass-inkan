// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

/// @dev The subset of the Safe ABI used by tests and scripts. Identical across 1.3.0, 1.4.1 and 1.5.0
/// (`operation` is the `Enum.Operation` uint8).
interface ISafe {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;

    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);

    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce
    ) external view returns (bytes32);

    function nonce() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function domainSeparator() external view returns (bytes32);
    function VERSION() external view returns (string memory);
}

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
    function proxyCreationCode() external pure returns (bytes memory);
}

interface IMultiSend {
    function multiSend(bytes memory transactions) external payable;
}

interface IWebAuthnSignerFactory {
    function SINGLETON() external view returns (address);
    function getSigner(uint256 x, uint256 y, uint176 verifiers) external view returns (address);
    function createSigner(uint256 x, uint256 y, uint176 verifiers) external returns (address);
    function isValidSignatureForSigner(
        bytes32 message,
        bytes calldata signature,
        uint256 x,
        uint256 y,
        uint176 verifiers
    ) external view returns (bytes4);
}

interface IWebAuthnSigner {
    /// @dev ERC-1271, used by Safe 1.5.0. Returns 0x1626ba7e.
    function isValidSignature(bytes32 message, bytes calldata signature) external view returns (bytes4);
    /// @dev Legacy Safe `ISignatureValidator`, used by Safe 1.3.0 / 1.4.1. Hashes `data` with
    /// keccak256 first. Returns 0x20c13b0b.
    function isValidSignature(bytes memory data, bytes calldata signature) external view returns (bytes4);
    function getConfiguration() external view returns (uint256 x, uint256 y, uint176 verifiers);
}
