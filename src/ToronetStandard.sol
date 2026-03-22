// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

abstract contract ToronetOwnable {
    address private _owner;
    address private initialOwner; // The initial owner who deploys the contract
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _transferOwnership(msg.sender);
        initialOwner = msg.sender; // Set the initial owner
    }
    modifier onlyOwner() {
        _checkOwner();
        _;
    }
    modifier onlyInitialOwner() {
        require(initialOwner == msg.sender, "Ownable: caller is not the initial owner");
        _;
    }

    function owner() public view virtual returns (address) {
        return _owner;
    }

    function _checkOwner() internal view virtual {
        require(owner() == msg.sender, "Ownable: caller is not the owner");
    }

    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }

    function transferOwnership(address newOwner) public virtual onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }

    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // Add the destroy function here
    function destroy() public virtual onlyInitialOwner {
        selfdestruct(payable(initialOwner));
    }
}
