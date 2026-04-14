// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MyToken is Ownable {
    string public name = "MyToken";
    string public symbol = "MTK";
    uint8 public decimals = 18;

    mapping(address => uint256) public balances;

    constructor(string memory name_, string memory symbol_) Ownable(msg.sender) {
        balances[msg.sender] = 1000 * (10 ** uint256(decimals)); // Mint initial supply to the owner
    }

    function transfer(address to, uint256 amount) external {
        require(balances[msg.sender] >= amount, "Not enough tokens");
        balances[msg.sender] -= amount;
        balances[to] += amount;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        balances[to] += amount;
    }
}
