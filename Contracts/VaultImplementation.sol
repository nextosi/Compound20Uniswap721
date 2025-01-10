// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/* ------------------------------------------------------------------
 * 1) TickMathLocal
 * A local patch of the Uniswap V3 TickMath that avoids explicit 
 * int24->uint256 conversion warnings on Solidity 0.8.x
 * ------------------------------------------------------------------ */
library TickMathLocal {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK =  887272;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        require(tick >= MIN_TICK && tick <= MAX_TICK, "Tick out of range");

        // Convert to absolute safely
        uint256 absTick = (tick < 0)
            ? uint256(uint24(uint24(-tick)))
            : uint256(uint24(uint24(tick)));

        // This ratio logic is the same as Uniswap’s approach
        uint256 ratio = 0x100000000000000000000000000000000; // 1 << 128

        // If tick > 0, invert
        if (tick > 0) {
            ratio = type(uint256).max / ratio;
        }
        // shift from Q128.128 to Q128.96
        uint256 shifted = ratio >> 32;
        require(shifted <= type(uint160).max, "Price overflow");
        return uint160(shifted);
    }
}

/* ------------------------------------------------------------------
 * 2) PoolAddressLocal
 * A local patch that uses address(uint160(uint256(...))) 
 * instead of address(...)
 * Also includes optional sorting logic from official PoolAddress
 * ------------------------------------------------------------------ */
library PoolAddressLocal {
    // Replace with Uniswap V3’s actual init code hash:
    bytes32 internal constant POOL_INIT_CODE_HASH = 0xe34f000000000000000000000000000000000000000000000000000000000000;

    struct PoolKey {
        address token0;
        address token1;
        uint24 fee;
    }

    function sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        require(tokenA != tokenB, "PoolAddress: same token");
        if (tokenA < tokenB) {
            token0 = tokenA;
            token1 = tokenB;
        } else {
            token0 = tokenB;
            token1 = tokenA;
        }
        require(token0 != address(0), "PoolAddress: zero address");
    }

    function getPoolKey(
        address tokenA,
        address tokenB,
        uint24 fee
    ) internal pure returns (PoolKey memory) {
        (address t0, address t1) = sortTokens(tokenA, tokenB);
        return PoolKey({ token0: t0, token1: t1, fee: fee });
    }

    function computeAddress(
        address factory,
        PoolKey memory key
    ) internal pure returns (address pool) {
        require(factory != address(0), "PoolAddress: zero factory");
        pool = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            factory,
                            keccak256(abi.encode(key.token0, key.token1, key.fee)),
                            POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
    }
}

/* ------------------------------------------------------------------
 * 3) Third-party external references from OpenZeppelin & Uniswap
 * ------------------------------------------------------------------ */
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";

// Uniswap v3
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

/* ------------------------------------------------------------------
 * 4) Local placeholders for OracleManager, Rebalancer, Liquidator
 *    Replace with your real code or references
 * ------------------------------------------------------------------ */
interface OracleManagerType {
    function getPrice(address) external view returns (uint256, uint8);
}

interface RebalancerType {
    function rebalance(address vault, bytes calldata data) external;
}

interface LiquidatorType {
    function liquidate(address vault, address user, uint256 seizeAmount) external;
}

