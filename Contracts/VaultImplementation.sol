// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

/* ------------------------------------------------------------------
 * Minimal local expansions for Uniswap v3 TickMath and LiquidityAmounts
 * that compile under 0.8.x without explicit cast errors.
 * Fully implemented, no placeholders.
 * ------------------------------------------------------------------ */

library TickMathLocal {
    /// @dev The minimum tick supported by Uniswap v3
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick supported by Uniswap v3
    int24 internal constant MAX_TICK = -MIN_TICK;

    /**
     * @notice Calculates sqrt(1.0001^tick) * 2^96
     * @dev This is the same logic as Uniswap v3-core’s TickMath,
     *      adapted to 0.8.9 to avoid explicit negative cast errors.
     * @param tick The tick for which to compute the sqrt ratio
     * @return sqrtPriceX96 A FixedPoint Q96.96 number representing
     *         sqrt(1.0001^tick) * 2^96
     */
    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        // Revert if out of range:
        require(tick >= MIN_TICK && tick <= MAX_TICK, "Tick out of range");

        // The Uniswap v3-core code uses an approach with precomputed
        // constants and repeated multiplication. We replicate it fully.
        // See https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/TickMath.sol

        // For brevity, here’s the entire logic:
        uint256 absTick = (tick < 0) ? uint256(uint24(-tick)) : uint256(uint24(tick));

        // Uniswap’s magic constants:
        // We do all multiplications at 256-bit then shift down for Q96
        uint256 ratio = 0x100000000000000000000000000000000; // 1 << 128

        // Each of these “if” blocks check a bit in absTick and multiply ratio
        // by the corresponding constant if set. This results in ratio = 1.0001^absTick << 128
        if (absTick & 0x1 != 0) ratio = (ratio * 0xfffcb933bd6fad37aa2d162d1a594001) >> 128;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1f6a7a2e3fadacb4c9b) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        // Shift from Q128.128 to Q128.96 by >> 32
        // then cast to uint160
        uint256 shifted = (ratio >> 32);
        require(shifted <= type(uint160).max, "Price overflow");

        sqrtPriceX96 = uint160(shifted);
    }
}

library LiquidityAmounts {
    /**
     * @notice Computes the amount0 & amount1 for a given liquidity, current price, and the lower & upper sqrt prices
     */
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        // Make sure sqrtLower <= sqrtUpper
        if (sqrtLower > sqrtUpper) {
            (sqrtLower, sqrtUpper) = (sqrtUpper, sqrtLower);
        }

        if (sqrtPriceX96 <= sqrtLower) {
            // current price below range => all liquidity in token0
            uint256 intermediate = uint256(liquidity) << 96;
            amount0 = (intermediate * (sqrtUpper - sqrtLower)) / sqrtUpper / sqrtLower;
            amount1 = 0;
        } else if (sqrtPriceX96 >= sqrtUpper) {
            // current price above range => all liquidity in token1
            amount0 = 0;
            amount1 = _computeLiquidityToken1(sqrtUpper, sqrtLower, liquidity);
        } else {
            // in range => partial
            amount0 = (uint256(liquidity) << 96) * (sqrtUpper - sqrtPriceX96) / sqrtUpper / sqrtPriceX96;
            amount1 = _computeLiquidityToken1(sqrtPriceX96, sqrtLower, liquidity);
        }
    }

    function _computeLiquidityToken1(uint160 sqrtRatioA, uint160 sqrtRatioB, uint128 liquidity)
        private
        pure
        returns (uint256)
    {
        return uint256(liquidity) * (sqrtRatioA - sqrtRatioB) / 0x1000000000000000000000000;
        // => (liquidity * (ratioA - ratioB)) / 2^96
    }
}

/* ------------------------------------------------------------------
 * Minimal interfaces for Uniswap v3 factory/pool/NFPM + Oracle, etc.
 * ------------------------------------------------------------------*/

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

interface IUniswapV3Pool {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24  tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8  feeProtocol,
            bool   unlocked
        );
}

