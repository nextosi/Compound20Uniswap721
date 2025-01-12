// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @dev Minimal local `Ownable` under ^0.8.28 to avoid importing older
 *      openzeppelin code referencing <0.8.0. If you prefer, you can
 *      manually copy the official OZ v4.8.3 code (which is ^0.8.x)
 *      but remove or update any leftover <0.8.0 references.
 */
contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        require(initialOwner != address(0), "Ownable: invalid owner");
        _owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        require(owner() == msg.sender, "Ownable: not owner");
        _;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: invalid newOwner");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

/**
 * @dev Minimal local interface for OracleManager. 
 *      We only need to store a reference to it and possibly call some function,
 *      but if your code never calls it, we can omit the function signature.
 */
interface OracleManager {
    // e.g. if you need a function like getSomething() from the Oracle,
    // declare it here. Otherwise it can be blank if you only store a reference.
    // function getSomeValue() external view returns (uint256);
}

/**
 * @dev Minimal interface for an ERC721-based vault that the Rebalancer interacts with.
 *      We specifically want:
 *      - vaultPositionTokenId() => returns the Uniswap v3 position tokenId
 *      - positionManager() => returns the NFPM address
 *      - getUnderlyingPrice() => returns a price for optional checks
 *      - rebalancerMintShares(...) => a function to auto-compound new shares
 */
interface IMultiNftVaultRebalance {
    function vaultPositionTokenId() external view returns (uint256);
    function positionManager() external view returns (address);
    function getUnderlyingPrice() external view returns (uint256 price, uint8 decimals);
    function rebalancerMintShares(uint256 extraValue, address to) external;
}

/**
 * @dev A local interface for Uniswap’s INonfungiblePositionManager
 *      so we avoid pulling in older `<0.8.0` references.
 */
interface IMinimalNonfungiblePositionManager {
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

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
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
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);
}

/**
 * @title Rebalancer
 * @notice Rebalances a Uniswap V3 position for a Vault by removing/adding liquidity,
 *         optionally checking an OracleManager for price constraints, 
 *         and providing an “auto-compounding” feature that can mint shares.
 *
 *         This version uses no external references that specify `<0.8.0`,
 *         thus avoiding the “ParserError: Source file requires different compiler version” issue.
 */
