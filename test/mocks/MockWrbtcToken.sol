//SPDX-License-Identifier: MIT

// commit: f4aee58fb18703c2a2a536e01bd23c0ead0392db
// git repo: https://github.com/DistributedCollective/Sovryn-smart-contracts
// git file: https://github.com/DistributedCollective/Sovryn-smart-contracts/blob/f4aee58fb18703c2a2a536e01bd23c0ead0392db/contracts/testhelpers/TestWrbtc.sol

pragma solidity 0.8.36;

contract MockWrbtcToken {
    string public name = "Wrapped BTC";
    string public symbol = "WRBTC";
    uint8 public decimals = 18;

    event Approval(address indexed src, address indexed guy, uint256 wad);
    event Transfer(address indexed src, address indexed dst, uint256 wad);
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit(address depositor) public payable {
        balanceOf[depositor] += msg.value;
        emit Deposit(depositor, msg.value);
    }

    function withdraw(uint256 wad) public {
        require(balanceOf[msg.sender] >= wad);
        balanceOf[msg.sender] -= wad;
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }

    function totalSupply() public view returns (uint256) {
        return address(this).balance;
    }

    function approve(address guy, uint256 wad) public returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    function transfer(address dst, uint256 wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint256 wad) public returns (bool) {
        require(balanceOf[src] >= wad);

        if (src != msg.sender /*&& allowance[src][msg.sender] != uint256(-1)*/ ) {
            require(allowance[src][msg.sender] >= wad);
            allowance[src][msg.sender] -= wad;
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);

        return true;
    }

    /**
     * added for local swap implementation
     *
     */
    function mint(address _to, uint256 _value) public {
        require(_to != address(0), "no burn allowed");
        balanceOf[_to] = balanceOf[_to] + _value;
        emit Transfer(address(0), _to, _value);
    }

    /**
     * added for local swap implementation
     *
     */
    function burn(address _who, uint256 _value) public {
        require(_value <= balanceOf[_who], "balance too low");
        // no need to require _value <= totalSupply, since that would imply the
        // sender's balance is greater than the totalSupply, which *should* be an assertion failure

        balanceOf[_who] = balanceOf[_who] - _value;
        emit Transfer(_who, address(0), _value);
    }
}