interface INonfungiblePositionManager {
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24  tickLower,
            int24  tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external returns (uint256 amount0, uint256 amount1);

    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/* ------------------------------------------------------------------
 * Local placeholders or real references for Oracle, Rebalancer, Liquidator
 * ------------------------------------------------------------------*/
interface OracleManagerType {
    function getPrice(address) external view returns (uint256 price, uint8 decimals);
}
interface RebalancerType {
    function rebalance(address vault, bytes calldata data) external;
}
interface LiquidatorType {
    function liquidate(address vault, address user, uint256 seizeAmount) external;
}

/* ------------------------------------------------------------------
 * Import OpenZeppelin upgradeable base classes
 * ------------------------------------------------------------------*/
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.8.3/contracts/token/ERC20/ERC20Upgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.8.3/contracts/security/PausableUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.8.3/contracts/security/ReentrancyGuardUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.8.3/contracts/access/OwnableUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.8.3/contracts/proxy/utils/UUPSUpgradeable.sol";

import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.8.3/contracts/token/ERC721/IERC721ReceiverUpgradeable.sol";

/**
 * @title VaultImplementation
 * @notice A UUPS-upgradeable vault that accepts multiple Uniswap V3 NFTs from a single pool,
 *         mints proportional ERC20 shares, references a Rebalancer, Liquidator, OracleManager,
 *         and allows partial liquidity ops, rebalancing, and forced share seizures.
 */
contract VaultImplementation is
    ERC20Upgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IERC721ReceiverUpgradeable
{
    // External references
    OracleManagerType public oracleManager;
    RebalancerType   public rebalancer;
    LiquidatorType   public liquidator;
    IUniswapV3Factory public uniswapFactory;
    INonfungiblePositionManager public positionManager;

    // The single pool for all NFTs
    address public requiredPool;

    // Slippage in bps
    uint256 public maxSlippageBps;

    struct NftPosition {
        bool    exists;
        uint256 mintedShares;
        address originalDepositor;
    }
    mapping(uint256 => NftPosition) public nftPositions;
    uint256[] public allTokenIds;

    // ------------------ Events ------------------
    event ExternalContractsUpdated(address indexed oracle, address indexed rebalancer, address indexed liquidator);
    event SlippageUpdated(uint256 oldSlippageBps, uint256 newSlippageBps);

    event NftDeposited(address indexed user, uint256 tokenId, uint256 mintedShares, uint256 nftValue);
    event NftWithdrawn(address indexed user, uint256 tokenId, uint256 burnedShares, uint256 nftValue);

    event LiquidityAdded(address indexed user, uint256 tokenId, uint256 mintedShares, uint256 addedValue);
    event LiquidityRemoved(address indexed user, uint256 tokenId, uint256 burnedShares, uint256 removedValue);

    event VaultRebalanced(uint256 tokenId, bytes data);
    event VaultLiquidated(address user, bytes data);
    event SharesSeized(address user, uint256 shares, address recipient);
    event RebalancerSharesMinted(uint256 extraValue, address to, uint256 mintedShares);

    // UUPS
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // Initialization
    function initialize(
        address _positionManager,
        address _uniswapFactory,
        address _requiredPool,
        address _oracleMgr,
        address _rebalancer,
        address _liquidator,
        address _owner,
        string memory _name,
        string memory _symbol,
        uint256 _maxSlippageBps
    ) external initializer {
        __Ownable_init();
        _transferOwnership(_owner);

        __ERC20_init(_name, _symbol);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        require(_positionManager != address(0), "Vault: invalid posMgr");
        require(_uniswapFactory != address(0),  "Vault: invalid factory");
        require(_requiredPool   != address(0),  "Vault: invalid pool");
        require(_oracleMgr      != address(0),  "Vault: invalid oracle");
        require(_rebalancer     != address(0),  "Vault: invalid rebalancer");
        require(_liquidator     != address(0),  "Vault: invalid liquidator");
        require(_maxSlippageBps <= 5000,        "Vault: slippage too high");

        positionManager = INonfungiblePositionManager(_positionManager);
        uniswapFactory  = IUniswapV3Factory(_uniswapFactory);
        requiredPool    = _requiredPool;
        oracleManager   = OracleManagerType(_oracleMgr);
        rebalancer      = RebalancerType(_rebalancer);
        liquidator      = LiquidatorType(_liquidator);
        maxSlippageBps  = _maxSlippageBps;

        emit ExternalContractsUpdated(_oracleMgr, _rebalancer, _liquidator);
    }

    // Setters
    function setExternalContracts(
        address _oracleMgr,
        address _rebalancer,
        address _liquidator
    ) external onlyOwner {
        require(_oracleMgr     != address(0), "Vault: invalid oracle");
        require(_rebalancer    != address(0), "Vault: invalid rebalancer");
        require(_liquidator    != address(0), "Vault: invalid liquidator");

        oracleManager = OracleManagerType(_oracleMgr);
        rebalancer    = RebalancerType(_rebalancer);
        liquidator    = LiquidatorType(_liquidator);

        emit ExternalContractsUpdated(_oracleMgr, _rebalancer, _liquidator);
    }

    function setMaxSlippageBps(uint256 newSlippageBps) external onlyOwner {
        require(newSlippageBps <= 5000, "Vault: slippage too high");
        uint256 old = maxSlippageBps;
        maxSlippageBps = newSlippageBps;
        emit SlippageUpdated(old, newSlippageBps);
    }

    // Pausing
    function pauseVault() external onlyOwner {
        _pause();
    }
    function unpauseVault() external onlyOwner {
        _unpause();
    }

    // ------------------ NFT Handling ------------------
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override nonReentrant whenNotPaused returns (bytes4) {
        require(msg.sender == address(positionManager), "Vault: only NFPM");
        require(!nftPositions[tokenId].exists, "Vault: tokenId already in vault");

        _ensureCorrectPool(tokenId);

        uint256 nftValue      = _getNftValue(tokenId);
        uint256 oldSupply     = totalSupply();
        uint256 oldVaultValue = _getTotalVaultValue();
        uint256 depositValue  = nftValue;
        uint256 mintedShares;

        if (oldSupply == 0) {
            mintedShares = depositValue;
        } else {
            mintedShares = (depositValue * oldSupply) / (oldVaultValue == 0 ? 1 : oldVaultValue);
        }
        require(mintedShares > 0 || oldSupply == 0, "Vault: NFT => 0 shares?");

        nftPositions[tokenId] = NftPosition({
            exists: true,
            mintedShares: mintedShares,
            originalDepositor: from
        });
        allTokenIds.push(tokenId);

        if (mintedShares > 0) {
            _mint(from, mintedShares);
        }

        emit NftDeposited(from, tokenId, mintedShares, nftValue);
        return IERC721ReceiverUpgradeable.onERC721Received.selector;
    }

    function withdrawNFT(uint256 tokenId, address to) external nonReentrant whenNotPaused {
        require(to != address(0), "Vault: invalid to");
        NftPosition storage pos = nftPositions[tokenId];
        require(pos.exists, "Vault: unknown tokenId");

        uint256 neededShares = pos.mintedShares;
        require(balanceOf(msg.sender) >= neededShares, "Vault: insufficient shares");
        _burn(msg.sender, neededShares);

        pos.exists = false;
        positionManager.safeTransferFrom(address(this), to, tokenId);

        uint256 nftValue = _getNftValue(tokenId);
        emit NftWithdrawn(msg.sender, tokenId, neededShares, nftValue);
    }

    // Additional Liquidity
    function depositAdditional(
        uint256 tokenId,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external nonReentrant whenNotPaused {
        NftPosition storage pos = nftPositions[tokenId];
        require(pos.exists, "Vault: unknown tokenId");
        require(amount0Desired > 0 || amount1Desired > 0, "No deposit amounts");

        _ensureCorrectPool(tokenId);

        uint256 oldVaultValue = _getTotalVaultValue();
        uint256 oldSupply     = totalSupply();

        uint256 amt0min = (amount0Desired * (10000 - maxSlippageBps)) / 10000;
        uint256 amt1min = (amount1Desired * (10000 - maxSlippageBps)) / 10000;

        INonfungiblePositionManager.IncreaseLiquidityParams memory params =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amt0min,
                amount1Min: amt1min,
                deadline: block.timestamp + 1800
            });
        (uint128 addedLiquidity, , ) = positionManager.increaseLiquidity(params);
        require(addedLiquidity > 0, "No liquidity added");

        uint256 newVaultValue = _getTotalVaultValue();
        require(newVaultValue > oldVaultValue, "No net value?");

        uint256 depositValue = newVaultValue - oldVaultValue;
        uint256 mintedShares = (oldSupply == 0)
            ? depositValue
            : (depositValue * oldSupply) / (oldVaultValue == 0 ? 1 : oldVaultValue);

        pos.mintedShares += mintedShares;
        if (mintedShares > 0) {
            _mint(msg.sender, mintedShares);
        }

        emit LiquidityAdded(msg.sender, tokenId, mintedShares, depositValue);
    }

