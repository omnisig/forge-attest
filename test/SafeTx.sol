// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Inline cheatcode surface — forge-attest's verifier has no Solidity
///      dependencies (no forge-std, nothing to `forge install`, nothing to drift).
interface Vm {
    function envString(string calldata name) external view returns (string memory);
    function envOr(string calldata name, string calldata defaultValue) external view returns (string memory);
    function readFile(string calldata path) external view returns (string memory);
    function writeFile(string calldata path, string calldata data) external;
    function keyExistsJson(string calldata json, string calldata key) external view returns (bool);
    function parseJsonAddress(string calldata json, string calldata key) external view returns (address);
    function parseJsonUint(string calldata json, string calldata key) external view returns (uint256);
    function parseJsonBytes(string calldata json, string calldata key) external view returns (bytes memory);
    function parseJsonString(string calldata json, string calldata key) external view returns (string memory);
    function parseBytes32(string calldata value) external pure returns (bytes32);
    function parseUint(string calldata value) external pure returns (uint256);
    function parseAddress(string calldata value) external pure returns (address);
    function toString(bytes32 value) external pure returns (string memory);
    function toString(uint256 value) external pure returns (string memory);
    function toString(address value) external pure returns (string memory);
}

/// @title SafeTxLib
/// @notice Solidity model of a Gnosis Safe transaction, plus readers for every
///         JSON shape forge-attest accepts. This is the *second, independent*
///         implementation of the hash derivation — `lib/derive.sh` computes the
///         same values with `cast`, and the two are compared on every run so no
///         single implementation is trusted.
///
///         Targets Safe >= 1.3.0 (chainId in the EIP-712 domain, `baseGas` field
///         name), matching `lib/derive.sh`.
library SafeTxLib {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    bytes32 internal constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
    bytes32 internal constant SAFE_TX_TYPEHASH = keccak256(
        "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"
    );

    /// @dev The contracts Safe{Wallet} delegatecalls to execute a batch. `CallOnly`
    ///      is the default and refuses inner DELEGATECALLs; the plain MultiSend
    ///      allows them.
    address internal constant MULTI_SEND_CALL_ONLY_1_3_0 = 0x40A2aCCbd92BCA938b02010E17A5b8929b49130D;
    address internal constant MULTI_SEND_CALL_ONLY_1_4_1 = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;

    /// @notice The full EIP-712 SafeTx field set — forge-attest's canonical form.
    struct SafeTx {
        address safe;
        uint256 chainId;
        string safeVersion;
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
        uint256 safeTxGas;
        uint256 baseGas;
        uint256 gasPrice;
        address gasToken;
        address refundReceiver;
        uint256 nonce;
    }

    /// @notice One entry of a Transaction Builder batch.
    struct InnerTx {
        address to;
        uint256 value;
        bytes data;
        uint8 operation;
    }

    /// @notice What a batch cannot tell us and the config must supply.
    struct Binding {
        address safe;
        uint256 nonce;
        uint256 chainId; // 0 = take it from the JSON
        string safeVersion; // "" = 1.3.0
        address multiSend; // address(0) = canonical MultiSendCallOnly for safeVersion
        bool forceMultiSend; // wrap even a single-transaction batch
    }

    // ---------------------------------------------------------------- hashing

    function domainSeparator(uint256 chainId, address safe) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, chainId, safe));
    }

    function structHash(SafeTx memory t) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SAFE_TX_TYPEHASH,
                t.to,
                t.value,
                keccak256(t.data),
                t.operation,
                t.safeTxGas,
                t.baseGas,
                t.gasPrice,
                t.gasToken,
                t.refundReceiver,
                t.nonce
            )
        );
    }

    /// @notice The digest Safe owners actually sign.
    function hash(SafeTx memory t) internal pure returns (bytes32) {
        require(atLeast130(t.safeVersion), "SafeTxLib: Safe < 1.3.0 is not supported by this deriver");
        return keccak256(
            abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator(t.chainId, t.safe), structHash(t))
        );
    }

    // ------------------------------------------------------------- multi-send

    /// @notice The packed MultiSend payload: for each transaction,
    ///         `abi.encodePacked(uint8 operation, address to, uint256 value,
    ///         uint256 data.length, bytes data)`.
    function encodeMultiSendPayload(InnerTx[] memory txs) internal pure returns (bytes memory payload) {
        for (uint256 i = 0; i < txs.length; i++) {
            payload = abi.encodePacked(payload, txs[i].operation, txs[i].to, txs[i].value, txs[i].data.length, txs[i].data);
        }
    }

    /// @notice `multiSend(bytes)` calldata for the packed payload.
    function encodeMultiSendCalldata(InnerTx[] memory txs) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("multiSend(bytes)", encodeMultiSendPayload(txs));
    }

    /// @notice Fold a batch into the single SafeTx its owners sign — mirroring
    ///         what Safe{Wallet} does when it submits a Transaction Builder batch.
    function toSafeTx(InnerTx[] memory txs, Binding memory b, uint256 jsonChainId)
        internal
        pure
        returns (SafeTx memory t)
    {
        require(txs.length > 0, "SafeTxLib: batch contains no transactions");

        t.safe = b.safe;
        t.chainId = b.chainId == 0 ? jsonChainId : b.chainId;
        t.safeVersion = bytes(b.safeVersion).length == 0 ? "1.3.0" : b.safeVersion;
        t.nonce = b.nonce;
        require(t.safe != address(0), "SafeTxLib: no Safe address");
        require(t.chainId != 0, "SafeTxLib: no chainId");

        if (txs.length == 1 && !b.forceMultiSend) {
            t.to = txs[0].to;
            t.value = txs[0].value;
            t.data = txs[0].data;
            t.operation = txs[0].operation;
            return t;
        }

        address multiSend = b.multiSend;
        if (multiSend == address(0)) {
            multiSend = _isV14(t.safeVersion) ? MULTI_SEND_CALL_ONLY_1_4_1 : MULTI_SEND_CALL_ONLY_1_3_0;
        }

        bool callOnly = multiSend == MULTI_SEND_CALL_ONLY_1_3_0 || multiSend == MULTI_SEND_CALL_ONLY_1_4_1;
        for (uint256 i = 0; i < txs.length; i++) {
            require(txs[i].operation <= 1, "SafeTxLib: inner operation must be 0 or 1");
            require(
                !(callOnly && txs[i].operation == 1),
                "SafeTxLib: inner DELEGATECALL rejected by MultiSendCallOnly"
            );
        }

        t.to = multiSend;
        t.value = 0;
        t.data = encodeMultiSendCalldata(txs);
        t.operation = 1; // MultiSend is always DELEGATECALLed from the Safe
    }

    // ------------------------------------------------------------ JSON reading

    /// @notice Read forge-attest's canonical SafeTx JSON (all scalars quoted).
    function readCanonical(string memory json) internal view returns (SafeTx memory t) {
        t.safe = vm.parseJsonAddress(json, ".safe");
        t.chainId = vm.parseJsonUint(json, ".chainId");
        t.safeVersion = vm.keyExistsJson(json, ".safeVersion") ? vm.parseJsonString(json, ".safeVersion") : "1.3.0";
        t.to = vm.parseJsonAddress(json, ".to");
        t.value = vm.parseJsonUint(json, ".value");
        t.data = _optionalBytes(json, ".data");
        t.operation = uint8(vm.parseJsonUint(json, ".operation"));
        t.safeTxGas = vm.parseJsonUint(json, ".safeTxGas");
        t.baseGas = vm.parseJsonUint(json, ".baseGas");
        t.gasPrice = vm.parseJsonUint(json, ".gasPrice");
        t.gasToken = vm.parseJsonAddress(json, ".gasToken");
        t.refundReceiver = vm.parseJsonAddress(json, ".refundReceiver");
        t.nonce = vm.parseJsonUint(json, ".nonce");
    }

    /// @notice Read a Safe{Wallet} Transaction Builder batch (`.transactions`) or
    ///         a bare JSON array of the same entries.
    /// @dev Scalars may be JSON numbers or quoted strings — producers differ, and
    ///      `parseJsonUint` accepts both. `operation` defaults to 0 (CALL).
    function readBatch(string memory json) internal view returns (InnerTx[] memory txs) {
        string memory base = vm.keyExistsJson(json, ".transactions[0].to") ? ".transactions" : "";

        uint256 n;
        while (vm.keyExistsJson(json, string.concat(base, "[", vm.toString(n), "].to"))) {
            n++;
        }
        require(n > 0, "SafeTxLib: batch contains no transactions");

        txs = new InnerTx[](n);
        for (uint256 i = 0; i < n; i++) {
            string memory at = string.concat(base, "[", vm.toString(i), "]");
            require(
                !vm.keyExistsJson(json, string.concat(at, ".contractMethod"))
                    || _optionalBytes(json, string.concat(at, ".data")).length > 0,
                "SafeTxLib: contractMethod without encoded data"
            );
            txs[i] = InnerTx({
                to: vm.parseJsonAddress(json, string.concat(at, ".to")),
                value: vm.keyExistsJson(json, string.concat(at, ".value"))
                    ? vm.parseJsonUint(json, string.concat(at, ".value"))
                    : 0,
                data: _optionalBytes(json, string.concat(at, ".data")),
                operation: vm.keyExistsJson(json, string.concat(at, ".operation"))
                    ? uint8(vm.parseJsonUint(json, string.concat(at, ".operation")))
                    : 0
            });
        }
    }

    /// @notice chainId from a batch JSON, or 0 when the batch doesn't carry one
    ///         (a bare array never does).
    function readChainId(string memory json) internal view returns (uint256) {
        return vm.keyExistsJson(json, ".chainId") ? vm.parseJsonUint(json, ".chainId") : 0;
    }

    /// @notice Read any supported shape and fold it into the SafeTx to be signed.
    function readAny(string memory json, Binding memory b) internal view returns (SafeTx memory) {
        if (vm.keyExistsJson(json, ".transactions[0].to") || vm.keyExistsJson(json, "[0].to")) {
            return toSafeTx(readBatch(json), b, readChainId(json));
        }
        return readCanonical(json);
    }

    // ----------------------------------------------------------------- helpers

    /// @dev `data` is routinely absent or explicitly `null` for plain value
    ///      transfers, which `parseJsonBytes` refuses outright.
    function _optionalBytes(string memory json, string memory key) private view returns (bytes memory) {
        if (!vm.keyExistsJson(json, key)) return "";
        try Vm(address(vm)).parseJsonBytes(json, key) returns (bytes memory d) {
            return d;
        } catch {
            return "";
        }
    }

    /// @dev True for Safe >= 1.3.0, whose EIP-712 domain binds `chainId`. Older
    ///      Safes use a chainId-free domain and are out of scope here (the live
    ///      check via `safe_hashes.sh` still covers them).
    function atLeast130(string memory version) internal pure returns (bool) {
        (uint256 major, uint256 minor) = _majorMinor(version);
        if (major > 1) return true;
        return major == 1 && minor >= 3;
    }

    function _isV14(string memory version) private pure returns (bool) {
        (uint256 major, uint256 minor) = _majorMinor(version);
        return major == 1 && minor >= 4;
    }

    function _majorMinor(string memory version) private pure returns (uint256 major, uint256 minor) {
        bytes memory v = bytes(version);
        uint256 i;
        for (; i < v.length && v[i] != "."; i++) {
            major = major * 10 + _digit(v[i]);
        }
        for (i = i + 1; i < v.length && v[i] != "."; i++) {
            minor = minor * 10 + _digit(v[i]);
        }
    }

    function _digit(bytes1 c) private pure returns (uint256) {
        require(c >= "0" && c <= "9", "SafeTxLib: malformed safeVersion");
        return uint8(c) - 48;
    }
}
