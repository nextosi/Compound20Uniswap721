// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;


/* ------------------ Local TickMath for 0.8.x ------------------ */
/**
 * This is a simplified version of Uniswap's TickMath adjusted for Solidity 0.8.x:
 * - We do safe casting from int24 to uint256 where needed
 * - We re-check tick ranges with `require()`
 */
library TickMathLocal {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK =  887272; // note: was -MIN_TICK in uniswap

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        require(tick >= MIN_TICK && tick <= MAX_TICK, "Tick out of range");

        // Original Uniswap logic used an unchecked block + 0.7.x casting
        // We replicate that logic but do some safe casting for 0.8.x
        uint256 absTick = tick < 0
            ? uint256(uint24(uint24(-tick)))
            : uint256(uint24(uint24(tick)));

        // This is the Uniswap ratio initialization
        uint256 ratio = 0x100000000000000000000000000000000; // 1 << 128

        // Reproducing the multiplication pattern
        if (absTick & 0x1 != 0)
            ratio = (ratio * 0xfffcb933bd6fad37aa2d162d1a594001) >> 128;
        if (absTick & 0x2 != 0)
            ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0)
            ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0)
            ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0)
            ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0)
            ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0)
            ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0)
            ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0)
            ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0)
            ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0)
            ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0)
            ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0)
            ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0)
            ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0)
            ratio = (ratio * 0x70d869a156d2a1f6a7a2e3fadacb4c9b) >> 128;
        if (absTick & 0x8000 != 0)
            ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0)
            ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0)
            ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0)
            ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0)
            ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) {
            // invert
            ratio = type(uint256).max / ratio;
        }

        // from Q128.128 to Q128.96
        uint256 shifted = ratio >> 32;
        require(shifted <= type(uint160).max, "Price overflow");
        return uint160(shifted);
    }
}

/* ------------------------------------------------------------------
   Importing your original libraries from GitHub
------------------------------------------------------------------ */
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.8.3/contracts/token/ERC20/ERC20Upgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.8.3/contracts/security/PausableUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.8.3/contracts/security/ReentrancyGuardUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.8.3/contracts/access/OwnableUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.8.3/contracts/proxy/utils/UUPSUpgradeable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/v4.8.3/contracts/token/ERC721/IERC721ReceiverUpgradeable.sol";

// Uniswap V3 imports
import "https://github.com/Uniswap/v3-periphery/blob/v1.3.0/contracts/interfaces/INonfungiblePositionManager.sol";
import "https://github.com/Uniswap/v3-core/blob/v1.0.0/contracts/interfaces/IUniswapV3Factory.sol";
import "https://github.com/Uniswap/v3-core/blob/v1.0.0/contracts/interfaces/IUniswapV3Pool.sol";
import "https://github.com/Uniswap/v3-periphery/blob/v1.3.0/contracts/libraries/LiquidityAmounts.sol";

/* ------------------------------------------------------------------
local interfaces for OracleManager, Rebalancer, Liquidator
------------------------------------------------------------------ */
interface OracleManagerType {
    function getPrice(address) external view returns (uint256, uint8);
}
interface RebalancerType {
    function rebalance(address vault, bytes calldata data) external;
}
interface LiquidatorType {
    function liquidate(address vault, address user, uint256 seizeAmount) external;
}

/**
 * @title VaultImplementation (0.8.x Required)
 * @notice A UUPS-upgradeable vault that supports multiple NFTs from one Uniswap V3 pool,
 *         references a Rebalancer, Liquidator, OracleManager, and issues ERC20 shares 
 *         proportional to total vault value.
 */
