// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/utils/ERC721HolderUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "./MulticallUpgradeable.sol";
import "./interfaces/IWETH.sol";
import "./interfaces/IPTokenFactory.sol";
import "./interfaces/IPToken.sol";
import "./interfaces/IFundingStrategy.sol";
import "./libraries/TransferHelper.sol";

/**
 * @title Pawnfi's LB Contract
 * @author Pawnfi
 */
contract LB is MulticallUpgradeable, OwnableUpgradeable, ERC721HolderUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    // Denominator, used for calculating percentage
    uint256 private constant BASE = 1e18;

    /// @notice WETH address
    address public WETH;

    /// @notice ptoken factory address
    address public ptokenFactory;

    /// @notice Floating percentage for calculating rational price range - to provide liquidity on Uniswap
    uint256 public floatingPercentage;

    /// @notice Strategy address
    address public strategy;

    /**
     * @dev Fundraising status
     */
    enum FundraisingStatus { processing, finished, received, canceled }

    /**
     * @notice Fundraising info
     * @member startTime Start time
     * @member endTime End time
     * @member unlockTime Unlock time
     * @member fee uniswap fee tier
     * @member sqrtPriceX96 Expected square root price when adding liquidity
     * @member tickLower Min price
     * @member tickUpper Max price
     * @member rewardToken Reward token address
     * @member token0 token0 address
     * @member token1 token1 address
     * @member fundraisingStatus Fundraising status
     * @member rewardAmounts Reward token amount when event completes
     * @member targetAmounts Target amount
     * @member amounts Raised amount
     */
    struct FundraisingInfo {
        uint32 startTime;
        uint32 endTime;
        uint32 unlockTime;
        uint24 fee;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        address rewardToken;
        address token0;
        address token1;
        FundraisingStatus fundraisingStatus;
        mapping(address => uint256) rewardAmounts;
        mapping(address => uint256) targetAmounts;
        mapping(address => uint256) amounts;
    }

    /**
     * @notice User info
     * @member nftIds Comitted nft id list
     * @member depositAmount Comitted asset amount
     * @member withdrawAmount Withdrawalbe asset amount
     */
    struct UserInfo {
        mapping(address => EnumerableSetUpgradeable.UintSet) nftIds;
        mapping(address => uint256) depositAmount;
        mapping(address => uint256) withdrawAmount;
    }

    /// @notice Latest EventID
    uint256 public roundId;

    // Store fundraising info of different Event ID
    mapping(uint256 => FundraisingInfo) private _fundraisingInfoMap;

    // Store user info of different Event ID
    mapping(address => mapping(uint256 => UserInfo)) private _userInfoMap;

    /// @notice Emitted event info when fundraising launches
    event OrganiseEvent(
        uint256 indexed roundId,
        address indexed account,
        address rewardToken,
        address token0,
        address token1,
        uint256 rewardAmount0,
        uint256 rewardAmount1,
        uint256 targetAmount0,
        uint256 targetAmount1,
        uint32 startTime,
        uint32 endTime,
        uint32 unlockTime
    );

    /// @notice Emitted market making info when fundraising launches
    event MarketMakingInfo(uint256 indexed roundId, uint24 fee, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper);

    /// @notice Emitted when fundraising completes
    event RaisingSuccess(uint256 indexed roundId, uint256 price);

    /// @notice Emitted when cancelling fundraising
    event RaisingCancel(uint256 indexed roundId);

    /// @notice Emitted when committing in NFT
    event RaiseFundsNFT(uint256 indexed roundId, address indexed account, address nft, uint256[] nftIds);

    /// @notice Emitted when participating in fundraising
    event RaiseFunds(uint256 indexed roundId, address indexed account, address token, uint256 totalDepositAmount, uint256 totalAmount);

    /// @notice Emitted when redeeming NFT
    event RedeemNft(uint256 indexed roundId, address indexed account, address nft, uint256[] ids);

    /// @notice Emitted when applying refund - fundraising failed
    event RefundAsset(uint256 indexed roundId, address indexed account, address token0, address token1, uint256 amount0, uint256 amount1);

    /// @notice Emitted when withdrawing - fundraising succeeded
    event WithdrawAsset(
        uint256 indexed roundId,
        address indexed account,
        address token0,
        address token1,
        uint256 liquidityAmount0,
        uint256 liquidityAmount1,
        uint256 swapFee0,
        uint256 swapFee1,
        uint256 bonus0,
        uint256 bonus1,
        uint256 rewardAmount
    );

    /// @notice Emitted when claiming asset
    event Claim(uint256 indexed roundId, address indexed account);
    
    /// @notice Emitted when claiming reward token
    event ClaimRewardToken(uint256 indexed roundId, address indexed account);

    /**
     * @notice Initialize contract parameters - only execute once
     * @param owner_ Owner address
     * @param WETH_ WETH address
     * @param ptokenFactory_ ptkoen factory address
     * @param floatingPercentage_ Floating percentage for calculating rational price range - to provide liquidity on Uniswap
     */
    function initialize(address owner_, address WETH_, address ptokenFactory_, uint256 floatingPercentage_) external initializer {
        _transferOwnership(owner_);

        WETH = WETH_;
        ptokenFactory = ptokenFactory_;
        floatingPercentage = floatingPercentage_;
    }

    /**
     * @notice Set new strategy address - exclusive to owner
     * @param newStrategy New strategy address
     */
    function setStrategy(address newStrategy) external onlyOwner {
        strategy = newStrategy;
    }

    /**
     * @notice Set new floating percentage - exclusive to owner
     * @param newFloatingPercentage New floating percentage
     */
    function setFloatingPercentage(uint256 newFloatingPercentage) external onlyOwner {
        floatingPercentage = newFloatingPercentage;
    }

    struct OrganiseEventParams {
        uint32 startTime;
        uint32 endTime;
        uint32 unlockTime;
        uint24 fee;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        address rewardToken;
        address token0;
        address token1;
        uint256 rewardAmount0;
        uint256 rewardAmount1;
        uint256 targetAmount0;
        uint256 targetAmount1;
    }

    /**
     * @notice Initiate fundraising - exclusive to owner
     * @param organiseEventParams Fundraising info
     */
    function organiseEvent(OrganiseEventParams memory organiseEventParams) external onlyOwner {
        require(
            organiseEventParams.startTime >= block.timestamp &&
            organiseEventParams.startTime < organiseEventParams.endTime &&
            organiseEventParams.endTime < organiseEventParams.unlockTime,
            "time error"
        );
        require(organiseEventParams.token0 < organiseEventParams.token1, "sort error");
        require(organiseEventParams.token0 != address(0), "token error");

        roundId++;
        FundraisingInfo storage info = _fundraisingInfoMap[roundId];
        info.startTime = organiseEventParams.startTime;
        info.endTime = organiseEventParams.endTime;
        info.unlockTime = organiseEventParams.unlockTime;
        info.fee = organiseEventParams.fee;
        info.sqrtPriceX96 = organiseEventParams.sqrtPriceX96;
        info.tickLower = organiseEventParams.tickLower;
        info.tickUpper = organiseEventParams.tickUpper;
        info.rewardToken = organiseEventParams.rewardToken;
        info.token0 = organiseEventParams.token0;
        info.token1 = organiseEventParams.token1;
        info.rewardAmounts[organiseEventParams.token0] = organiseEventParams.rewardAmount0;
        info.rewardAmounts[organiseEventParams.token1] = organiseEventParams.rewardAmount1;
        info.targetAmounts[organiseEventParams.token0] = organiseEventParams.targetAmount0;
        info.targetAmounts[organiseEventParams.token1] = organiseEventParams.targetAmount1;

        emit OrganiseEvent(
            roundId,
            msg.sender,
            organiseEventParams.rewardToken,
            organiseEventParams.token0,
            organiseEventParams.token1,
            organiseEventParams.rewardAmount0,
            organiseEventParams.rewardAmount1,
            organiseEventParams.targetAmount0,
            organiseEventParams.targetAmount1,
            organiseEventParams.startTime,
            organiseEventParams.endTime,
            organiseEventParams.unlockTime
        );
        emit MarketMakingInfo(roundId, organiseEventParams.fee, organiseEventParams.sqrtPriceX96, organiseEventParams.tickLower, organiseEventParams.tickUpper);
    }

    /**
     * @notice Get fundraising info based on EventID
     * @param rId EventID
     * @return startTime raising start time
     * @return endTime raising end time
     * @return unlockTime token unlock time
     * @return rewardToken reward token
     * @return token0 token0 address
     * @return token1 token1 address
     * @return rewardAmount0 token0 reward amount assigned
     * @return rewardAmount1 token1 reward amount assigned
     * @return targetAmount0 token0 target amount
     * @return targetAmount1 token1 target amount
     * @return amount0 token0 raised amount
     * @return amount1 token1 raised amount
     */
    function getFundraisingInfo(uint256 rId)
        external
        view
        returns (
            uint32 startTime,
            uint32 endTime,
            uint32 unlockTime,
            address rewardToken,
            address token0,
            address token1,
            uint256 rewardAmount0,
            uint256 rewardAmount1,
            uint256 targetAmount0,
            uint256 targetAmount1,
            uint256 amount0,
            uint256 amount1
        )
    {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];
        
        startTime = raisingInfo.startTime;
        endTime = raisingInfo.endTime;
        unlockTime = raisingInfo.unlockTime;

        rewardToken = raisingInfo.rewardToken;
        (token0, token1, targetAmount0, targetAmount1, amount0, amount1) = getAmountsInfo(rId);
        
        rewardAmount0 = raisingInfo.rewardAmounts[token0];
        rewardAmount1 = raisingInfo.rewardAmounts[token1];
    }

    /**
     * @notice Get raised amount info
     * @param rId EventID
     * @return token0 token0 address
     * @return token1 token1 address
     * @return targetAmount0 token0 target amount
     * @return targetAmount1 token1 target amount
     * @return amount0 token0 raised amount
     * @return amount1 token1 raised amount
     */
    function getAmountsInfo(uint256 rId) public view returns (address token0, address token1, uint256 targetAmount0, uint256 targetAmount1, uint256 amount0, uint256 amount1) {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];
        token0 = raisingInfo.token0;
        token1 = raisingInfo.token1; 
        targetAmount0 = raisingInfo.targetAmounts[token0];
        targetAmount1 = raisingInfo.targetAmounts[token1];
        amount0 = raisingInfo.amounts[token0];
        amount1 = raisingInfo.amounts[token1];
    }

    /**
     * @notice Get market making info based on EventID
     * @param rId EventID
     * @return fee uniswap fee tier
     * @return sqrtPriceX96 Expected square root price
     * @return tickLower Min price
     * @return tickUpper Max price
     * @return token0 token0 address
     * @return token1 token1 address
     */
    function getMarketMakingInfo(uint256 rId) external view returns (uint24 fee, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, address token0, address token1) {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];

        fee = raisingInfo.fee;
        sqrtPriceX96 = raisingInfo.sqrtPriceX96;
        tickLower = raisingInfo.tickLower;
        tickUpper = raisingInfo.tickUpper;

        token0 = raisingInfo.token0;
        token1 = raisingInfo.token1;
    }

    /**
     * @notice Get fundraising status
     * @param rId EventID
     * @return status Event status
     */
    function getFundraisingStatus(uint256 rId) public view returns (FundraisingStatus status) {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];
        status = raisingInfo.fundraisingStatus;
    }

    /**
     * @notice Get user info
     * @param user User address
     * @param rId EventID
     * @return token0 token0 address
     * @return token1 token1 address
     * @return amount0 Committed token0 amount
     * @return amount1 Committed token1 amount
     * @return withdrawAmount0 Withdrawable token0 amount
     * @return withdrawAmount1 Withdrawable token1 amount
     * @return idsAtToken0 token0 nft array
     * @return idsAtToken1 token1 nft array
     */
    function getUserInfo(address user, uint256 rId)
        public
        view
        returns (
            address token0,
            address token1,
            uint256 amount0,
            uint256 amount1,
            uint256 withdrawAmount0,
            uint256 withdrawAmount1,
            uint256[] memory idsAtToken0,
            uint256[] memory idsAtToken1
        )
    {
        UserInfo storage userInfo = _userInfoMap[user][rId];
        token0 = _fundraisingInfoMap[rId].token0;
        token1 = _fundraisingInfoMap[rId].token1;

        amount0 = userInfo.depositAmount[token0];
        amount1 = userInfo.depositAmount[token1];

        withdrawAmount0 = userInfo.withdrawAmount[token0];
        withdrawAmount1 = userInfo.withdrawAmount[token1];

        EnumerableSetUpgradeable.UintSet storage nftIdsAtToken0 = _userInfoMap[user][rId].nftIds[token0];
        EnumerableSetUpgradeable.UintSet storage nftIdsAtToken1 = _userInfoMap[user][rId].nftIds[token1];
        
        idsAtToken0 = new uint256[](nftIdsAtToken0.length());
        for(uint i = 0; i < nftIdsAtToken0.length(); i++) {
            idsAtToken0[i] = nftIdsAtToken0.at(i);
        }

        idsAtToken1 = new uint256[](nftIdsAtToken1.length());
        for(uint i = 0; i < nftIdsAtToken1.length(); i++) {
            idsAtToken1[i] = nftIdsAtToken1.at(i);
        }
    }

    /**
     * @notice Validate whether committing is allowed
     * @param rId Event ID
     * @param token Token address
     * @param amount Committed amount
     * @return Difference from target amount
     */
    function _raiseAllowed(uint256 rId, address token, uint256 amount) private view returns (uint256) {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];
        require(block.timestamp >= raisingInfo.startTime && block.timestamp <= raisingInfo.endTime, "out of time frame");
        require(raisingInfo.fundraisingStatus == FundraisingStatus.processing, "fundraising status isn't processing");
        uint256 targetAmount = raisingInfo.targetAmounts[token];
        require(targetAmount > 0, "token error");
        uint256 raisedAmount = raisingInfo.amounts[token];
        uint256 diffAmount = targetAmount - raisedAmount;
        require(diffAmount > 0, "enough amount");
        return MathUpgradeable.min(amount, diffAmount);
    }

    /**
     * @notice Participate in fundraising
     * @param rId EventID
     * @param token token address
     * @param amount Committed amount
     */
    function raiseFundsToken(uint256 rId, address token, uint256 amount) external payable {
        require(amount > 0, "raise funds failed");
        uint256 depositAmount = _raiseAllowed(rId, token, amount);
        if(token == WETH && address(this).balance >= depositAmount) {
            IWETH(token).deposit{value: depositAmount}();
        } else {
            IERC20Upgradeable(token).safeTransferFrom(msg.sender, address(this), depositAmount);
        }
        _raiseFunds(rId, msg.sender, token, depositAmount);
    }

    /**
     * @notice Raise fund with nft
     * @param rId EventID
     * @param ptoken ptoken address
     * @param ids nft id array
     */
    function raiseFundsNFT(uint256 rId, address ptoken, uint256[] memory ids) external payable {
        address nftAddr = IPTokenFactory(ptokenFactory).getNftAddress(ptoken);
        require(nftAddr != address(0), "nft address not exist");
        uint256 idsLength = ids.length;
        require(idsLength > 0, "length error");

        uint256 pieceCount = IPToken(ptoken).pieceCount();
        uint256 depositAmount = _raiseAllowed(rId, ptoken, pieceCount * idsLength);
        uint256 length = depositAmount / pieceCount;
        length = depositAmount % pieceCount > 0 ? length + 1 : length;
        length = MathUpgradeable.min(idsLength, length);

        uint256[] memory nftIds = new uint256[](length);
        address nftTransferManager = IPTokenFactory(ptokenFactory).nftTransferManager();
        for(uint i = 0; i < length; i++) {
            TransferHelper.transferInNonFungibleToken(nftTransferManager, nftAddr, msg.sender, address(this), ids[i]);
            TransferHelper.approveNonFungibleToken(nftTransferManager, nftAddr, address(this), ptoken, ids[i]);
            
            nftIds[i] = ids[i];
            _userInfoMap[msg.sender][rId].nftIds[ptoken].add(ids[i]);
        }

        uint256 amount = IPToken(ptoken).deposit(nftIds, type(uint256).max);
        _raiseFunds(rId, msg.sender, ptoken, MathUpgradeable.min(amount, depositAmount));
        if(amount > depositAmount) {
            IERC20Upgradeable(ptoken).safeTransfer(msg.sender, amount - depositAmount);
        }
        emit RaiseFundsNFT(rId, msg.sender, nftAddr, nftIds);
    }

    /**
     * @notice Update fundraising info
     * @param rId Event Id
     * @param user User address
     * @param token Token address
     * @param amount Committed amount 
     */
    function _raiseFunds(uint256 rId, address user, address token, uint256 amount) private {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];
        uint256 totalAmount = raisingInfo.amounts[token] + amount;
        raisingInfo.amounts[token] = totalAmount;

        UserInfo storage userInfo = _userInfoMap[user][rId];
        uint256 userAmount = userInfo.depositAmount[token] + amount;
        userInfo.depositAmount[token] = userAmount;

        emit RaiseFunds(rId, user, token, userAmount, totalAmount);

        _automatedExecuteStrategy(rId);
    }

    /**
     * @notice Manually execute strategy - exclusive to owner 
     * @param rId EventId
     */
    function executeStrategy(uint256 rId) external onlyOwner {
        require(reachTargetAmount(rId), "fundraising fund failed");
        _executeStrategy(rId);
    }

    /**
     * @notice Automatic strategy execution
     * @param rId Event Id
     */
    function _automatedExecuteStrategy(uint256 rId) private {
        if(reachTargetAmount(rId)) {
            FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];
            uint256 realTimePrice = IFundingStrategy(strategy).getRealTimePrice(raisingInfo.token0, raisingInfo.token1, raisingInfo.fee, 0);
            uint256 proposedPrice = IFundingStrategy(strategy).getRealTimePrice(raisingInfo.token0, raisingInfo.token1, raisingInfo.fee, raisingInfo.sqrtPriceX96);
            uint256 delta = proposedPrice * floatingPercentage / BASE;
            uint256 proposedPriceMinimum = proposedPrice - delta;
            uint256 proposedPriceMaximum = proposedPrice + delta;
            if(proposedPriceMinimum <= realTimePrice && realTimePrice <= proposedPriceMaximum) {
                _executeStrategy(rId);
            }
        }
    }

    /**
     * @notice Execute strategy
     * @param rId Event Id
     */
    function _executeStrategy(uint256 rId) private {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];
        require(raisingInfo.fundraisingStatus == FundraisingStatus.processing, "executed strategy");
        raisingInfo.fundraisingStatus = FundraisingStatus.finished;

        _approveMax(raisingInfo.token0, strategy, raisingInfo.amounts[raisingInfo.token0]);
        _approveMax(raisingInfo.token1, strategy, raisingInfo.amounts[raisingInfo.token1]);
        IFundingStrategy(strategy).executeStrategy(rId);

        uint256 lockTime = uint256(raisingInfo.unlockTime) - raisingInfo.endTime;
        raisingInfo.unlockTime = uint32(block.timestamp + lockTime);
        
        emit RaisingSuccess(rId, IFundingStrategy(strategy).getInvestmentPrice(rId));
    }

    /**
     * @notice Get whether event reaches target amount
     * @param rId EventID
     * @return success Target reached or not
     */
    function reachTargetAmount(uint256 rId) public view returns (bool success) {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];
        address[] memory tokens = new address[](2);
        tokens[0] = raisingInfo.token0;
        tokens[1] = raisingInfo.token1;

        success = true;
        for(uint8 i = 0; i < tokens.length; i++) {
            if(raisingInfo.amounts[tokens[i]] < raisingInfo.targetAmounts[tokens[i]]) {
                success = false;
            }
        }
    }

    /**
     * @notice Cancel event - exclusive to owner
     * @param rId EventID
     */
    function setFundingRaisingCancel(uint256 rId) external onlyOwner {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];
        require(raisingInfo.fundraisingStatus == FundraisingStatus.processing, "fundraising status isn't processing");
        
        raisingInfo.endTime = uint32(block.timestamp);
        raisingInfo.fundraisingStatus = FundraisingStatus.canceled;
        emit RaisingCancel(rId);
    }

    /**
     * @notice Redeem nft
     * @param rId Event ID
     * @param token ptoken address
     * @param ids nft id array
     */
    function _redeemNft(uint256 rId, address token, uint256[] memory ids) private {
        uint256 pieceCount = IPToken(token).pieceCount();
        uint256 amount = pieceCount * ids.length;

        UserInfo storage userInfo = _userInfoMap[msg.sender][rId];
        uint256 withdrawalAmount = userInfo.withdrawAmount[token];
        if(amount > withdrawalAmount) {
            uint256 shortfall = amount - withdrawalAmount;
            IERC20Upgradeable(token).safeTransferFrom(msg.sender, address(this), shortfall);
            withdrawalAmount += shortfall;
        }
        userInfo.withdrawAmount[token] = withdrawalAmount - amount;

        for(uint i = 0; i < ids.length; i++) {
            require(userInfo.nftIds[token].contains(ids[i]), "id not exist");
            userInfo.nftIds[token].remove(ids[i]);
        }
        IPToken(token).withdraw(ids);
        address nftTransferManager = IPTokenFactory(ptokenFactory).nftTransferManager();
        address nftAddr = IPTokenFactory(ptokenFactory).getNftAddress(token);
        for(uint i = 0; i < ids.length; i++) {
            TransferHelper.transferOutNonFungibleToken(nftTransferManager, nftAddr, address(this), msg.sender, ids[i]);
        }
        emit RedeemNft(rId, msg.sender, nftAddr, ids);
    }

    /**
     * @notice Target not reached - refund
     * @param rId EventID
     */
    function refundAsset(uint256 rId) external {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];

        require(block.timestamp > raisingInfo.endTime, "not ended");

        require(
            (reachTargetAmount(rId) && raisingInfo.fundraisingStatus == FundraisingStatus.canceled) ||
            (raisingInfo.fundraisingStatus == FundraisingStatus.processing || raisingInfo.fundraisingStatus == FundraisingStatus.canceled),
            "fundraising status inconsistent"
        );
        if(raisingInfo.fundraisingStatus != FundraisingStatus.canceled) {
            raisingInfo.fundraisingStatus = FundraisingStatus.canceled;
        }

        UserInfo storage userInfo = _userInfoMap[msg.sender][rId];
        address token0 = raisingInfo.token0;
        address token1 = raisingInfo.token1;
        require(userInfo.depositAmount[token0] > 0 || userInfo.depositAmount[token1] > 0, "no deposit amount");

        uint256 amount0 = userInfo.depositAmount[token0];
        uint256 amount1 = userInfo.depositAmount[token1];
        delete userInfo.depositAmount[token0];
        delete userInfo.depositAmount[token1];
        userInfo.withdrawAmount[token0] = amount0;
        userInfo.withdrawAmount[token1] = amount1;

        emit RefundAsset(rId, msg.sender, token0, token1, amount0, amount1);
    }

    /**
     * @notice Exit strategy
     * @param rId EventId
     */
    function exitStrategy(uint256 rId) external {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];
        require(block.timestamp > raisingInfo.unlockTime, "time error");
        require(raisingInfo.fundraisingStatus == FundraisingStatus.finished, "fundraising status inconsistent");
        raisingInfo.fundraisingStatus = FundraisingStatus.received;
        IFundingStrategy(strategy).exitedStrategy(rId);
    }

    /**
     * @notice Withdraw asset
     * @param rId EventId
     */
    function withdrawAsset(uint256 rId) external {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];
        require(block.timestamp > raisingInfo.unlockTime, "time error");
        require(raisingInfo.fundraisingStatus == FundraisingStatus.finished || raisingInfo.fundraisingStatus == FundraisingStatus.received, "fundraising status inconsistent");

        if(raisingInfo.fundraisingStatus == FundraisingStatus.finished) {
            IFundingStrategy(strategy).exitedStrategy(rId);
            raisingInfo.fundraisingStatus = FundraisingStatus.received;
        }

        UserInfo storage userInfo = _userInfoMap[msg.sender][rId];
        require(userInfo.depositAmount[raisingInfo.token0] > 0 || userInfo.depositAmount[raisingInfo.token1] > 0, "no deposit amount");

        (uint256 liquidityAmount0, uint256 liquidityAmount1, uint256 swapFee0, uint256 swapFee1, uint256 bonus0, uint256 bonus1) = getWithdrawAmounts(rId, msg.sender);

        uint256 rewardAmount = getRewardTokenAmount(rId, msg.sender);

        delete userInfo.depositAmount[raisingInfo.token0];
        delete userInfo.depositAmount[raisingInfo.token1];

        uint amount0 = liquidityAmount0 + swapFee0 + bonus0;
        userInfo.withdrawAmount[raisingInfo.token0] = amount0;

        uint amount1 = liquidityAmount1 + swapFee1 + bonus1;
        userInfo.withdrawAmount[raisingInfo.token1] = amount1;

        userInfo.withdrawAmount[raisingInfo.rewardToken] = rewardAmount;
        emit WithdrawAsset(rId, msg.sender, raisingInfo.token0, raisingInfo.token1, liquidityAmount0, liquidityAmount1, swapFee0, swapFee1, bonus0, bonus1, rewardAmount);
    }

    /**
     * @notice Get user's withdrawable amount after unlock
     * @param rId EventID
     * @param user User address
     * @return liquidityAmount0 token0 unlock amount
     * @return liquidityAmount1 token1 unlock amount
     * @return swapFee0 token0 swap fee
     * @return swapFee1 tokne1 swap fee
     * @return bonus0 token0 reward
     * @return bonus1 tokne1 reward
     */
    function getWithdrawAmounts(uint256 rId, address user) public returns (uint256 liquidityAmount0, uint256 liquidityAmount1, uint256 swapFee0, uint256 swapFee1, uint256 bonus0, uint256 bonus1) {
        (liquidityAmount0, liquidityAmount1) = _capitalDistribution(rId, user);
        (swapFee0, swapFee1, bonus0, bonus1) = _feeDistribution(rId, user);
    }

    /**
     * @notice Get added liquidity token share
     * @param rId Event Id
     * @param user User address
     * @return liquidityAmount0 token0 amount
     * @return liquidityAmount1 token1 amount
     */
    function _capitalDistribution(uint256 rId, address user) private returns (uint256 liquidityAmount0, uint256 liquidityAmount1) {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];
        uint256 amount0 = raisingInfo.targetAmounts[raisingInfo.token0];
        uint256 amount1 = raisingInfo.targetAmounts[raisingInfo.token1];

        uint256 depositAmount0 = _userInfoMap[user][rId].depositAmount[raisingInfo.token0];
        uint256 depositAmount1 = _userInfoMap[user][rId].depositAmount[raisingInfo.token1];

        (uint256 returnAmount0, uint256 returnAmount1) = IFundingStrategy(strategy).getAmountsForLiquidity(rId);
        (uint256 capital0, uint256 capital1, , ) = IFundingStrategy(strategy).getLendInfos(rId);

        returnAmount0 = returnAmount0 + capital0;
        returnAmount1 = returnAmount1 + capital1;

        uint256 diffAmount;
        uint256 pct;
        if(returnAmount0 > amount0) {
            diffAmount = returnAmount0 - amount0;
            pct = depositAmount1 * BASE / amount1;
            liquidityAmount0 = depositAmount0 + (pct * diffAmount / BASE);
            liquidityAmount1 = pct * returnAmount1 / BASE;
        } else if(returnAmount1 > amount1) {
            diffAmount = returnAmount1 - amount1;
            pct = depositAmount0 * BASE / amount0;
            liquidityAmount1 = depositAmount1 + (pct * diffAmount / BASE);
            liquidityAmount0 = pct * returnAmount0 / BASE;
        } else {
            liquidityAmount0 = (depositAmount0 * BASE / amount0) * returnAmount0 / BASE;
            liquidityAmount1 = (depositAmount1 * BASE / amount1) * returnAmount1 / BASE;
        }
    }

    /**
     * @notice Get swap fee and lending revenue after strategy execution
     * @param rId Event Id
     * @param user User address
     * @return swapFee0 token0 swap fee
     * @return swapFee1 token1 swap fee
     * @return bonus0 token0 lending revenue
     * @return bonus1 token1 lending revenue
     */
    function _feeDistribution(uint256 rId, address user) private returns (uint256 swapFee0, uint256 swapFee1, uint256 bonus0, uint256 bonus1) {
        ( , , uint256 tokenBonus0, uint256 tokenBonus1) = IFundingStrategy(strategy).getLendInfos(rId);
        (uint256 token0Fee, uint256 token1Fee) = IFundingStrategy(strategy).getSwapFees(rId);

        uint256 proportion = getInvestmentProportion(rId, user);
        swapFee0 = proportion * token0Fee / BASE;
        swapFee1 = proportion * token1Fee / BASE;
        bonus0 = proportion * tokenBonus0 / BASE;
        bonus1 = proportion * tokenBonus1 / BASE;
    }

    /**
     * @notice Claim committed token
     * @param rId EventID
     */
    function claim(uint256 rId) external {
        // (address token0, address token1, uint256 amount0, uint256 amount1, uint256 withdrawAmount0, uint256 withdrawAmount1, uint256[] idsAtToken0, uint256[] idsAtToken1)
        (address token0, address token1, , , , , uint256[] memory idsAtToken0, uint256[] memory idsAtToken1) = getUserInfo(msg.sender, rId);

        if(idsAtToken0.length > 0) {
            _redeemNft(rId, token0, idsAtToken0);
        }
        if(idsAtToken1.length > 0) {
            _redeemNft(rId, token1, idsAtToken1);
        }

        address[] memory tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;
        _claim(rId, msg.sender, tokens);

        emit Claim(rId, msg.sender);
    }

    /**
     * @notice Claim reward token
     * @param rId EventId
     */
    function claimRewardToken(uint256 rId) external {
        address[] memory tokens = new address[](1);
        tokens[0] = _fundraisingInfoMap[rId].rewardToken;
        _claim(rId, msg.sender, tokens);
        emit ClaimRewardToken(rId, msg.sender);
    }

    function _claim(uint256 rId, address user, address[] memory tokens) private {
        UserInfo storage userInfo = _userInfoMap[user][rId];
        for(uint i = 0; i < tokens.length; i++) {
            uint256 amount = userInfo.withdrawAmount[tokens[i]];
            if(amount > 0) {
                delete userInfo.withdrawAmount[tokens[i]];
                _transferAsset(tokens[i], amount);
            }
        }
    }

    /**
     * @notice Send asset
     * @param token token address
     * @param amount Sent amount
     */
    function _transferAsset(address token, uint256 amount) private {
        if(token == WETH) {
            IWETH(WETH).withdraw(amount);
            refundETH();
        } else {
            IERC20Upgradeable(token).safeTransfer(msg.sender, amount);
        }
    }

    /**
     * @notice Refund ETH
     */
    function refundETH() public payable {
        uint256 bal = address(this).balance;
        if(bal > 0) {
            payable(msg.sender).transfer(bal);
        }
    }

    /**
     * @notice Get user committed proportion
     * @param rId EventID
     * @param user User address
     * @return proportion proportion percentage / BASE
     */
    function getInvestmentProportion(uint256 rId, address user) public view returns (uint256) {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];
        if(raisingInfo.fundraisingStatus == FundraisingStatus.finished || raisingInfo.fundraisingStatus == FundraisingStatus.received) {
            uint256 price = IFundingStrategy(strategy).getInvestmentPrice(rId);
        
            // (address token0, address token1, uint256 depositAmount0, uint256 depositAmount1, uint256 withdrawAmount0, uint256 withdrawAmount1, uint256[] idsAtToken0, uint256[] idsAtToken1)
            (address token0, address token1, uint256 depositAmount0, uint256 depositAmount1, , , , ) = getUserInfo(user, rId);

            uint256 amount0 = raisingInfo.targetAmounts[token0];
            uint256 amount1 = raisingInfo.targetAmounts[token1];

            uint256 totalAmount = amount0 * price / BASE + amount1;
            uint256 totalDepositAmount = depositAmount0 * price / BASE + depositAmount1;
            return totalDepositAmount * BASE / totalAmount;
        }
        return 0;
    }

    /**
     * @notice Get reward token amount based on committed tokens
     * @param rId EventID
     * @param user User address
     * @return reward reward token amount
     */
    function getRewardTokenAmount(uint256 rId, address user) public view returns (uint256) {
        FundraisingInfo storage raisingInfo = _fundraisingInfoMap[rId];

        address token0 = raisingInfo.token0;
        address token1 = raisingInfo.token1;

        uint256 depositAmount0 = _userInfoMap[user][rId].depositAmount[token0];
        uint256 depositAmount1 = _userInfoMap[user][rId].depositAmount[token1];

        uint256 targetAmount0 = raisingInfo.targetAmounts[token0];
        uint256 targetAmount1 = raisingInfo.targetAmounts[token1];

        uint256 rewardAmount0 = raisingInfo.rewardAmounts[token0] * depositAmount0 / targetAmount0;
        uint256 rewardAmount1 = raisingInfo.rewardAmounts[token1] * depositAmount1 / targetAmount1;
        return rewardAmount0 + rewardAmount1;
    }

    /**
     * @notice Approve token
     * @param token token address
     * @param spender Approved address
     * @param amount Approved amount
     */
    function _approveMax(address token, address spender, uint256 amount) private {
        uint256 allowance = IERC20Upgradeable(token).allowance(address(this), spender);
        if(allowance < amount) {
            IERC20Upgradeable(token).approve(spender, 0);
            IERC20Upgradeable(token).approve(spender, type(uint256).max);
        }
    }

    receive() external payable {}
}