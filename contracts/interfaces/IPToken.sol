// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.0;

interface IPToken {

    function pieceCount() external view returns(uint256);

    function deposit(uint256[] memory nftIds, uint256 blockNumber) external returns(uint256 tokenAmount);

    function withdraw(uint256[] memory nftIds) external returns(uint256 tokenAmount);
}
