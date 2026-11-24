// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Test double for the SPACE ID Agent ID registry: an address "holds"
///         an Agent ID iff it was marked. Used only in local tests.
contract MockRegistry {
    mapping(address => bool) public holders;

    function setHolder(address who, bool holds) external {
        holders[who] = holds;
    }

    function balanceOf(address who) external view returns (uint256) {
        return holders[who] ? 1 : 0;
    }
}

/// @notice Minimal ERC-20 test double (USDT-style) for local tests.
contract MockToken {
    string public name = "Mock USD";
    string public symbol = "MUSD";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "no allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
