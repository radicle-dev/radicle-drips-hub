// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {
    ILayerZeroReceiver,
    Origin
} from "layer-zero-v2/protocol/contracts/interfaces/ILayerZeroReceiver.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

/// @notice Description of a call.
/// @param target The called address.
/// @param data The calldata to be used for the call.
/// @param value The value of the call.
struct Call {
    address target;
    bytes data;
    uint256 value;
}

function runCalls(Call[] memory calls) {
    for (uint256 i = 0; i < calls.length; i++) {
        Call memory call = calls[i];
        Address.functionCallWithValue(call.target, call.data, call.value);
    }
}

contract BridgedGovernor is UUPSUpgradeable, ILayerZeroReceiver {
    address public immutable endpoint;
    uint32 public immutable ownerEid;
    bytes32 public immutable owner;

    uint64 internal _lastNonce;

    constructor(address endpoint_, uint32 ownerEid_, bytes32 owner_) {
        // slither-disable-next-line missing-zero-check
        endpoint = endpoint_;
        ownerEid = ownerEid_;
        owner = owner_;
    }

    function allowInitializePath(Origin calldata origin) public view onlyProxy returns (bool) {
        return origin.srcEid == ownerEid && origin.sender == owner;
    }

    function nextNonce(uint32 srcEid, bytes32 sender)
        public
        view
        onlyProxy
        returns (uint64 nextNonce_)
    {
        if (srcEid == ownerEid && sender == owner) nextNonce_ = _lastNonce + 1;
    }

    function lzReceive(
        Origin calldata origin,
        bytes32, /* guid */
        bytes calldata message,
        address, /* executor */
        bytes calldata /* extraData */
    ) public payable onlyProxy {
        require(msg.sender == endpoint, "Must be called by the endpoint");
        require(origin.srcEid == ownerEid, "Invalid message source chain");
        require(origin.sender == owner, "Invalid message sender");
        require(origin.nonce == _lastNonce + 1, "Invalid message nonce");
        // slither-disable-next-line events-maths
        _lastNonce = origin.nonce;
        runCalls(abi.decode(message, (Call[])));
    }

    function _authorizeUpgrade(address /* newImplementation */ ) internal view override {
        require(msg.sender == address(this), "Only upgradeable by self");
    }
}

contract BridgedGovernorProxy is ERC1967Proxy {
    constructor(address logic, Call[] memory calls) ERC1967Proxy(logic, "") {
        runCalls(calls);
    }
}
