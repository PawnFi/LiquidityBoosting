// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.0;

interface INftController {

    function STAKER_ROLE() external view returns(bytes32);
    function grantRole(bytes32 role, address account) external;
}