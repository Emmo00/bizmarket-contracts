// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "./Ownable.sol";

contract TestStablecoin is ERC20, Ownable {
    constructor(string memory name_, string memory symbol_, address owner_) ERC20(name_, symbol_) {
        // _transferOwnership(owner_); // Set the initial owner to the specified address
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
