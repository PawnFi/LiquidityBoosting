// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.0;

interface IFundingStrategy {

    function getInvestmentPrice(uint256 _roundId) external view returns(uint256);

    function getRealTimePrice(address token0, address token1, uint24 fee, uint160 sqrtPriceX96) external view returns(uint256);

    function executeStrategy(uint256 _roundId) external;

    function exitedStrategy(uint256 _roundId) external;

    function getAmountsForLiquidity(uint256 _roundId) external view returns(uint256 amount0, uint256 amount1);

    function getLendInfos(uint256 _roundId) external returns(uint256 capital0, uint256 capital1, uint256 bonus0, uint256 bonus1);

    function getSwapFees(uint256 _roundId) external returns(uint256 token0Fee, uint256 token1Fee);
}