// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./Rebalancer.sol";
import "./Liquidator.sol";
import "./OracleManager.sol";

/**
 * @dev Minimal interface for interacting with Uniswap V3's NonfungiblePositionManager.
 *      Used for add/remove liquidity and reading positions.
 */
interface INonfungiblePositionManager {
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        int24 tickLower;
        int24 tickUpper;
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
            int24 tickLower,
            int24 tickUpper,
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

    function collect(CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1);

    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/**
 * @title VaultImplementation
 * @notice An upgradeable vault that manages a single Uniswap V3 position (NFT),
 *         issues ERC20 shares to represent user ownership, supports partial deposit/withdraw,
 *         references external Rebalancer, Liquidator, and OracleManager, and locks the NFT
 *         so it cannot be removed except via vault logic.
 *
 *         Key Features:
 *         1. Single NFT reference (vaultTokenId). Initially 0 until a position is deposited.
 *         2. onERC721Received to accept a Uniswap V3 position from NonfungiblePositionManager.
 *         3. deposit() / withdraw() to add/remove token0/token1 liquidity from the existing position.
 *         4. rebalancer/ liquidator external calls for advanced logic.
 *         5. Price-based share minting/burning: partial deposit/withdraw changes totalUnderlying
 *            or totalLiquidity, adjusts share distribution accordingly.
 *         6. UUPS upgradeable pattern with onlyOwner gating.
 *         7. Pausable & ReentrancyGuard for safety.
 *
 *         This contract is intended to be deployed behind an ERC1967Proxy.
 */
contract VaultImplementation is
    ERC20Upgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IERC721Receiver
{
    /**
     * @dev Address of the Uniswap V3 pool this vault is restricted to (token0, token1, fee).
     *      This is for validation if needed. 
     */
    address public v3Pool;

    /**
     * @dev Reference to the Uniswap V3 NonfungiblePositionManager. Used for liquidity calls.
     */
    INonfungiblePositionManager public positionManager;

    /**
     * @dev The NFT tokenId representing this vault's single Uniswap V3 position.
     *      If 0, no position is currently owned by the vault.
     */
    uint256 public vaultTokenId;

    /**
     * @dev External references for advanced operations.
     */
    OracleManager public oracleManager;
    Rebalancer public rebalancer;
    Liquidator public liquidator;

    /**
     * @dev Tracks an internal measure of total "liquidity" or "underlying" 
     *      used to compute share price. 
     *      If you prefer a direct formula using the position's liquidity & token amounts,
     *      you can skip storing this and compute on the fly.
     */
    uint256 public totalUnderlying;

    /**
     * @dev Emitted when external references are updated.
     */
    event ExternalContractsUpdated(
        address indexed oracleManager,
        address indexed rebalancer,
        address indexed liquidator
    );

    /**
     * @dev Emitted when a new position NFT is received into the vault.
     */
    event PositionReceived(
        address from,
        uint256 tokenId,
        uint128 liquidityAdded,
        uint256 shareMinted
    );

    /**
     * @dev Emitted when tokens are deposited (adding liquidity to the existing position).
     */
    event Deposited(
        address indexed user,
        uint256 token0In,
        uint256 token1In,
        uint128 liquidityAdded,
        uint256 sharesMinted
    );

    /**
     * @dev Emitted when tokens are withdrawn (removing liquidity).
     */
    event Withdrawn(
        address indexed user,
        uint128 liquidityRemoved,
        uint256 amount0Out,
        uint256 amount1Out,
        uint256 sharesBurned
    );

    /**
     * @dev Emitted when the entire NFT is transferred out. 
     *      This might be a special scenario if you allow full exit by a single user.
     */
    event NFTWithdrawn(address to, uint256 tokenId);

    /**
     * @dev Emitted after a rebalancing operation is triggered from the vault side.
     */
    event VaultRebalanced(bytes data);

    /**
     * @dev Emitted after a liquidation operation is triggered from the vault side.
     */
    event VaultLiquidated(address user, bytes data);

    /**
     * @dev Emitted when shares are forcibly seized from a user by the liquidator.
     */
    event SharesSeized(address user, uint256 shares);

    /**
     * @dev Required for UUPS to restrict who can upgrade this contract.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Initializes the vault. Called once during proxy deployment.
     *
     * @param _v3Pool          The Uniswap V3 pool address this vault is restricted to
     * @param _positionManager The NonfungiblePositionManager contract
     * @param _oracleMgr       The OracleManager address
     * @param _rebalancer      The Rebalancer address
     * @param _liquidator      The Liquidator address
     * @param _owner           The vault owner
     * @param _name            ERC20 name for share tokens
     * @param _symbol          ERC20 symbol for share tokens
     */
    function initialize(
        address _v3Pool,
        address _positionManager,
        address _oracleMgr,
        address _rebalancer,
        address _liquidator,
        address _owner,
        string memory _name,
        string memory _symbol
    ) external initializer {
        __ERC20_init(_name, _symbol);
        __Ownable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        require(_v3Pool != address(0), "Vault: invalid v3Pool");
        require(_positionManager != address(0), "Vault: invalid positionMgr");
        v3Pool = _v3Pool;
        positionManager = INonfungiblePositionManager(_positionManager);

        oracleManager = OracleManager(_oracleMgr);
        rebalancer = Rebalancer(_rebalancer);
        liquidator = Liquidator(_liquidator);

        totalUnderlying = 0;
        vaultTokenId = 0;

        _transferOwnership(_owner);

        emit ExternalContractsUpdated(_oracleMgr, _rebalancer, _liquidator);
    }

    /**
     * @notice Updates external references if needed.
     * @param _oracleMgr   The new OracleManager
     * @param _rebalancer  The new Rebalancer
     * @param _liquidator  The new Liquidator
     */
    function setExternalContracts(
        address _oracleMgr,
        address _rebalancer,
        address _liquidator
    ) external onlyOwner {
        require(_oracleMgr != address(0), "Vault: invalid oracle");
        require(_rebalancer != address(0), "Vault: invalid rebalancer");
        require(_liquidator != address(0), "Vault: invalid liquidator");

        oracleManager = OracleManager(_oracleMgr);
        rebalancer = Rebalancer(_rebalancer);
        liquidator = Liquidator(_liquidator);

        emit ExternalContractsUpdated(_oracleMgr, _rebalancer, _liquidator);
    }

    /**
     * @notice The vault can be paused or unpaused by the owner for emergencies.
     */
    function pauseVault() external onlyOwner {
        _pause();
    }

    function unpauseVault() external onlyOwner {
        _unpause();
    }

    /**
     * @notice The vault implements onERC721Received to accept a new position NFT from 
     *         NonfungiblePositionManager. This is triggered when a user or contract
     *         calls safeTransferFrom(...). 
     *
     *         If the vault doesn't currently hold an NFT (vaultTokenId==0),
     *         we accept this as our main position. We then mint shares to the sender
     *         proportional to the position's liquidity or value. 
     *         If the vault already holds an NFT, you could either revert or 
     *         attempt merging (not shown here).
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata /* data */
    ) external override nonReentrant whenNotPaused returns (bytes4) {
        require(msg.sender == address(positionManager), "Vault: not from NFPM");

        // If the vault does not hold any position yet, accept this as the new position
        require(vaultTokenId == 0, "Vault: position already exists");
        vaultTokenId = tokenId;

        // Read position liquidity to compute how many shares to mint
        (
            /* nonce */,
            /* operator */,
            /* token0 */,
            /* token1 */,
            /* fee */,
            /* tickLower */,
            /* tickUpper */,
            uint128 liquidity,
            /* feeGrowthInside0LastX128 */,
            /* feeGrowthInside1LastX128 */,
            /* tokensOwed0 */,
            /* tokensOwed1 */
        ) = positionManager.positions(tokenId);

        // Compute shares minted. For simplicity, 1 share = 1 unit of liquidity or
        // you can do a more advanced approach using oracles, partial decimals, etc.
        uint256 mintedShares = uint256(liquidity);

        // Update totalUnderlying if you track it in some manner
        totalUnderlying += mintedShares;

        // Mint shares to 'from'
        _mint(from, mintedShares);

        emit PositionReceived(from, tokenId, liquidity, mintedShares);
        return this.onERC721Received.selector;
    }

