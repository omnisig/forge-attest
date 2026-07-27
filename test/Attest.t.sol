// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Inline cheatcode surface — this verifier has no Solidity dependencies.
interface Vm {
    function envString(string calldata name) external view returns (string memory);
    function readFile(string calldata path) external view returns (string memory);
    function writeFile(string calldata path, string calldata data) external;
    function parseJsonAddress(string calldata json, string calldata key) external pure returns (address);
    function parseJsonUint(string calldata json, string calldata key) external pure returns (uint256);
    function parseJsonBytes(string calldata json, string calldata key) external pure returns (bytes memory);
    function parseBytes32(string calldata value) external pure returns (bytes32);
    function toString(bytes32 value) external pure returns (string memory);
}

/// @title AttestTest
/// @notice Independent (Solidity) recomputation of the Gnosis Safe EIP-712
///         transaction hash from the producer's JSON. `forge-attest`'s bash side
///         derives the same hash via `cast`; this test proves the two agree and
///         both match the pinned expectation — so the derivation isn't trusting a
///         single implementation.
///
///         Inputs come from env (set by attest.sh):
///           ATTEST_JSON                    path to the SafeTx JSON (under ./out)
///           ATTEST_EXPECTED_SAFE_TX_HASH   the hash to assert against
///
///         Targets Safe >= 1.3.0 (chainId in the domain, `baseGas` field name),
///         matching lib/derive.sh.
contract AttestTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
    bytes32 internal constant SAFE_TX_TYPEHASH = keccak256(
        "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"
    );

    struct SafeTx {
        address safe;
        uint256 chainId;
        address to;
        uint256 value;
        bytes data;
        uint256 operation;
        uint256 safeTxGas;
        uint256 baseGas;
        uint256 gasPrice;
        address gasToken;
        address refundReceiver;
        uint256 nonce;
    }

    function test_SafeTxHashMatchesExpected() external {
        string memory json = vm.readFile(vm.envString("ATTEST_JSON"));
        bytes32 expected = vm.parseBytes32(vm.envString("ATTEST_EXPECTED_SAFE_TX_HASH"));

        bytes32 computed = _safeTxHash(_load(json));

        // Publish the computed hash so the orchestrator can display/compare it.
        vm.writeFile("out/solidity-safe-tx-hash.txt", vm.toString(computed));

        require(computed == expected, "solidity-derived Safe tx hash != expected");
    }

    function _load(string memory json) internal pure returns (SafeTx memory t) {
        t.safe = vm.parseJsonAddress(json, ".safe");
        t.chainId = vm.parseJsonUint(json, ".chainId");
        t.to = vm.parseJsonAddress(json, ".to");
        t.value = vm.parseJsonUint(json, ".value");
        t.data = vm.parseJsonBytes(json, ".data");
        t.operation = vm.parseJsonUint(json, ".operation");
        t.safeTxGas = vm.parseJsonUint(json, ".safeTxGas");
        t.baseGas = vm.parseJsonUint(json, ".baseGas");
        t.gasPrice = vm.parseJsonUint(json, ".gasPrice");
        t.gasToken = vm.parseJsonAddress(json, ".gasToken");
        t.refundReceiver = vm.parseJsonAddress(json, ".refundReceiver");
        t.nonce = vm.parseJsonUint(json, ".nonce");
    }

    function _safeTxHash(SafeTx memory t) internal pure returns (bytes32) {
        bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_TYPEHASH, t.chainId, t.safe));
        bytes32 structHash = keccak256(
            abi.encode(
                SAFE_TX_TYPEHASH,
                t.to,
                t.value,
                keccak256(t.data),
                uint8(t.operation),
                t.safeTxGas,
                t.baseGas,
                t.gasPrice,
                t.gasToken,
                t.refundReceiver,
                t.nonce
            )
        );
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator, structHash));
    }
}
