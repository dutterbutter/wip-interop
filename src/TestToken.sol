// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Simple mintable ERC20 for testing cross‑chain transfers
contract TestToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    /// @notice Mint tokens to `to`
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
