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
    bytes32 internal constant POOL_INIT_CODE_HASH =
        0xe34f000000000000000000000000000000000000000000000000000000000000;

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
    // Must be configured with isVaultToken=true for this vault,
    // so getPrice(vaultAddr) => returns "USD per 1 share"
    function getPrice(address token) external view returns (uint256, uint8);
}

interface RebalancerType {
    function rebalance(address vault, bytes calldata data) external;
}

interface LiquidatorType {
    function liquidate(address vault, address user, uint256 seizeAmount) external;
}

/* ------------------------------------------------------------------
 * 5) VaultImplementation (UUPS) referencing local libraries 
 *    with splitted "removeLiquidity" and advanced multi-NFT logic
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

    /// The single Uniswap V3 pool this vault accepts (e.g. LINK/USD)
    address public requiredPool;

    /// Slippage in BPS (e.g. 300 => 3%)
    uint256 public maxSlippageBps;

    /// Data for each NFT
    struct NftPosition {
        bool    exists;
        uint256 mintedShares;     
        address originalDepositor;
    }
    mapping(uint256 => NftPosition) public nftPositions;
    uint256[] public allTokenIds;

    // Events
    event ExternalContractsUpdated(address indexed oracle, address indexed rebal, address indexed liq);
    event SlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event NftDeposited(address indexed user, uint256 tokenId, uint256 mintedShares, uint256 nftValueUsd);
    event NftWithdrawn(address indexed user, uint256 tokenId, uint256 burnedShares, uint256 nftValueUsd);
    event LiquidityAdded(address indexed user, uint256 tokenId, uint256 mintedShares, uint256 addedValueUsd);
    event LiquidityRemoved(address indexed user, uint256 tokenId, uint256 burnedShares, uint256 removedValueUsd);
    event VaultRebalanced(uint256 tokenId, bytes data);
    event VaultLiquidated(address user, bytes data);
    event SharesSeized(address user, uint256 shares, address recipient);
    event RebalancerSharesMinted(uint256 extraValueUsd, address to, uint256 mintedShares);

    // UUPS
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Initialize. 
     *  - _requiredPool: the specific Uniswap V3 pool (LINK/USD, etc.) 
     *  - The OracleManager must be configured so that getPrice(address(this)) => returns 
     *    "USD per share" for the entire vault. 
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

        // Derive the UniswapV3Factory from the pool
        address factoryAddr = IUniswapV3Pool(_requiredPool).factory();
        require(factoryAddr != address(0), "Vault: invalid factory from pool");
        uniswapFactory = IUniswapV3Factory(factoryAddr);

        requiredPool  = _requiredPool;
        oracleManager = OracleManagerType(_oracleMgr);
        rebalancer    = RebalancerType(_rebalancer);
        liquidator    = LiquidatorType(_liquidator);

        // Default slippage (5%)
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

    // ------------------ NFT Handling (Deposit / Withdraw) ------------------

    /**
     * @dev onERC721Received is triggered when user does:
     *   positionManager.safeTransferFrom(user, vaultAddress, tokenId)
     * This vault enforces:
     *   require(msg.sender == address(positionManager)), 
     *   to ensure the NFT is truly from the official NFPM.
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override nonReentrant whenNotPaused returns (bytes4) {
        require(msg.sender == address(positionManager), "Vault: only NFPM");
        require(!nftPositions[tokenId].exists, "Vault: token in vault");

        _ensureCorrectPool(tokenId);

        // 1) Compute approximate USD value of the incoming NFT
        uint256 nftValueUsd = _approxNftUsdValue(tokenId);

        // 2) Mint shares
        uint256 oldSupply  = totalSupply();
        uint256 oldValue   = _getTotalVaultUsdValue(); // from aggregator
        uint256 minted;

        if (oldSupply == 0) {
            // First NFT => 1:1 with USD 
            minted = nftValueUsd;
        } else {
            // minted = fraction * oldSupply
            // fraction = nftValueUsd / oldValue
            // minted = (nftValueUsd * oldSupply) / oldValue
            if (oldValue == 0) {
                minted = nftValueUsd;
            } else {
                minted = (nftValueUsd * oldSupply) / oldValue;
            }
        }
        require(minted > 0 || oldSupply == 0, "Vault: minted=0? check NFT?");

        // 3) Record 
        nftPositions[tokenId] = NftPosition({
            exists: true,
            mintedShares: minted,
            originalDepositor: from
        });
        allTokenIds.push(tokenId);

        // 4) Mint shares to the depositor
        if (minted > 0) {
            _mint(from, minted);
        }

        emit NftDeposited(from, tokenId, minted, nftValueUsd);
        return IERC721ReceiverUpgradeable.onERC721Received.selector;
    }

    /**
     * @dev Withdraws a specific NFT, burning the shares minted for it.
     */
    function withdrawNFT(uint256 tokenId, address to) external nonReentrant whenNotPaused {
        require(to != address(0), "Vault: invalid to");
        NftPosition storage pos = nftPositions[tokenId];
        require(pos.exists, "Vault: not found");

        uint256 neededShares = pos.mintedShares;
        require(balanceOf(msg.sender) >= neededShares, "Vault: insufficient shares");
        _burn(msg.sender, neededShares);

        pos.exists = false;
        positionManager.safeTransferFrom(address(this), to, tokenId);

        uint256 valUsd = _getNftValue(tokenId); // current approximate 
        emit NftWithdrawn(msg.sender, tokenId, neededShares, valUsd);
    }

    // ------------------ Additional Liquidity in an NFT ------------------
    function depositAdditional(
        uint256 tokenId,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external nonReentrant whenNotPaused {
        NftPosition storage pos = nftPositions[tokenId];
        require(pos.exists, "Vault: unknown token");
        require(amount0Desired > 0 || amount1Desired > 0, "No deposit amounts");

        _ensureCorrectPool(tokenId);

        uint256 oldValUsd = _getTotalVaultUsdValue();
        uint256 oldSup    = totalSupply();

        uint256 amt0min = (amount0Desired * (10000 - maxSlippageBps)) / 10000;
        uint256 amt1min = (amount1Desired * (10000 - maxSlippageBps)) / 10000;

        // Increase liquidity 
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

        // Recompute the new total vault USD
        uint256 newValUsd = _getTotalVaultUsdValue();
        require(newValUsd > oldValUsd, "No net value?");
        uint256 depositValue = newValUsd - oldValUsd;

        // Mint shares for the user based on fraction
        uint256 minted = (oldSup == 0)
            ? depositValue
            : (depositValue * oldSup) / (oldValUsd == 0 ? 1 : oldValUsd);

        pos.mintedShares += minted;
        if (minted > 0) {
            _mint(msg.sender, minted);
        }

        emit LiquidityAdded(msg.sender, tokenId, minted, depositValue);
    }

    /**
     * Remove liquidity partially from an NFT, returning tokens directly to user
     */
    struct RemoveLiquidityLocalVars {
        uint256 oldValUsd;
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
        require(balanceOf(msg.sender) >= sharesToBurn, "Vault: insufficient shares");

        _ensureCorrectPool(tokenId);

        // burn user shares first
        _burn(msg.sender, sharesToBurn);

        RemoveLiquidityLocalVars memory v;
        v.oldValUsd = _getTotalVaultUsdValue();
        v.oldSup    = totalSupply() + sharesToBurn;

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

        // proportion to remove
        v.liqRemove = uint128((uint256(v.currentLiquidity) * sharesToBurn) / v.oldSup);
        if (v.liqRemove > 0) {
            // estimate amounts 
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

        uint256 newValUsd = _getTotalVaultUsdValue();
        uint256 removedValue = (v.oldValUsd > newValUsd) ? (v.oldValUsd - newValUsd) : 0;

        emit LiquidityRemoved(msg.sender, tokenId, sharesToBurn, removedValue);
    }

    // ------------------ Rebalance & Liquidation ------------------
    function rebalanceVault(uint256 tokenId, bytes calldata data) external whenNotPaused {
        require(nftPositions[tokenId].exists, "Vault: no such NFT");
        rebalancer.rebalance(address(this), data);
        emit VaultRebalanced(tokenId, data);
    }

    function rebalancerMintShares(uint256 extraValueUsd, address to) external {
        require(msg.sender == address(rebalancer), "Vault: only rebalancer");
        require(extraValueUsd > 0, "No extraValue");
        uint256 oldVal = _getTotalVaultUsdValue();
        uint256 oldSup = totalSupply();

        // minted shares = fraction of old supply
        uint256 minted = (oldSup == 0)
            ? extraValueUsd
            : (extraValueUsd * oldSup) / (oldVal == 0 ? 1 : oldVal);

        _mint(to, minted);
        emit RebalancerSharesMinted(extraValueUsd, to, minted);
    }

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

    // ------------------ Price (Vault as a single "token") ------------------
    /**
     * The OracleManager is set up with isVaultToken=true for this address.
     * So getPrice(address(this)) => "USD per share" 
     */
    function getUnderlyingPrice() external view returns (uint256 price, uint8 decimals) {
        return oracleManager.getPrice(address(this));
    }

    // ------------------ Internal Helpers ------------------

    /**
     * @dev Approximate the NFT's USD value by comparing its liquidity 
     *      to the total vault liquidity, then multiplying by the vault's 
     *      total USD. 
     */
    function _approxNftUsdValue(uint256 tokenId) internal view returns (uint256) {
        // 1) sum total liquidity of all NFTs
        uint256 totalLiq;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            uint256 tid = allTokenIds[i];
            if (nftPositions[tid].exists) {
                (, , , , , , , uint128 liq, , , ,) = positionManager.positions(tid);
                totalLiq += liq;
            }
        }

        // 2) get this NFT's liquidity
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint128 nftLiq,
            ,
            ,
            ,

        ) = positionManager.positions(tokenId);

        if (nftLiq == 0) {
            // no liquidity => 0
            return 0;
        }

        // 3) get entire vault's total USD from aggregator
        uint256 vaultUsd = _getTotalVaultUsdValue();
        uint256 combinedLiq = totalLiq + nftLiq; 
        // if old NFT is not yet included in total?

        // 4) fraction = nftLiq / (totalLiq + nftLiq) 
        //    approximate NFT portion of "the new total" 
        //    If vaultUsd=0 => minted=0
        //    If totalLiq=0 => let fraction=1
        uint256 fraction;
        if (combinedLiq == 0) {
            fraction = 1; 
        } else {
            fraction = (uint256(nftLiq) * 1e18) / combinedLiq; // fraction in [0..1], scaled 1e18
        }


        uint256 nftValue = (vaultUsd * fraction) / 1e18;
        return nftValue;
    }

    /**
     * @dev Return how many total "USD" the vault represents, by calling
     *      oracleManager.getPrice(address(this)) => (pricePerShare, decimals)
     *      Then multiply price/share * totalSupply 
     */
    function _getTotalVaultUsdValue() internal view returns (uint256) {
        (uint256 psPrice, uint8 psDec) = oracleManager.getPrice(address(this));
        uint256 supply = totalSupply();
        if (supply == 0) {
            return 0;
        }
        // totalUsd = (psPrice * supply) / 10^psDec
        return (psPrice * supply) / (10 ** psDec);
    }

    /**
     * @dev Return the approximate current value of an NFT => 
     *      mintedShares * (vaultPrice/share / 10^dec).
     *      Because mintedShares ~ fraction of total supply.
     */
    function _getNftValue(uint256 tokenId) internal view returns (uint256) {
        NftPosition storage pos = nftPositions[tokenId];
        if (!pos.exists) {
            return 0;
        }
        // per-share price
        (uint256 psPrice, uint8 psDec) = oracleManager.getPrice(address(this));

        // minted shares for this NFT
        uint256 minted = pos.mintedShares;
        // NFT’s portion = minted * price/share / 10^dec
        return (minted * psPrice) / (10 ** psDec);
    }

    /**
     * @dev Ensures the NFT's pool is exactly requiredPool
     */
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

    /**
     * @dev For removing liquidity. 
     */
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
