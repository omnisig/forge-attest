// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm, SafeTxLib} from "./SafeTx.sol";

/// @title AttestTest
/// @notice Independent (Solidity) recomputation of the Safe transaction hash for
///         the JSON a producer actually emitted. `forge-attest`'s bash side folds
///         the same JSON with `lib/normalize.sh` and hashes it with `cast`; this
///         test proves the two agree and both match the pinned expectation, so
///         no single implementation is trusted.
///
///         Deliberately reads the *raw* producer output rather than the bash
///         side's canonical form: consuming the normalised JSON would make the
///         cross-check blind to a bug in normalisation itself, which is where the
///         interesting work (batch folding, MultiSend packing) happens.
///
///         Inputs come from env (set by attest.sh):
///           ATTEST_JSON                    path to the producer's JSON, under ./out
///           ATTEST_EXPECTED_SAFE_TX_HASH   the hash to assert against
///           ATTEST_SAFE                    Safe address       (batch formats)
///           ATTEST_NONCE                   Safe nonce         (batch formats)
///           ATTEST_CHAIN_ID                chain id           (optional; "" = from JSON)
///           ATTEST_SAFE_VERSION            Safe version       (optional; "" = 1.3.0)
///           ATTEST_MULTISEND               MultiSend override (optional)
///           ATTEST_FORCE_MULTISEND         "1" to wrap a single-transaction batch
///           ATTEST_CHILD_SAFE              child Safe approving on the parent (optional)
///           ATTEST_CHILD_NONCE             that child's nonce
contract AttestTest {
    using SafeTxLib for SafeTxLib.SafeTx;

    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function test_SafeTxHashMatchesExpected() external {
        // This is a driver for attest.sh, not a self-contained unit test: with no
        // claim in the environment there is nothing to check, so a bare
        // `forge test` skips it. The unit coverage lives in SafeTxHash.t.sol.
        string memory path = vm.envOr("ATTEST_JSON", string(""));
        if (bytes(path).length == 0) return;

        string memory json = vm.readFile(path);
        bytes32 expected = vm.parseBytes32(vm.envString("ATTEST_EXPECTED_SAFE_TX_HASH"));

        SafeTxLib.Binding memory b;
        b.safe = _envAddress("ATTEST_SAFE");
        b.nonce = _envUint("ATTEST_NONCE");
        b.chainId = _envUint("ATTEST_CHAIN_ID");
        b.safeVersion = vm.envOr("ATTEST_SAFE_VERSION", string(""));
        b.multiSend = _envAddress("ATTEST_MULTISEND");
        b.forceMultiSend = keccak256(bytes(vm.envOr("ATTEST_FORCE_MULTISEND", string("")))) == keccak256("1");
        // Batch formats carry no gas/refund fields, so they come from the same
        // config the bash side reads. Omitting them here would make a non-zero
        // config diverge between the two derivations.
        b.safeTxGas = _envUint("ATTEST_SAFE_TX_GAS");
        b.baseGas = _envUint("ATTEST_BASE_GAS");
        b.gasPrice = _envUint("ATTEST_GAS_PRICE");
        b.gasToken = _envAddress("ATTEST_GAS_TOKEN");
        b.refundReceiver = _envAddress("ATTEST_REFUND_RECEIVER");

        SafeTxLib.SafeTx memory t = SafeTxLib.readAny(json, b);
        bytes32 computed = t.hash();
        if (b.safe == address(0)) b.safe = t.safe;

        // Publish the computed hash so the orchestrator can display and compare it.
        vm.writeFile("out/solidity-safe-tx-hash.txt", vm.toString(computed));

        // A nested claim: the child Safe approves `computed` on the parent. The
        // approval is constructed here independently of the bash side rather than
        // read back from it, so the two remain a check on each other.
        address child = _envAddress("ATTEST_CHILD_SAFE");
        if (child != address(0)) {
            SafeTxLib.SafeTx memory approval = SafeTxLib.approvalTx(
                b.safe, computed, child, _envUint("ATTEST_CHILD_NONCE"), t.chainId, b.safeVersion
            );
            vm.writeFile("out/solidity-child-safe-tx-hash.txt", vm.toString(approval.hash()));
        }

        require(
            computed == expected,
            string.concat(
                "solidity-derived Safe tx hash ", vm.toString(computed), " != expected ", vm.toString(expected)
            )
        );
    }

    function _envUint(string memory name) private view returns (uint256) {
        string memory v = vm.envOr(name, string(""));
        return bytes(v).length == 0 ? 0 : vm.parseUint(v);
    }

    function _envAddress(string memory name) private view returns (address) {
        string memory v = vm.envOr(name, string(""));
        return bytes(v).length == 0 ? address(0) : vm.parseAddress(v);
    }
}
