// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

interface IChangeContract {
    function execute() external;
}

contract GovernorMock {
    bool public isAuthorized = true;

    function executeChange(IChangeContract changeContract) external {
        changeContract.execute();
    }

    function isAuthorizedChanger(address) external view returns (bool) {
        return isAuthorized;
    }

    function setIsAuthorized(bool isAuthorized_) public {
        isAuthorized = isAuthorized_;
    }
}