    // Partial Remove
    struct RemoveLiquidityVars {
        uint256 oldVaultValue;
        uint256 oldSupply;
        uint128 currentLiquidity;
        uint128 liquidityToRemove;
        uint256 est0;
        uint256 est1;
        uint256 min0;
        uint256 min1;
        uint256 removedValue;
    }

    function removeLiquidity(uint256 tokenId, uint256 sharesToBurn)
        external
        nonReentrant
        whenNotPaused
    {
        NftPosition storage pos = nftPositions[tokenId];
        require(pos.exists, "Vault: unknown tokenId");
        require(sharesToBurn > 0, "no shares");
        require(balanceOf(msg.sender) >= sharesToBurn, "insufficient shares");

        _ensureCorrectPool(tokenId);

        _burn(msg.sender, sharesToBurn);

        RemoveLiquidityVars memory v;
        v.oldVaultValue = _getTotalVaultValue();
        v.oldSupply     = totalSupply() + sharesToBurn;

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            v.currentLiquidity,
            ,
            ,
            ,

        ) = positionManager.positions(tokenId);

        v.liquidityToRemove = uint128(
            (uint256(v.currentLiquidity) * sharesToBurn) / v.oldSupply
        );

        if (v.liquidityToRemove > 0) {
            (v.est0, v.est1) = _estimateTokenAmounts(tokenId, v.liquidityToRemove);

            v.min0 = (v.est0 * (10000 - maxSlippageBps)) / 10000;
            v.min1 = (v.est1 * (10000 - maxSlippageBps)) / 10000;

            INonfungiblePositionManager.DecreaseLiquidityParams memory dparams =
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: v.liquidityToRemove,
                    amount0Min: v.min0,
                    amount1Min: v.min1,
                    deadline: block.timestamp + 1800
                });
            (uint256 removed0, uint256 removed1) = positionManager.decreaseLiquidity(dparams);

            // collect to user
            INonfungiblePositionManager.CollectParams memory cparams =
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: msg.sender,
                    amount0Max: uint128(removed0),
                    amount1Max: uint128(removed1)
                });
            positionManager.collect(cparams);
        }

        pos.mintedShares -= sharesToBurn;

        uint256 newVaultValue = _getTotalVaultValue();
        v.removedValue = (v.oldVaultValue > newVaultValue)
            ? (v.oldVaultValue - newVaultValue)
            : 0;

        emit LiquidityRemoved(msg.sender, tokenId, sharesToBurn, v.removedValue);
    }

    // Rebalancer
    function rebalanceVault(uint256 tokenId, bytes calldata data) external whenNotPaused {
        require(nftPositions[tokenId].exists, "Vault: no such NFT");
        rebalancer.rebalance(address(this), data);
        emit VaultRebalanced(tokenId, data);
    }

    function rebalancerMintShares(uint256 extraValue, address to) external {
        require(msg.sender == address(rebalancer), "Vault: only rebalancer");
        require(extraValue > 0, "No extraValue");
        uint256 oldVaultValue = _getTotalVaultValue();
        uint256 oldSupply     = totalSupply();

        uint256 mintedShares = (oldSupply == 0)
            ? extraValue
            : (extraValue * oldSupply) / (oldVaultValue == 0 ? 1 : oldVaultValue);

        _mint(to, mintedShares);
        emit RebalancerSharesMinted(extraValue, to, mintedShares);
    }

    // Liquidator
    function liquidatePosition(address user, bytes calldata data) external whenNotPaused {
        (uint256 liquidationAmount) = abi.decode(data, (uint256));
        liquidator.liquidate(address(this), user, liquidationAmount);
        emit VaultLiquidated(user, data);
    }

    function seizeShares(address from, uint256 shares, address recipient) external {
        require(msg.sender == address(liquidator), "Vault: only Liquidator");
        require(balanceOf(from) >= shares, "Vault: insufficient shares");
        _burn(from, shares);
        _mint(recipient, shares);
        emit SharesSeized(from, shares, recipient);
    }

    // Oracle-based Price
    function getUnderlyingPrice() external view returns (uint256 price, uint8 decimals) {
        return oracleManager.getPrice(address(this));
    }

    // Internal Value
    function _getTotalVaultValue() internal view returns (uint256) {
        uint256 sum;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            uint256 tid = allTokenIds[i];
            if (nftPositions[tid].exists) {
                sum += _getNftValue(tid);
            }
        }
        return sum;
    }

    struct NftValueVars {
        address token0;
        address token1;
        uint24 fee;
        int24  tickLower;
        int24  tickUpper;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
        address poolAddr;
        uint160 sqrtPriceX96;
        bool unlocked;
        uint256 amt0Active;
        uint256 amt1Active;
        uint256 total0;
        uint256 total1;
        uint256 p0;
        uint256 p1;
        uint8   d0;
        uint8   d1;
    }

    function _getNftValue(uint256 tokenId) internal view returns (uint256) {
        NftValueVars memory v;

        (
            ,
            ,
            v.token0,
            v.token1,
            v.fee,
            v.tickLower,
            v.tickUpper,
            v.liquidity,
            ,
            ,
            v.owed0,
            v.owed1
        ) = positionManager.positions(tokenId);

        v.poolAddr = uniswapFactory.getPool(v.token0, v.token1, v.fee);
        require(v.poolAddr == requiredPool, "Vault: not requiredPool");

        (v.sqrtPriceX96, , , , , , v.unlocked) = IUniswapV3Pool(v.poolAddr).slot0();
        require(v.unlocked, "Vault: pool locked?");

        // amounts from active liquidity
        (v.amt0Active, v.amt1Active) = LiquidityAmounts.getAmountsForLiquidity(
            v.sqrtPriceX96,
            TickMathLocal.getSqrtRatioAtTick(v.tickLower),
            TickMathLocal.getSqrtRatioAtTick(v.tickUpper),
            v.liquidity
        );

        v.total0 = v.amt0Active + v.owed0;
        v.total1 = v.amt1Active + v.owed1;

        (v.p0, v.d0) = oracleManager.getPrice(v.token0);
        (v.p1, v.d1) = oracleManager.getPrice(v.token1);

        uint256 value0 = (v.total0 * v.p0) / (10 ** v.d0);
        uint256 value1 = (v.total1 * v.p1) / (10 ** v.d1);

        return value0 + value1;
    }

    function _ensureCorrectPool(uint256 tokenId) internal view {
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            ,
            ,
            ,
            ,
            ,
            ,
        ) = positionManager.positions(tokenId);

        address poolAddr = uniswapFactory.getPool(token0, token1, fee);
        require(poolAddr == requiredPool, "Vault: wrong pool");
    }

    struct EstimateLocalVars {
        uint160 sqrtPriceX96;
    }
    function _estimateTokenAmounts(uint256 tokenId, uint128 liqToRemove)
        internal
        view
        returns (uint256 amt0, uint256 amt1)
    {
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            ,
            ,
            ,
            ,

        ) = positionManager.positions(tokenId);

        address poolAddr = uniswapFactory.getPool(token0, token1, fee);
        require(poolAddr == requiredPool, "Vault: not requiredPool");

        EstimateLocalVars memory v;
        (v.sqrtPriceX96, , , , , , ) = IUniswapV3Pool(poolAddr).slot0();

        (amt0, amt1) = LiquidityAmounts.getAmountsForLiquidity(
            v.sqrtPriceX96,
            TickMathLocal.getSqrtRatioAtTick(tickLower),
            TickMathLocal.getSqrtRatioAtTick(tickUpper),
            liqToRemove
        );
    }

    receive() external payable {}
}
