//SPDX-License-Identifier: MIT
//Create by evabase.network core team.
pragma solidity ^0.8.0;

interface IEvaSafes {
    function initialize(address admin, address agent) external;

    function owner() external returns (address);

    function getRunningTask() external view returns (uint256);

    function multicall(uint256 taskId, bytes[] calldata data)
        external
        returns (bytes[] memory results);

    function multicallWithValue(uint256 taskId, bytes[] calldata data)
        external
        returns (bytes[] memory results);

    function setRevoke(bool revoke) external;

    function refund(address token, uint256 amount) external;

    function refundETH(uint256 amount) external;
    // function setControl(address add, bool revoke) external;
}