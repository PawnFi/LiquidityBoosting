// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.0;

interface IPTokenFactory {

    function nftTransferManager() external view returns(address);

    function getNftAddress(address ptokenAddr) external view returns(address);
    function getPiece(address nftAddr) external view returns(address);
}