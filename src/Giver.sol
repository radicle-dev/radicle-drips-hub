// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.24;

import {DripsLib} from "./DripsLib.sol";
import "./IGiver.sol";
import {IDrips} from "./IDrips.sol";
import {Managed} from "./Managed.sol";
import {Clones} from "openzeppelin-contracts/proxy/Clones.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice The implementation of `IGiver`, see its documentation for more details.
contract Giver is IGiver {
    /// @inheritdoc IGiver
    address public immutable owner = msg.sender;

    receive() external payable {}

    /// @notice Delegate call to another contract. This function is callable only by the owner.
    /// @param target The address to delegate to.
    /// @param data The calldata to use when delegating.
    /// @return ret The data returned from the delegation.
    function delegate(address target, bytes memory data)
        public
        payable
        returns (bytes memory ret)
    {
        require(msg.sender == owner, "Caller is not the owner");
        return Address.functionDelegateCall(target, data, "Giver failed");
    }
}

/// @notice The implementation of `IGiversRegistry`, see its documentation for more details.
contract GiversRegistry is IGiversRegistry, Managed {
    /// @inheritdoc IGiversRegistry
    IERC20 public immutable nativeTokenWrapper;
    /// @inheritdoc IGiversRegistry
    IAddressDriver public immutable addressDriver;
    /// @notice The `Drips` contract used by `addressDriver`.
    IDrips internal immutable _drips;

    /// @param addressDriver_ The driver to use to `give`.
    constructor(IAddressDriver addressDriver_) {
        addressDriver = addressDriver_;
        _drips = addressDriver.drips();

        address nativeTokenWrapper_;
        if (block.chainid == 1 /* Mainnet */ ) {
            nativeTokenWrapper_ = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        } else if (block.chainid == 5 /* Goerli */ ) {
            nativeTokenWrapper_ = 0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6;
        } else if (block.chainid == 11155111 /* Sepolia */ ) {
            nativeTokenWrapper_ = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
        } else {
            nativeTokenWrapper_ = address(bytes20("native token wrapper"));
        }
        nativeTokenWrapper = IERC20(nativeTokenWrapper_);
    }

    /// @notice Initialize this instance of the contract.
    function initialize() public onlyProxy {
        if (!Address.isContract(_giverLogic(address(this)))) new Giver();
    }

    /// @inheritdoc IGiversRegistry
    function giver(uint256 accountId) public view onlyProxy returns (address giver_) {
        return _giver(accountId, address(this));
    }

    /// @notice Calculate the address of the `Giver` assigned to the account ID.
    /// @param accountId The ID of the account to which the `Giver` is assigned.
    /// @param deployer The address of the deployer of the `Giver` and its logic.
    /// @return giver_ The address of the `Giver`.
    function _giver(uint256 accountId, address deployer) internal pure returns (address giver_) {
        return
            Clones.predictDeterministicAddress(_giverLogic(deployer), bytes32(accountId), deployer);
    }

    /// @notice Calculate the address of the logic that is cloned for each `Giver`.
    /// @param deployer The address of the deployer of the `Giver` logic.
    /// @param giverLogic The address of the `Giver` logic.
    function _giverLogic(address deployer) internal pure returns (address giverLogic) {
        // The address is calculated assuming that the logic is the first contract
        // deployed by the instance of `GiversRegistry` using plain `CREATE`.
        bytes32 hash = keccak256(abi.encodePacked(hex"D694", deployer, hex"01"));
        return address(uint160(uint256(hash)));
    }

    /// @inheritdoc IGiversRegistry
    function give(uint256 accountId, IERC20 erc20) public onlyProxy returns (uint256 amt) {
        address giver_ = giver(accountId);
        if (!Address.isContract(giver_)) {
            // slither-disable-next-line unused-return
            Clones.cloneDeterministic(_giverLogic(address(this)), bytes32(accountId));
        }
        bytes memory delegateCalldata = abi.encodeCall(this.giveImpl, (accountId, erc20));
        bytes memory returned = Giver(payable(giver_)).delegate(implementation(), delegateCalldata);
        return abi.decode(returned, (uint256));
    }

    /// @notice The delegation target for `Giver`.
    /// Only executable by `Giver` delegation and if `Giver` is called by its deployer.
    /// `give`s to the account all the tokens held by the `Giver` assigned to that account.
    /// @param accountId The ID of the account to which tokens should be `give`n.
    /// It must be the account assigned to the `Giver` on its deployment.
    /// @param erc20 The token to `give` to the account.
    /// If it's the zero address, wraps all the native tokens using
    /// `nativeTokenWrapper`, and then `give`s to the account all the wrapped tokens.
    /// @param amt The amount of tokens that were `give`n.
    function giveImpl(uint256 accountId, IERC20 erc20) public returns (uint256 amt) {
        // `address(this)` in this context should be the `Giver` clone contract.
        require(address(this) == _giver(accountId, msg.sender), "Caller is not GiversRegistry");
        if (address(erc20) == address(0)) {
            erc20 = nativeTokenWrapper;
            // slither-disable-next-line unused-return
            Address.functionCallWithValue(
                address(erc20), "", address(this).balance, "Failed to wrap native tokens"
            );
        }
        (uint256 streamsBalance, uint256 splitsBalance) = _drips.balances(erc20);
        uint256 maxAmt = DripsLib.MAX_TOTAL_BALANCE - streamsBalance - splitsBalance;
        // The balance of the `Giver` clone contract.
        amt = erc20.balanceOf(address(this));
        if (amt > maxAmt) amt = maxAmt;
        // slither-disable-next-line incorrect-equality
        if (amt == 0) return amt;
        SafeERC20.forceApprove(erc20, address(addressDriver), amt);
        addressDriver.give(accountId, erc20, uint128(amt));
    }
}