    /**
     * @notice Allows a user to deposit token0/token1 into the existing position.
     *         The user must have sent tokens to this vault in advance or must have 
     *         set allowance on the positionManager. Implementation detail can vary.
     *
     *         This function calls increaseLiquidity on the vault's NFT, 
     *         computing the minted shares based on the new liquidity gained.
     *
     * @param amount0Desired   The amount of token0 the user wants to add
     * @param amount1Desired   The amount of token1 the user wants to add
     * @param amount0Min       The minimum amount0 accepted
     * @param amount1Min       The minimum amount1 accepted
     * @param tickLower        The current or new tickLower if re-ranging 
     * @param tickUpper        The current or new tickUpper
     * @param deadline         The tx deadline for safety
     */
    function deposit(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        int24 tickLower,
        int24 tickUpper,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        require(vaultTokenId != 0, "Vault: no NFT in vault");
        require(amount0Desired > 0 || amount1Desired > 0, "Vault: nothing to deposit");

        // Before calling increaseLiquidity, user must have transferred token0, token1 
        // to the vault or the vault must hold allowance for them. 
        // Implementation detail can vary. This code snippet doesn't handle actual ERC20 pulls.

        // read old liquidity
        (, , , , , int24 oldTickLower, int24 oldTickUpper, uint128 oldLiquidity, , , , ) =
            positionManager.positions(vaultTokenId);

        // If the user attempts to deposit outside the existing tick range, 
        // we can allow it or revert. For simplicity, we require the user matches the existing range:
        require(tickLower == oldTickLower && tickUpper == oldTickUpper, "Vault: must match current range");

        uint128 addedLiquidity;
        uint256 used0;
        uint256 used1;

        // Actually call increaseLiquidity
        {
            INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: vaultTokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                tickLower: tickLower,
                tickUpper: tickUpper,
                deadline: deadline
            });

