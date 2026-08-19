// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice A minimal ERC-1967 delegatecall proxy. State lives in the proxy's
/// storage; logic is borrowed from the implementation via `delegatecall`. The
/// implementation address is held in the ERC-1967 slot so it can never collide
/// with the implementation's own slot 0, 1, 2… . An admin may upgrade it.
contract Proxy {
    // bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
    bytes32 internal constant _IMPL_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)
    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    constructor(address implementation, address admin) {
        _setSlot(_IMPL_SLOT, implementation);
        _setSlot(_ADMIN_SLOT, admin);
    }

    function _getSlot(bytes32 slot) internal view returns (address a) {
        assembly {
            a := sload(slot)
        }
    }

    function _setSlot(bytes32 slot, address value) internal {
        assembly {
            sstore(slot, value)
        }
    }

    function upgradeTo(address newImplementation) external {
        require(msg.sender == _getSlot(_ADMIN_SLOT), "not admin");
        _setSlot(_IMPL_SLOT, newImplementation);
    }

    function implementation() external view returns (address) {
        return _getSlot(_IMPL_SLOT);
    }

    fallback() external payable {
        address impl = _getSlot(_IMPL_SLOT);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}
