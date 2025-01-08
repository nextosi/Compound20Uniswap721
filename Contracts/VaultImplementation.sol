// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// ------------------ OpenZeppelin Upgradeable ------------------
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// ------------------ Uniswap V3 ------------------
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

// ------------------ Aliased Local Contracts ------------------
import { OracleManager as OracleManagerType } from "./OracleManager.sol";
import { Rebalancer as RebalancerType } from "./Rebalancer.sol";
import { Liquidator as LiquidatorType } from "./Liquidator.sol";

/**
 * @title VaultImplementation
 * @notice A UUPS-upgradeable vault that manages a single Uniswap V3 position NFT,
 *         references a Rebalancer, Liquidator, OracleManager, and issues ERC20 shares.
 *
 *         We fix the "Stack too deep" error in withdraw(...) by grouping local variables
 *         into a struct. This reduces the compiler's local variable count.
 */
contract VaultImplementation is
    ERC20Upgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IERC721Receiver
{
    // ------------------ State ------------------

    address public v3Pool;
    INonfungiblePositionManager public positionManager;
    uint256 public vaultTokenId;

    OracleManagerType public oracleManager;
    RebalancerType public rebalancer;
    LiquidatorType public liquidator;

    // ------------------ Events ------------------

    event ExternalContractsUpdated(
        address indexed oracleManager,
        address indexed rebalancer,
        address indexed liquidator
    );

    event PositionReceived(
        address from,
        uint256 tokenId
    );

    event Deposited(
        address indexed user,
        uint256 usedToken0,
        uint256 usedToken1,
        uint256 mintedShares,
        uint256 depositValue
    );

    /**
     * @dev Grouping withdraw event arguments in line with function changes
     */
    event Withdrawn(
        address indexed user,
        uint128 liquidityRemoved,
        uint256 amount0Out,
        uint256 amount1Out,
        uint256 sharesBurned
    );

    event NFTWithdrawn(
        address to, 
        uint256 tokenId
    );

    event VaultRebalanced(bytes data);
    event VaultLiquidated(address user, bytes data);
    event SharesSeized(address user, uint256 shares, address recipient);

    // ------------------ UUPS ------------------
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ------------------ Initialization ------------------

    /**
     * @notice Initialization behind a proxy.
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
        // If your local Ownable requires an address param:
        __Ownable_init(_owner);

        __ERC20_init(_name, _symbol);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        require(_v3Pool != address(0), "Vault: invalid v3Pool");
        require(_positionManager != address(0), "Vault: invalid positionMgr");
        require(_oracleMgr != address(0), "Vault: invalid oracle");
        require(_rebalancer != address(0), "Vault: invalid rebalancer");
        require(_liquidator != address(0), "Vault: invalid liquidator");

        v3Pool = _v3Pool;
        positionManager = INonfungiblePositionManager(_positionManager);
        oracleManager = OracleManagerType(_oracleMgr);
        rebalancer = RebalancerType(_rebalancer);
        liquidator = LiquidatorType(_liquidator);

        _transferOwnership(_owner);

        emit ExternalContractsUpdated(_oracleMgr, _rebalancer, _liquidator);
    }

    // ------------------ External References ------------------
    function setExternalContracts(
        address _oracleMgr,
        address _rebalancer,
        address _liquidator
    ) external onlyOwner {
        require(_oracleMgr != address(0), "Vault: invalid oracle");
        require(_rebalancer != address(0), "Vault: invalid rebalancer");
        require(_liquidator != address(0), "Vault: invalid liquidator");

        oracleManager = OracleManagerType(_oracleMgr);
        rebalancer = RebalancerType(_rebalancer);
        liquidator = LiquidatorType(_liquidator);

        emit ExternalContractsUpdated(_oracleMgr, _rebalancer, _liquidator);
    }

    // ------------------ Pausing ------------------

    function pauseVault() external onlyOwner {
        _pause();
    }

    function unpauseVault() external onlyOwner {
        _unpause();
    }

    // ------------------ NFT Handling (Single onERC721Received) ------------------

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata /* data */
    ) external override(IERC721Receiver) nonReentrant whenNotPaused returns (bytes4) {
        require(msg.sender == address(positionManager), "Vault: not from NFPM");
        require(vaultTokenId == 0, "Vault: position already exists");

        vaultTokenId = tokenId;
        emit PositionReceived(from, tokenId);
        return this.onERC721Received.selector;
    }

    // ------------------ Example Deposit (6-field IncreaseLiquidity) ------------------

    function deposit(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        require(vaultTokenId != 0, "Vault: no NFT in vault");
        require(amount0Desired > 0 || amount1Desired > 0, "Vault: no deposit amounts");

        uint256 oldVaultValue = _getVaultValue();
        uint256 oldSupply = totalSupply();

        INonfungiblePositionManager.IncreaseLiquidityParams memory params =
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: vaultTokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            });

        (uint128 addedLiquidity, uint256 used0, uint256 used1) = positionManager.increaseLiquidity(params);

        uint256 newVaultValue = _getVaultValue();
        uint256 depositValue = (oldVaultValue == 0)
            ? newVaultValue
            : (newVaultValue > oldVaultValue ? (newVaultValue - oldVaultValue) : 0);

        uint256 mintedShares;
        if (oldSupply == 0) {
            mintedShares = depositValue;
        } else {
            mintedShares = (depositValue * oldSupply) / (oldVaultValue == 0 ? 1 : oldVaultValue);
        }

        if (mintedShares > 0) {
            _mint(msg.sender, mintedShares);
        }

        emit Deposited(msg.sender, used0, used1, mintedShares, depositValue);
    }

    // ------------------ Stack-Too-Deep Fix for Withdraw ------------------

    /**
     * @dev We group local variables for withdraw(...) in a struct to avoid 'Stack too deep'.
     */
    struct WithdrawVars {
        uint256 oldSupply;
        uint128 liquidityToRemove;
        uint256 removed0;
        uint256 removed1;
        uint256 col0;
        uint256 col1;
    }

    /**
     * @notice Allows user to burn shares, remove partial liquidity, collect tokens, 
     *         returning them to the user. 
     */
    function withdraw(
        uint256 sharesToBurn,
        uint256 liquidityPctBps,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external nonReentrant whenNotPaused {
        require(vaultTokenId != 0, "Vault: no NFT");
        require(sharesToBurn > 0, "Vault: zero shares");
        require(balanceOf(msg.sender) >= sharesToBurn, "Vault: insufficient shares");
        require(liquidityPctBps > 0 && liquidityPctBps <= 10000, "Vault: invalid bps");

        _burn(msg.sender, sharesToBurn);

        WithdrawVars memory wv; // local struct
        {
            (, , , , , , , uint128 currentLiquidity, , , , ) = positionManager.positions(vaultTokenId);
            wv.oldSupply = totalSupply() + sharesToBurn;
            wv.liquidityToRemove = uint128(
                (uint256(currentLiquidity) * sharesToBurn * liquidityPctBps) / (wv.oldSupply * 10000)
            );
        }

        if (wv.liquidityToRemove == 0) {
            emit Withdrawn(msg.sender, 0, 0, 0, sharesToBurn);
            return;
        }

        INonfungiblePositionManager.DecreaseLiquidityParams memory params =
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: vaultTokenId,
                liquidity: wv.liquidityToRemove,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            });

        (wv.removed0, wv.removed1) = positionManager.decreaseLiquidity(params);

        INonfungiblePositionManager.CollectParams memory collectParams =
            INonfungiblePositionManager.CollectParams({
                tokenId: vaultTokenId,
                recipient: msg.sender,
                amount0Max: uint128(wv.removed0),
                amount1Max: uint128(wv.removed1)
            });
        (wv.col0, wv.col1) = positionManager.collect(collectParams);

        emit Withdrawn(msg.sender, wv.liquidityToRemove, wv.col0, wv.col1, sharesToBurn);
    }

    function withdrawNFT(address to) external nonReentrant whenNotPaused {
        require(to != address(0), "Vault: invalid to");
        require(vaultTokenId != 0, "Vault: no NFT");
        require(balanceOf(msg.sender) == totalSupply(), "Vault: must hold all shares");

        uint256 tokenId = vaultTokenId;
        vaultTokenId = 0;
        _burn(msg.sender, totalSupply());

        positionManager.safeTransferFrom(address(this), to, tokenId);
        emit NFTWithdrawn(to, tokenId);
    }

    // ------------------ Rebalancer / Liquidator Calls ------------------

    function rebalanceVault(bytes calldata data) external whenNotPaused {
        rebalancer.rebalance(address(this), data);
        emit VaultRebalanced(data);
    }

    function liquidatePosition(address user, bytes calldata data) external whenNotPaused {
        // decode into a uint256 if needed
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

    // ------------------ Oracle-based Price Queries ------------------

    function getUnderlyingPrice() external view returns (uint256 price, uint8 decimals) {
        return oracleManager.getPrice(address(this));
    }

    function _getVaultValue() internal view returns (uint256) {
        (uint256 p, ) = oracleManager.getPrice(address(this));
        return p;
    }

    // ------------------ End ------------------

    receive() external payable {}
}