contract VaultImplementation is
    ERC20Upgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IERC721ReceiverUpgradeable
{
    OracleManagerType public oracleManager;
    RebalancerType   public rebalancer;
    LiquidatorType   public liquidator;
    INonfungiblePositionManager public positionManager;
    IUniswapV3Factory public uniswapFactory;

    address public requiredPool;
    uint256 public maxSlippageBps;

    struct NftPosition {
        bool    exists;
        uint256 mintedShares;
        address originalDepositor;
    }
    mapping(uint256 => NftPosition) public nftPositions;
    uint256[] public allTokenIds;

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

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Use the standard `__Ownable_init()`, then `_transferOwnership(_owner)`.
     */
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
        __Ownable_init();                 // no arguments
        _transferOwnership(_owner);       // set the owner properly

        __ERC20_init(_name, _symbol);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        require(_positionManager != address(0), "Vault: invalid positionManager");
        require(_uniswapFactory  != address(0), "Vault: invalid uniswapFactory");
        require(_requiredPool    != address(0), "Vault: invalid requiredPool");
        require(_oracleMgr       != address(0), "Vault: invalid oracle");
        require(_rebalancer      != address(0), "Vault: invalid rebalancer");
        require(_liquidator      != address(0), "Vault: invalid liquidator");
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

    function pauseVault() external onlyOwner { _pause(); }
    function unpauseVault() external onlyOwner { _unpause(); }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override nonReentrant whenNotPaused returns (bytes4) {
        require(msg.sender == address(positionManager), "Vault: only from NFPM");
        require(!nftPositions[tokenId].exists, "Vault: token exists already");
        _ensureCorrectPool(tokenId);

        uint256 nftValue = _getNftValue(tokenId);

        uint256 oldSupply     = totalSupply();
        uint256 oldVaultValue = _getTotalVaultValue();
        uint256 depositValue  = nftValue;
        uint256 mintedShares;

        if (oldSupply == 0) {
            mintedShares = depositValue;
        } else {
            mintedShares = (depositValue * oldSupply) / ((oldVaultValue == 0) ? 1 : oldVaultValue);
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
        require(pos.exists, "Vault: no such tokenId");

        uint256 neededShares = pos.mintedShares;
        require(balanceOf(msg.sender) >= neededShares, "Vault: insufficient shares");
        _burn(msg.sender, neededShares);

        pos.exists = false;
        positionManager.safeTransferFrom(address(this), to, tokenId);

        uint256 nftValue = _getNftValue(tokenId);
        emit NftWithdrawn(msg.sender, tokenId, neededShares, nftValue);
    }

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

        uint256 amount0Min = (amount0Desired * (10000 - maxSlippageBps)) / 10000;
        uint256 amount1Min = (amount1Desired * (10000 - maxSlippageBps)) / 10000;

        INonfungiblePositionManager.IncreaseLiquidityParams memory params =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: block.timestamp + 1800
            });
        (uint128 addedLiquidity, , ) = positionManager.increaseLiquidity(params);
        require(addedLiquidity > 0, "No liquidity added");

        uint256 newVaultValue = _getTotalVaultValue();
        require(newVaultValue > oldVaultValue, "No net value?");

        uint256 depositValue = newVaultValue - oldVaultValue;
        uint256 mintedShares = (oldSupply == 0)
            ? depositValue
            : (depositValue * oldSupply) / ((oldVaultValue == 0) ? 1 : oldVaultValue);

        pos.mintedShares += mintedShares;
        if (mintedShares > 0) {
            _mint(msg.sender, mintedShares);
        }

        emit LiquidityAdded(msg.sender, tokenId, mintedShares, depositValue);
    }

    function removeLiquidity(uint256 tokenId, uint256 sharesToBurn)
        external
        nonReentrant
        whenNotPaused
    {
        NftPosition storage pos = nftPositions[tokenId];
        require(pos.exists, "Vault: unknown tokenId");
        require(sharesToBurn > 0, "No shares");
        require(balanceOf(msg.sender) >= sharesToBurn, "Insufficient shares");
        _ensureCorrectPool(tokenId);

        _burn(msg.sender, sharesToBurn);

        uint256 oldVaultValue = _getTotalVaultValue();
        uint256 oldSupply     = totalSupply() + sharesToBurn;

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 currentLiquidity,
            ,
            ,
            ,
            
        ) = positionManager.positions(tokenId);

        uint128 liquidityToRemove = uint128((uint256(currentLiquidity) * sharesToBurn) / oldSupply);
        if (liquidityToRemove > 0) {
            (uint256 est0, uint256 est1) = _estimateTokenAmounts(tokenId, liquidityToRemove);
            uint256 min0 = (est0 * (10000 - maxSlippageBps)) / 10000;
            uint256 min1 = (est1 * (10000 - maxSlippageBps)) / 10000;

            INonfungiblePositionManager.DecreaseLiquidityParams memory dparams =
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: liquidityToRemove,
                    amount0Min: min0,
                    amount1Min: min1,
                    deadline: block.timestamp + 1800
                });
            (uint256 removed0, uint256 removed1) = positionManager.decreaseLiquidity(dparams);

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
        uint256 removedValue = (oldVaultValue > newVaultValue) ? (oldVaultValue - newVaultValue) : 0;

        emit LiquidityRemoved(msg.sender, tokenId, sharesToBurn, removedValue);
    }

    function rebalanceVault(uint256 tokenId, bytes calldata data) external whenNotPaused {
        require(nftPositions[tokenId].exists, "Vault: no such NFT");
        rebalancer.rebalance(address(this), data);
        emit VaultRebalanced(tokenId, data);
    }

    function rebalancerMintShares(uint256 extraValue, address to) external {
        require(msg.sender == address(rebalancer), "Vault: only Rebalancer");
        require(extraValue > 0, "No extraValue");

        uint256 oldVaultValue = _getTotalVaultValue();
        uint256 oldSupply = totalSupply();

        uint256 mintedShares = (oldSupply == 0)
            ? extraValue
            : (extraValue * oldSupply) / ((oldVaultValue == 0) ? 1 : oldVaultValue);

        _mint(to, mintedShares);
        emit RebalancerSharesMinted(extraValue, to, mintedShares);
    }

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

    function getUnderlyingPrice() external view returns (uint256 price, uint8 decimals) {
        return oracleManager.getPrice(address(this));
    }

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

    function _getNftValue(uint256 tokenId) internal view returns (uint256) {
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            ,
            ,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = positionManager.positions(tokenId);

        address poolAddr = uniswapFactory.getPool(token0, token1, fee);
        require(poolAddr == requiredPool, "Vault: NFT from wrong pool");

        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(poolAddr).slot0();

        (uint256 amt0Active, uint256 amt1Active) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMathLocal.getSqrtRatioAtTick(tickLower),   // using local library
            TickMathLocal.getSqrtRatioAtTick(tickUpper),
            liquidity
        );
        // total amounts
        uint256 total0 = amt0Active + tokensOwed0;
        uint256 total1 = amt1Active + tokensOwed1;

        (uint256 p0, uint8 d0) = oracleManager.getPrice(token0);
        (uint256 p1, uint8 d1) = oracleManager.getPrice(token1);

        uint256 value0 = (total0 * p0) / (10 ** d0);
        uint256 value1 = (total1 * p1) / (10 ** d1);

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
        require(poolAddr == requiredPool, "Vault: tokenId not from requiredPool");
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
        require(poolAddr == requiredPool, "Vault: mismatch pool");
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(poolAddr).slot0();

        (amt0, amt1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMathLocal.getSqrtRatioAtTick(tickLower),   // local library
            TickMathLocal.getSqrtRatioAtTick(tickUpper),
            liqToRemove
        );
    }

    receive() external payable {}
}
