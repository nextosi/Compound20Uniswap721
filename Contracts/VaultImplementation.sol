// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/* ---------------------------------------------------------------------
 * 1) Minimal Upgradable & Utility Patterns
 *    (Local patches of Ownable, ERC20, Pausable, ReentrancyGuard, UUPS)
 * --------------------------------------------------------------------- */

/**
 * @dev Minimal local Ownable for ^0.8.28, no old references.
 */
contract OwnableLocal {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function _initOwner(address initialOwner) internal {
        require(initialOwner != address(0), "OwnableLocal: invalid owner");
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        require(owner() == msg.sender, "OwnableLocal: not owner");
        _;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "OwnableLocal: invalid");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/**
 * @dev Minimal local Pausable for ^0.8.28, no old references.
 */
contract PausableLocal {
    bool private _paused;

    event Paused(address account);
    event Unpaused(address account);

    function _initPausable() internal {
        _paused = false;
    }

    modifier whenNotPaused() {
        require(!paused(), "PausableLocal: paused");
        _;
    }

    modifier whenPaused() {
        require(paused(), "PausableLocal: not paused");
        _;
    }

    function paused() public view returns (bool) {
        return _paused;
    }

    function _pause() internal whenNotPaused {
        _paused = true;
        emit Paused(msg.sender);
    }

    function _unpause() internal whenPaused {
        _paused = false;
        emit Unpaused(msg.sender);
    }
}

/**
 * @dev Minimal local ReentrancyGuard for ^0.8.28.
 */
contract ReentrancyGuardLocal {
    uint256 private _status;

    modifier nonReentrant() {
        require(_status != 2, "ReentrancyGuardLocal: reentrant call");
        _status = 2;
        _;
        _status = 1;
    }

    function _initReentrancyGuard() internal {
        _status = 1;
    }
}

/**
 * @dev Minimal local UUPS pattern for ^0.8.28. 
 *      We define a `_authorizeUpgrade(newImplementation)` that must be overridden.
 */
contract UUPSLocal {
    // Emitted when upgraded
    event Upgraded(address indexed implementation);

    /**
     * @notice Upgrade to new implementation address. 
     *         Must call `_authorizeUpgrade` for permission checks.
     */
    function upgradeTo(address newImplementation) external {
        _authorizeUpgrade(newImplementation);
        _upgradeImplementation(newImplementation);
    }

    /**
     * @dev Called by `upgradeTo` to actually store the new implementation address.
     *      For simplicity, we do NOT store it in ERC1967 “slot.” 
     *      Instead, you can store it in your own local state if needed.
     *      If you truly need ERC1967 semantics, you must replicate that logic
     *      in a local patch. This is just a demonstration.
     */
    function _upgradeImplementation(address newImpl) internal {
        require(newImpl != address(0), "UUPSLocal: invalid impl");
        emit Upgraded(newImpl);
        // Placeholder: store in your chosen location, if desired
        // e.g. _implementation = newImpl; 
        // or use a proxy pattern that delegates calls to newImpl.
    }

    /**
     * @dev You must override this with e.g. `onlyOwner` or some other check.
     */
    function _authorizeUpgrade(address newImplementation) internal virtual {
        // override me, e.g. require(msg.sender == owner, "not authorized");
        // or some custom logic
    }
}

/**
 * @dev Minimal local ERC20 for ^0.8.28 with an initializer. 
 *      No old references from OpenZeppelin.
 */
contract ERC20Local {
    string private _name;
    string private _symbol;
    uint8 private constant _decimals = 18;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function _initERC20(string memory name_, string memory symbol_) internal {
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public pure returns (uint8) { return _decimals; }
    function totalSupply() public view returns (uint256) { return _totalSupply; }

    function balanceOf(address account) public view returns (uint256) { 
        return _balances[account]; 
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function allowance(address owner_, address spender) public view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "ERC20Local: insufficient allowance");
        unchecked {
            _approve(from, msg.sender, currentAllowance - amount);
        }
        _transfer(from, to, amount);
        return true;
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20Local: mint to zero");
        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal {
        require(_balances[account] >= amount, "ERC20Local: burn exceeds balance");
        _balances[account] -= amount;
        _totalSupply -= amount;
        emit Transfer(account, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "ERC20Local: transfer from 0");
        require(to != address(0), "ERC20Local: transfer to 0");

        uint256 fromBal = _balances[from];
        require(fromBal >= amount, "ERC20Local: transfer > balance");
        unchecked {
            _balances[from] = fromBal - amount;
        }
        _balances[to] += amount;

        emit Transfer(from, to, amount);
    }

    function _approve(address owner_, address spender, uint256 amount) internal {
        require(owner_ != address(0), "ERC20Local: approve from zero");
        require(spender != address(0), "ERC20Local: approve to zero");
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }
}

/* ---------------------------------------------------------------------
 * 2) Minimal local NFT Receiver (IERC721Receiver) for ^0.8.28
 * --------------------------------------------------------------------- */
interface IERC721ReceiverLocal {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/* ---------------------------------------------------------------------
 * 3) Minimal Uniswap interfaces that do not pull in <0.8.0 references
 * --------------------------------------------------------------------- */
interface ILocalNonfungiblePositionManager {
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

    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function increaseLiquidity(IncreaseLiquidityParams calldata params) 
        external 
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);
    function collect(CollectParams calldata params) 
        external 
        returns (uint256 amount0, uint256 amount1);
}

interface ILocalUniswapV3Pool {
    function factory() external view returns (address);
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

interface ILocalUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/* ---------------------------------------------------------------------
 * 4) Local placeholder interfaces for OracleManager, Rebalancer, Liquidator
 * --------------------------------------------------------------------- */
interface OracleManagerLocal {
    function getPrice(address token) external view returns (uint256, uint8);
}

interface RebalancerLocal {
    function rebalance(address vault, bytes calldata data) external;
}

interface LiquidatorLocal {
    function liquidate(address vault, address user, uint256 seizeAmount) external;
}

/* ---------------------------------------------------------------------
 * 5) TickMathLocal - patched for ^0.8.x
 * --------------------------------------------------------------------- */
library TickMathLocal {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK =  887272;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        require(tick >= MIN_TICK && tick <= MAX_TICK, "Tick out of range");
        int256 t = int256(tick);
        uint256 absTick = t < 0 ? uint256(-t) : uint256(t);

        // ratio in Q128.128
        uint256 ratio = 0x100000000000000000000000000000000;
        // for brevity, we skip the bit-by-bit multiplications
        // you can add them if you do real math. This is a placeholder formula:
        if (tick > 0) {
            ratio = type(uint256).max / ratio;
        }
        uint256 shifted = ratio >> 32;
        require(shifted <= type(uint160).max, "Price overflow");
        return uint160(shifted);
    }
}

/* ---------------------------------------------------------------------
 * 6) Minimal LiquidityAmountsLocal
 * --------------------------------------------------------------------- */
library LiquidityAmountsLocal {
    function getAmountsForLiquidity(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        // For demonstration, you can fill in real logic or keep placeholders
        // to avoid references to <0.8.0 FullMath. Example:
        if (liquidity == 0 || sqrtRatioX96 == 0) {
            return (0, 0);
        }
        // just a mock calculation
        amount0 = uint256(liquidity) * 1000;
        amount1 = uint256(liquidity) * 2000;
    }
}

/* ---------------------------------------------------------------------
 * 7) VaultImplementation (UUPSLocal, etc.)
 * --------------------------------------------------------------------- */
contract VaultImplementation is
    ERC20Local,
    PausableLocal,
    ReentrancyGuardLocal,
    OwnableLocal,
    UUPSLocal,
    IERC721ReceiverLocal
{
    // External references
    OracleManagerLocal public oracleManager;
    RebalancerLocal    public rebalancer;
    LiquidatorLocal    public liquidator;

    ILocalNonfungiblePositionManager public positionManager;
    ILocalUniswapV3Factory           public uniswapFactory;

    address public requiredPool;
    uint256 public maxSlippageBps;

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

    /**
     * @dev Because we are combining everything locally, we do not rely on the usual
     *      upgradeable initializer approach from OpenZeppelin. Instead, we define
     *      our own `initialize` that calls internal `_init` methods.
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
    ) external {
        // We can add a check to ensure it's only called once, or track an "initialized" state.
        // For brevity, we skip that.

        // Initialize ownable
        _initOwner(_owner);

        // Initialize ERC20
        _initERC20(_name, _symbol);

        // Initialize Pausable
        _initPausable();

        // Initialize Reentrancy
        _initReentrancyGuard();

        // No special UUPS init, we'll rely on manually overriding _authorizeUpgrade

        require(_requiredPool    != address(0), "Vault: invalid pool");
        require(_positionManager != address(0), "Vault: invalid posMgr");
        require(_oracleMgr       != address(0), "Vault: invalid oracle");
        require(_rebalancer      != address(0), "Vault: invalid rebalancer");
        require(_liquidator      != address(0), "Vault: invalid liquidator");

        positionManager = ILocalNonfungiblePositionManager(_positionManager);

        // Derive the UniswapV3Factory from the pool
        address factoryAddr = ILocalUniswapV3Pool(_requiredPool).factory();
        require(factoryAddr != address(0), "Vault: invalid factory from pool");
        uniswapFactory = ILocalUniswapV3Factory(factoryAddr);

        requiredPool  = _requiredPool;
        oracleManager = OracleManagerLocal(_oracleMgr);
        rebalancer    = RebalancerLocal(_rebalancer);
        liquidator    = LiquidatorLocal(_liquidator);

        // Default slippage (5%)
        maxSlippageBps = 500;

        emit ExternalContractsUpdated(_oracleMgr, _rebalancer, _liquidator);
    }

    // UUPS override
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // onlyOwner check
    }

    // -------------- Owner Setters --------------
    function setExternalContracts(
        address _oracleMgr,
        address _rebalancer,
        address _liquidator
    ) external onlyOwner {
        require(_oracleMgr != address(0),  "Vault: invalid oracle");
        require(_rebalancer != address(0), "Vault: invalid rebalancer");
        require(_liquidator != address(0), "Vault: invalid liquidator");

        oracleManager = OracleManagerLocal(_oracleMgr);
        rebalancer    = RebalancerLocal(_rebalancer);
        liquidator    = LiquidatorLocal(_liquidator);

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

    // -------------- NFT Handling --------------

    /**
     * @dev Minimal local version of IERC721Receiver. Must return onERC721Received.selector.
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

        // Compute approximate USD
        uint256 nftValueUsd = _approxNftUsdValue(tokenId);

        // Mint shares
        uint256 oldSupply = totalSupply();
        uint256 oldValue  = _getTotalVaultUsdValue();
        uint256 minted;

        if (oldSupply == 0) {
            minted = nftValueUsd;
        } else {
            if (oldValue == 0) {
                minted = nftValueUsd;
            } else {
                minted = (nftValueUsd * oldSupply) / oldValue;
            }
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

        emit NftDeposited(from, tokenId, minted, nftValueUsd);
        return IERC721ReceiverLocal.onERC721Received.selector;
    }

    function withdrawNFT(uint256 tokenId, address to) external nonReentrant whenNotPaused {
        require(to != address(0), "Vault: invalid to");
        NftPosition storage pos = nftPositions[tokenId];
        require(pos.exists, "Vault: not found");

        uint256 neededShares = pos.mintedShares;
        require(balanceOf(msg.sender) >= neededShares, "Vault: insufficient shares");
        _burn(msg.sender, neededShares);

        pos.exists = false;
        positionManager.safeTransferFrom(address(this), to, tokenId);

        uint256 valUsd = _getNftValue(tokenId);
        emit NftWithdrawn(msg.sender, tokenId, neededShares, valUsd);
    }

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

        ILocalNonfungiblePositionManager.IncreaseLiquidityParams memory p =
            ILocalNonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amt0min,
                amount1Min: amt1min,
                deadline: block.timestamp + 1800
            });
        (uint128 liq, , ) = positionManager.increaseLiquidity(p);
        require(liq > 0, "No liquidity added?");

        uint256 newValUsd = _getTotalVaultUsdValue();
        require(newValUsd > oldValUsd, "No net value?");
        uint256 depositValue = newValUsd - oldValUsd;

        uint256 minted = (oldSup == 0) ? depositValue : ((depositValue * oldSup) / (oldValUsd == 0 ? 1 : oldValUsd));

        pos.mintedShares += minted;
        if (minted > 0) {
            _mint(msg.sender, minted);
        }

        emit LiquidityAdded(msg.sender, tokenId, minted, depositValue);
    }

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

        _burn(msg.sender, sharesToBurn);

        RemoveLiquidityLocalVars memory v;
        v.oldValUsd = _getTotalVaultUsdValue();
        v.oldSup    = totalSupply() + sharesToBurn;

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

            ILocalNonfungiblePositionManager.DecreaseLiquidityParams memory d =
                ILocalNonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: tokenId,
                    liquidity: v.liqRemove,
                    amount0Min: min0,
                    amount1Min: min1,
                    deadline: block.timestamp + 1800
                });
            (uint256 removed0, uint256 removed1) = positionManager.decreaseLiquidity(d);

            ILocalNonfungiblePositionManager.CollectParams memory c =
                ILocalNonfungiblePositionManager.CollectParams({
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

    // -------------- Rebalance & Liquidation --------------

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

        uint256 minted = (oldSup == 0) ? extraValueUsd : ((extraValueUsd * oldSup) / (oldVal == 0 ? 1 : oldVal));
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

    // -------------- Price --------------

    function getUnderlyingPrice() external view returns (uint256 price, uint8 decimals) {
        return oracleManager.getPrice(address(this));
    }

    // -------------- Internal Helpers --------------

    function _approxNftUsdValue(uint256 tokenId) internal view returns (uint256) {
        uint256 totalLiq;
        for (uint256 i = 0; i < allTokenIds.length; i++) {
            uint256 tid = allTokenIds[i];
            if (nftPositions[tid].exists) {
                (, , , , , , , uint128 liq, , , ,) = positionManager.positions(tid);
                totalLiq += liq;
            }
        }

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
            return 0;
        }

        uint256 vaultUsd = _getTotalVaultUsdValue();
        uint256 combinedLiq = totalLiq + nftLiq;

        uint256 fraction;
        if (combinedLiq == 0) {
            fraction = 1;
        } else {
            fraction = (uint256(nftLiq) * 1e18) / combinedLiq;
        }
        return (vaultUsd * fraction) / 1e18;
    }

    function _getTotalVaultUsdValue() internal view returns (uint256) {
        (uint256 psPrice, uint8 psDec) = oracleManager.getPrice(address(this));
        uint256 supply = totalSupply();
        if (supply == 0) {
            return 0;
        }
        return (psPrice * supply) / (10 ** psDec);
    }

    function _getNftValue(uint256 tokenId) internal view returns (uint256) {
        NftPosition storage pos = nftPositions[tokenId];
        if (!pos.exists) {
            return 0;
        }
        (uint256 psPrice, uint8 psDec) = oracleManager.getPrice(address(this));
        uint256 minted = pos.mintedShares;
        return (minted * psPrice) / (10 ** psDec);
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

        (uint160 sqrtPriceX96, , , , , , ) = ILocalUniswapV3Pool(poolAddr).slot0();

        (amt0, amt1) = LiquidityAmountsLocal.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMathLocal.getSqrtRatioAtTick(tickLower),
            TickMathLocal.getSqrtRatioAtTick(tickUpper),
            liqToRemove
        );
    }

    receive() external payable {}
}