contract Rebalancer is Ownable {

    OracleManager public oracleManager;

    uint256 public minPriceAllowed;
    uint256 public maxPriceAllowed;

    bool public defaultAutoCompound;

    event RebalancePerformed(
        address indexed vault,
        uint256 tokenId,
        uint256 amount0Removed,
        uint256 amount1Removed,
        uint256 amount0Added,
        uint256 amount1Added,
        bool autoCompounded,
        uint256 mintedShares
    );

    event PriceBoundsUpdated(uint256 minPrice, uint256 maxPrice);

    /**
     * @dev We pass the `initialOwner` to our local `Ownable` constructor.
     *      `_oracleManager` is stored in case you want to call it for some logic (not shown).
     *      `[minPriceAllowed, maxPriceAllowed]` define optional price range checks.
     */
    constructor(
        address initialOwner,
        address _oracleManager,
        uint256 _minPrice,
        uint256 _maxPrice
    )
        Ownable(initialOwner)
    {
        require(_oracleManager != address(0), "Rebalancer: invalid oracle");
        require(_minPrice <= _maxPrice, "Rebalancer: minPrice>maxPrice");

        oracleManager   = OracleManager(_oracleManager);
        minPriceAllowed = _minPrice;
        maxPriceAllowed = _maxPrice;

        emit PriceBoundsUpdated(_minPrice, _maxPrice);
    }

    // ------------------ Owner Setters ------------------

    function setPriceBounds(uint256 newMin, uint256 newMax) external onlyOwner {
        require(newMin <= newMax, "Rebalancer: minPrice>maxPrice");
        minPriceAllowed = newMin;
        maxPriceAllowed = newMax;
        emit PriceBoundsUpdated(newMin, newMax);
    }

    function setOracleManager(address newOracle) external onlyOwner {
        require(newOracle != address(0), "Rebalancer: invalid oracle");
        oracleManager = OracleManager(newOracle);
    }

    function setDefaultAutoCompound(bool autoCompound) external onlyOwner {
        defaultAutoCompound = autoCompound;
    }

    // ------------------ Data Structures ------------------

    struct ExtendedRebalanceArgs {
        uint128 liquidityToRemove;
        uint256 amount0MinRemove;
        uint256 amount1MinRemove;
        uint256 amount0DesiredAdd;
        uint256 amount1DesiredAdd;
        uint256 deadline;
        bool autoCompound;              
        uint256 extraValueForCompounding;
    }

    struct RebalanceLocalVars {
        address posMgr;
        uint256 tokenId;
        uint128 currentLiquidity;
        uint256 amt0Removed;
        uint256 amt1Removed;
        uint256 collect0;
        uint256 collect1;
        uint128 newLiquidity;
        uint256 amt0Added;
        uint256 amt1Added;
        bool doAuto;
        uint256 minted;
    }

    // ------------------ External Entry ------------------

    /**
     * @notice Rebalances the position by removing liquidity, collecting tokens, optionally adding more,
     *         and optionally auto-compounding (minting shares).
     *
     * @param vault The address of the vault implementing IMultiNftVaultRebalance
     * @param data  The ABI-encoded ExtendedRebalanceArgs
     */
    function rebalance(address vault, bytes calldata data) external onlyOwner {
        require(vault != address(0), "Rebalancer: invalid vault");
        RebalanceLocalVars memory v = _rebalanceInternal(vault, data);

        emit RebalancePerformed(
            vault,
            v.tokenId,
            v.amt0Removed,
            v.amt1Removed,
            v.amt0Added,
            v.amt1Added,
            v.doAuto,
            v.minted
        );
    }

    // ------------------ Internal Logic ------------------

    function _rebalanceInternal(address vault, bytes calldata data)
        private
        returns (RebalanceLocalVars memory v)
    {
        // 1) decode arguments
        ExtendedRebalanceArgs memory args = _decodeArgs(data);

        // 2) get the vault interface
        IMultiNftVaultRebalance vaultInterface = IMultiNftVaultRebalance(vault);
        v.tokenId = vaultInterface.vaultPositionTokenId();
        v.posMgr  = vaultInterface.positionManager();

        // 3) optional price checks
        _checkPriceConstraints(vaultInterface);

        // 4) fetch current liquidity
        v.currentLiquidity = _fetchLiquidity(v.posMgr, v.tokenId);
        require(v.currentLiquidity >= args.liquidityToRemove, "Rebalancer: not enough liquidity");

        // 5) remove liquidity
        (v.amt0Removed, v.amt1Removed) = _removeLiquidity(
            v.posMgr,
            v.tokenId,
            args.liquidityToRemove,
            args.amount0MinRemove,
            args.amount1MinRemove,
            args.deadline
        );

        // 6) collect tokens
        (v.collect0, v.collect1) = _collectAll(v.posMgr, vault, v.tokenId);

        // 7) optionally add more liquidity
        if (args.amount0DesiredAdd > 0 || args.amount1DesiredAdd > 0) {
            (v.newLiquidity, v.amt0Added, v.amt1Added) = _addLiquidity(
                v.posMgr,
                v.tokenId,
                args.amount0DesiredAdd,
                args.amount1DesiredAdd,
                args.deadline
            );
        }

        // 8) auto-compound?
        v.doAuto = (args.autoCompound || defaultAutoCompound);
        if (v.doAuto && args.extraValueForCompounding > 0) {
            vaultInterface.rebalancerMintShares(args.extraValueForCompounding, owner());
            v.minted = args.extraValueForCompounding; 
        }

        return v;
    }

    function _decodeArgs(bytes calldata data)
        private
        pure
        returns (ExtendedRebalanceArgs memory a)
    {
        (
            a.liquidityToRemove,
            a.amount0MinRemove,
            a.amount1MinRemove,
            a.amount0DesiredAdd,
            a.amount1DesiredAdd,
            a.deadline,
            a.autoCompound,
            a.extraValueForCompounding
        ) = abi.decode(data, (uint128, uint256, uint256, uint256, uint256, uint256, bool, uint256));
    }

    function _checkPriceConstraints(IMultiNftVaultRebalance vaultInterface) private view {
        if (minPriceAllowed > 0 || maxPriceAllowed > 0) {
            (uint256 vaultPrice, ) = vaultInterface.getUnderlyingPrice();
            require(
                vaultPrice >= minPriceAllowed && vaultPrice <= maxPriceAllowed,
                "Rebalancer: vault price out of range"
            );
        }
    }

    function _fetchLiquidity(address posMgr, uint256 tokenId)
        private
        view
        returns (uint128 liquidity)
    {
        // call positions(tokenId)
        (bool success, bytes memory result) = posMgr.staticcall(
            abi.encodeWithSelector(IMinimalNonfungiblePositionManager.positions.selector, tokenId)
        );
        require(success, _getRevertMsg(result));

        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            liquidity,
            ,
            ,
            ,
        ) = abi.decode(
            result,
            (
                uint96,
                address,
                address,
                address,
                uint24,
                int24,
                int24,
                uint128,
                uint256,
                uint256,
                uint128,
                uint128
            )
        );
    }

    function _removeLiquidity(
        address posMgr,
        uint256 tokenId,
        uint128 liquidityToRemove,
        uint256 amount0MinRemove,
        uint256 amount1MinRemove,
        uint256 deadline
    )
        private
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidityToRemove == 0) {
            return (0, 0);
        }

        IMinimalNonfungiblePositionManager.DecreaseLiquidityParams memory p =
            IMinimalNonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidityToRemove,
                amount0Min: amount0MinRemove,
                amount1Min: amount1MinRemove,
                deadline: deadline
            });

        (amount0, amount1) = IMinimalNonfungiblePositionManager(posMgr).decreaseLiquidity(p);
    }

    function _collectAll(address posMgr, address recipient, uint256 tokenId)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        IMinimalNonfungiblePositionManager.CollectParams memory cp =
            IMinimalNonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: recipient,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            });

        (amount0, amount1) = IMinimalNonfungiblePositionManager(posMgr).collect(cp);
    }

    function _addLiquidity(
        address posMgr,
        uint256 tokenId,
        uint256 amount0DesiredAdd,
        uint256 amount1DesiredAdd,
        uint256 deadline
    )
        private
        returns (uint128 liquidity, uint256 used0, uint256 used1)
    {
        IMinimalNonfungiblePositionManager.IncreaseLiquidityParams memory p =
            IMinimalNonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0DesiredAdd,
                amount1Desired: amount1DesiredAdd,
                amount0Min: 0,
                amount1Min: 0,
                deadline: deadline
            });

        (liquidity, used0, used1) = IMinimalNonfungiblePositionManager(posMgr).increaseLiquidity(p);
    }

    function _getRevertMsg(bytes memory _returnData) private pure returns (string memory) {
        if (_returnData.length < 68) return "Rebalancer: call reverted w/o message";
        assembly {
            _returnData := add(_returnData, 0x04)
        }
        return abi.decode(_returnData, (string));
    }
}