            (addedLiquidity, used0, used1) = positionManager.increaseLiquidity(params);
        }

        // mintedShares ~ addedLiquidity (simple approach)
        uint256 mintedShares = uint256(addedLiquidity);
        // update totalUnderlying
        totalUnderlying += mintedShares;

        // mint shares to the caller
        _mint(msg.sender, mintedShares);

        emit Deposited(msg.sender, used0, used1, addedLiquidity, mintedShares);
    }

    /**
     * @notice Allows a user to withdraw a portion of the vault's liquidity by burning shares.
     *         This calls decreaseLiquidity on the vault's NFT, collecting the tokens for the user.
     *
     * @param sharesToBurn    The amount of vault shares the user wants to redeem
     * @param liquidityPctBps The % of user's portion in basis points to remove from the NFT
     *                        e.g. 10000 = 100%, 5000 = 50%
     * @param amount0Min      The minimum amount0 accepted
     * @param amount1Min      The minimum amount1 accepted
     * @param deadline        The tx deadline
     */
    function withdraw(
        uint256 sharesToBurn,
        uint256 liquidityPctBps,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        require(vaultTokenId != 0, "Vault: no NFT in vault");
        require(sharesToBurn > 0, "Vault: sharesToBurn=0");
        require(balanceOf(msg.sender) >= sharesToBurn, "Vault: insufficient shares");
        require(liquidityPctBps > 0 && liquidityPctBps <= 10000, "Vault: invalid liquidityPctBps");

        // burn the shares from caller
        _burn(msg.sender, sharesToBurn);

        // update totalUnderlying
        totalUnderlying = (totalUnderlying >= sharesToBurn) ? totalUnderlying - sharesToBurn : 0;

        // compute how much liquidity this represents
        // read current position liquidity
        (, , , , , , , uint128 currentLiquidity, , , , ) = positionManager.positions(vaultTokenId);
        // the portion we remove is (currentLiquidity * sharesToBurn / totalSupply) * liquidityPctBps / 10000
        // but for simplicity, we do a direct approach: user has shares => fraction of totalUnderlying => fraction of liquidity
        uint256 _totalSupply = totalSupply() + sharesToBurn; // total supply before we burned
        uint128 liquidityToRemove = uint128((uint256(currentLiquidity) * sharesToBurn * liquidityPctBps) / (_totalSupply * 10000));
        if (liquidityToRemove == 0) {
            // user is redeeming too small portion or no liquidity is left
            emit Withdrawn(msg.sender, 0, 0, 0, sharesToBurn);
            return;
        }

        // actually call decreaseLiquidity
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: vaultTokenId,
            liquidity: liquidityToRemove,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            deadline: deadline
        });

        (uint256 removed0, uint256 removed1) = positionManager.decreaseLiquidity(params);

        // collect tokens to user
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: vaultTokenId,
            recipient: msg.sender,
            amount0Max: uint128(removed0),
            amount1Max: uint128(removed1)
        });
        (uint256 col0, uint256 col1) = positionManager.collect(collectParams);

        emit Withdrawn(msg.sender, liquidityToRemove, col0, col1, sharesToBurn);
    }

    /**
     * @notice If you want to allow a full NFT withdrawal, letting a single user remove the entire position,
     *         you can implement a function that requires the caller to hold all shares (or enough).
     */
    function withdrawNFT(address to) external nonReentrant whenNotPaused {
        require(to != address(0), "Vault: invalid address");
        require(vaultTokenId != 0, "Vault: no NFT in vault");
        // require user to hold entire supply
        require(balanceOf(msg.sender) == totalSupply(), "Vault: must hold all shares");

        uint256 tokenId = vaultTokenId;
        vaultTokenId = 0;
        totalUnderlying = 0;

        // burn all shares
        _burn(msg.sender, totalSupply());

        // transfer NFT
        positionManager.safeTransferFrom(address(this), to, tokenId);

        emit NFTWithdrawn(to, tokenId);
    }

    /**
     * @notice Trigger rebalancing in the Rebalancer contract. 
     *         The Rebalancer can remove/add liquidity or shift ticks. 
     *         The Vault must have approved Rebalancer to manage the NFT.
     */
    function rebalanceVault(bytes calldata data) external whenNotPaused {
        rebalancer.rebalance(address(this), data);
        emit VaultRebalanced(data);
    }

    /**
     * @notice Trigger a liquidation in the Liquidator contract if a user is undercollateralized. 
     *         The Liquidator calls seizeShares(...) if conditions are met.
     */
    function liquidatePosition(address user, bytes calldata data) external whenNotPaused {
        liquidator.liquidate(address(this), user, data);
        emit VaultLiquidated(user, data);
    }

    /**
     * @notice Called by the Liquidator to forcibly remove shares from an undercollateralized user.
     *         Implementation detail: we simply burn them here. A more advanced design might keep
     *         seized shares or allocate them to the liquidator, etc.
     */
    function seizeShares(address from, uint256 shares) external {
        require(msg.sender == address(liquidator), "Vault: only Liquidator");
        require(balanceOf(from) >= shares, "Vault: user does not have enough shares");

        _burn(from, shares);
        totalUnderlying = (totalUnderlying >= shares) ? totalUnderlying - shares : 0;

        emit SharesSeized(from, shares);
    }

    /**
     * @notice Exposes a method to get the current "price" or "value" from the OracleManager. 
     *         In a real system, you'd compute an LP token value using position amounts, 
     *         but we keep it simplified. External Rebalancer or Liquidator can call this 
     *         to get some approximate measure.
     */
    function getUnderlyingPrice() external view returns (uint256 price, uint8 decimals) {
        // For demonstration, we simply call a standard getPrice from oracleManager, 
        // passing the vault's v3Pool as the "token" key. 
        // A specialized aggregator must exist or code that calculates the total position's 
        // token0/token1 amounts at current price. 
        // This is a simplified approach. 
        return oracleManager.getPrice(v3Pool);
    }

    /**
     * @dev The UUPS pattern: only the owner can authorize an upgrade. 
     *      This is already enforced by _authorizeUpgrade() => onlyOwner.
     */

    /**
     * @dev Required by IERC721Receiver for safeTransferFrom. 
     *      Implementation is at the top (onERC721Received).
     */

    receive() external payable {}
}