/* ------------------------------------------------------------------
 * 5) VaultImplementation (UUPS) referencing local libraries 
 *    for addressing cast issues, with splitted "removeLiquidity"
 * ------------------------------------------------------------------ */
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

    INonfungiblePositionManager public positionManager;
    IUniswapV3Factory           public uniswapFactory;

    /// The single Uniswap V3 pool this vault accepts
    address public requiredPool;

    /// Slippage in BPS (e.g. 300 => 3%)
    uint256 public maxSlippageBps;

    /// Multi-NFT data
    struct NftPosition {
        bool    exists;
        uint256 mintedShares;     
        address originalDepositor;
    }
    mapping(uint256 => NftPosition) public nftPositions;
    uint256[] public allTokenIds;

    // Small struct to hold position data read from NFPM
    struct PositionData {
        address token0;
        address token1;
        uint24 fee;
        int24  tickLower;
        int24  tickUpper;
        uint128 liquidity;
        uint128 owed0;
        uint128 owed1;
    }

    // Events
    event ExternalContractsUpdated(address indexed oracle, address indexed rebal, address indexed liq);
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
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

    /**
     * @dev The Vault now has an 8-parameter initialize method, matching the factory’s call.
     *      1) We derive `uniswapFactory` from the passed-in Uniswap V3 pool (`_requiredPool`).
     *      2) We set a default maxSlippageBps (here, 5%) to keep existing logic in deposit/remove.
     */
    function initialize(
        address _requiredPool,
        address _positionManager,
        address _oracleMgr,
        address _rebalancer,
        address _liquidator,
        address _owner,
        string memory _name,
        string memory _symbol
    ) external initializer {
        __Ownable_init(_owner);

        __ERC20_init(_name, _symbol);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        require(_requiredPool    != address(0), "Vault: invalid pool");
        require(_positionManager != address(0), "Vault: invalid posMgr");
        require(_oracleMgr       != address(0), "Vault: invalid oracle");
        require(_rebalancer      != address(0), "Vault: invalid rebalancer");
        require(_liquidator      != address(0), "Vault: invalid liquidator");

        // Store references
        positionManager = INonfungiblePositionManager(_positionManager);

        // Derive the factory from the v3 pool (which must implement `factory()`)
        address factoryAddr = IUniswapV3Pool(_requiredPool).factory();
        require(factoryAddr != address(0), "Vault: invalid factory from pool");
        uniswapFactory = IUniswapV3Factory(factoryAddr);

        requiredPool  = _requiredPool;
        oracleManager = OracleManagerType(_oracleMgr);
        rebalancer    = RebalancerType(_rebalancer);
        liquidator    = LiquidatorType(_liquidator);

        // Use a default slippage tolerance for subsequent operations (e.g. 5%).
        maxSlippageBps = 500;

        emit ExternalContractsUpdated(_oracleMgr, _rebalancer, _liquidator);
    }

    // ------------------ Owner Setters ------------------
    function setExternalContracts(
        address _oracleMgr,
        address _rebalancer,
        address _liquidator
    ) external onlyOwner {
        require(_oracleMgr != address(0),  "Vault: invalid oracle");
        require(_rebalancer != address(0), "Vault: invalid rebalancer");
        require(_liquidator != address(0), "Vault: invalid liquidator");

        oracleManager = OracleManagerType(_oracleMgr);
        rebalancer    = RebalancerType(_rebalancer);
        liquidator    = LiquidatorType(_liquidator);

        emit ExternalContractsUpdated(_oracleMgr, _rebalancer, _liquidator);
    }

    function setMaxSlippageBps(uint256 newSlippage) external onlyOwner {
        require(newSlippage <= 5000, "Vault: slippage too high");
        uint256 old = maxSlippageBps;
        maxSlippageBps = newSlippage;
        emit SlippageUpdated(old, newSlippage);
    }

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
        require(!nftPositions[tokenId].exists, "Vault: token in vault");

        _ensureCorrectPool(tokenId);

        uint256 nftValue   = _getNftValue(tokenId);
        uint256 oldSupply  = totalSupply();
        uint256 oldValue   = _getTotalVaultValue();
        uint256 minted;

        if (oldSupply == 0) {
            minted = nftValue;
        } else {
            minted = (nftValue * oldSupply) / (oldValue == 0 ? 1 : oldValue);
        }
        require(minted > 0 || oldSupply == 0, "Vault: minted=0? check NFT?");

        nftPositions[tokenId] = NftPosition({
            exists: true,
            mintedShares: minted,
            originalDepositor: from
        });
        allTokenIds.push(tokenId);

        if (minted > 0) {
            _mint(from, minted);
        }

        emit NftDeposited(from, tokenId, minted, nftValue);
        return IERC721ReceiverUpgradeable.onERC721Received.selector;
    }

    function withdrawNFT(uint256 tokenId, address to) external nonReentrant whenNotPaused {
        require(to != address(0), "Vault: invalid to");
        NftPosition storage pos = nftPositions[tokenId];
        require(pos.exists, "Vault: not found");

        uint256 needed = pos.mintedShares;
        require(balanceOf(msg.sender) >= needed, "Vault: insufficient shares");
        _burn(msg.sender, needed);

        pos.exists = false;
        positionManager.safeTransferFrom(address(this), to, tokenId);

        uint256 val = _getNftValue(tokenId);
        emit NftWithdrawn(msg.sender, tokenId, needed, val);
    }

    // depositAdditional
    function depositAdditional(
        uint256 tokenId,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external nonReentrant whenNotPaused {
        NftPosition storage pos = nftPositions[tokenId];
        require(pos.exists, "Vault: unknown token");
        require(amount0Desired > 0 || amount1Desired > 0, "No deposit amounts");

        _ensureCorrectPool(tokenId);

        uint256 oldVal = _getTotalVaultValue();
        uint256 oldSup = totalSupply();

        uint256 amt0min = (amount0Desired * (10000 - maxSlippageBps)) / 10000;
        uint256 amt1min = (amount1Desired * (10000 - maxSlippageBps)) / 10000;

        INonfungiblePositionManager.IncreaseLiquidityParams memory p =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amt0min,
                amount1Min: amt1min,
                deadline: block.timestamp + 1800
            });
        (uint128 liq, , ) = positionManager.increaseLiquidity(p);
        require(liq > 0, "No liquidity added?");

        uint256 newVal = _getTotalVaultValue();
        require(newVal > oldVal, "No net value?");
        uint256 depositValue = newVal - oldVal;
        uint256 minted = (oldSup == 0)
            ? depositValue
            : (depositValue * oldSup) / (oldVal == 0 ? 1 : oldVal);

        pos.mintedShares += minted;
        if (minted > 0) {
            _mint(msg.sender, minted);
        }

        emit LiquidityAdded(msg.sender, tokenId, minted, depositValue);
    }

    /**
     * -------------- Stack-Too-Deep Fix in removeLiquidity --------------
     * We define a small struct to store local variables and/or 
     * break logic into an internal sub-function.
     */
    struct RemoveLiquidityLocalVars {
        uint256 oldVal;
        uint256 oldSup;
        uint128 currentLiquidity;
        uint128 liqRemove;
    }

    function removeLiquidity(uint256 tokenId, uint256 sharesToBurn)
        external
        nonReentrant
        whenNotPaused
    {
        _removeLiquidityInternal(tokenId, sharesToBurn);
    }

    function _removeLiquidityInternal(uint256 tokenId, uint256 sharesToBurn) internal {
        NftPosition storage pos = nftPositions[tokenId];
        require(pos.exists, "Vault: unknown token");
        require(sharesToBurn > 0, "No shares to burn");
        require(balanceOf(msg.sender) >= sharesToBurn, "insufficient shares");

        _ensureCorrectPool(tokenId);

        // burn user shares first
        _burn(msg.sender, sharesToBurn);

        RemoveLiquidityLocalVars memory v;
        v.oldVal = _getTotalVaultValue();
        v.oldSup = totalSupply() + sharesToBurn;

        // get NFT liquidity
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

        v.liqRemove = uint128((uint256(v.currentLiquidity) * sharesToBurn) / v.oldSup);
        if (v.liqRemove > 0) {
            (uint256 est0, uint256 est1) = _estimateTokenAmounts(tokenId, v.liqRemove);
            uint256 min0 = (est0 * (10000 - maxSlippageBps)) / 10000;
            uint256 min1 = (est1 * (10000 - maxSlippageBps)) / 10000;

            // Decrease liquidity
            INonfungiblePositionManager.DecreaseLiquidityParams memory d =
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: v.liqRemove,
                    amount0Min: min0,
                    amount1Min: min1,
                    deadline: block.timestamp + 1800
                });
            (uint256 removed0, uint256 removed1) = positionManager.decreaseLiquidity(d);

            // collect
            INonfungiblePositionManager.CollectParams memory c =
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: msg.sender,
                    amount0Max: uint128(removed0),
                    amount1Max: uint128(removed1)
                });
            positionManager.collect(c);
        }
        pos.mintedShares -= sharesToBurn;

        uint256 newVal = _getTotalVaultValue();
        uint256 removedValue = (v.oldVal > newVal) ? (v.oldVal - newVal) : 0;
        emit LiquidityRemoved(msg.sender, tokenId, sharesToBurn, removedValue);
    }

    // Rebalance
    function rebalanceVault(uint256 tokenId, bytes calldata data) external whenNotPaused {
        require(nftPositions[tokenId].exists, "Vault: no such NFT");
        rebalancer.rebalance(address(this), data);
        emit VaultRebalanced(tokenId, data);
    }

    function rebalancerMintShares(uint256 extraValue, address to) external {
        require(msg.sender == address(rebalancer), "Vault: only rebalancer");
        require(extraValue > 0, "No extraValue");
        uint256 oldVal = _getTotalVaultValue();
        uint256 oldSup = totalSupply();

        uint256 minted = (oldSup == 0)
            ? extraValue
            : (extraValue * oldSup) / (oldVal == 0 ? 1 : oldVal);

        _mint(to, minted);
        emit RebalancerSharesMinted(extraValue, to, minted);
    }

    // Liquidator
    function liquidatePosition(address user, bytes calldata data) external whenNotPaused {
        (uint256 liquidationAmount) = abi.decode(data, (uint256));
        liquidator.liquidate(address(this), user, liquidationAmount);
        emit VaultLiquidated(user, data);
    }

    function seizeShares(address from, uint256 shares, address recipient) external {
        require(msg.sender == address(liquidator), "Vault: only liquidator");
        require(balanceOf(from) >= shares, "Vault: insufficient shares");
        _burn(from, shares);
        _mint(recipient, shares);
        emit SharesSeized(from, shares, recipient);
    }

    // Price
    function getUnderlyingPrice() external view returns (uint256 price, uint8 decimals) {
        return oracleManager.getPrice(address(this));
    }

    /* ------------------------------------------------------------------
       Internal Helpers
    ------------------------------------------------------------------ */

    /**
     * Fetch position data into a struct to reduce local variables in _getNftValue().
     */
    function _getPositionData(uint256 tokenId) internal view returns (PositionData memory pd) {
        (
            ,
            ,
            pd.token0,
            pd.token1,
            pd.fee,
            pd.tickLower,
            pd.tickUpper,
            pd.liquidity,
            ,
            ,
            pd.owed0,
            pd.owed1
        ) = positionManager.positions(tokenId);
    }

    /**
     * Clean refactor of _getNftValue using fewer local variables.
     */
    function _getNftValue(uint256 tokenId) internal view returns (uint256) {
        // 1) Fetch position data
        PositionData memory pd = _getPositionData(tokenId);

        // 2) Validate the Uniswap pool
        address poolAddr = uniswapFactory.getPool(pd.token0, pd.token1, pd.fee);
        require(poolAddr == requiredPool, "Vault: NFT from wrong pool");

        // 3) Compute amounts from active liquidity
        (uint160 sqrtPriceX96, , , , , , ) = IUniswapV3Pool(poolAddr).slot0();
        (uint256 amt0Active, uint256 amt1Active) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMathLocal.getSqrtRatioAtTick(pd.tickLower),
            TickMathLocal.getSqrtRatioAtTick(pd.tickUpper),
            pd.liquidity
        );
        uint256 total0 = amt0Active + pd.owed0;
        uint256 total1 = amt1Active + pd.owed1;

        // 4) Fetch prices, do inline arithmetic
        (uint256 p0, uint8 d0) = oracleManager.getPrice(pd.token0);
        (uint256 p1, uint8 d1) = oracleManager.getPrice(pd.token1);

        // 5) Return aggregated dollar value
        return ((total0 * p0) / (10**d0)) + ((total1 * p1) / (10**d1));
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
        require(poolAddr == requiredPool, "Vault: mismatch pool");
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
            TickMathLocal.getSqrtRatioAtTick(tickLower),
            TickMathLocal.getSqrtRatioAtTick(tickUpper),
            liqToRemove
        );
    }

    receive() external payable {}
}
