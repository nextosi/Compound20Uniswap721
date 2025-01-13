// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/**
 * @dev Minimal interfaces to check if an NFT matches the vault pool.
 */
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
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

interface ILocalUniswapV3Pool {
    function factory() external view returns (address);
}

interface ILocalUniswapV3FactorySimple {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/**
 * @title MinimalVaultImplementation
 * @notice A UUPS-upgradeable vault logic contract that:
 *         - Implements ERC20 shares via OZ upgradeable library.
 *         - Conditionally mints shares when an NFT is deposited:
 *             - If NFT matches `requiredPoolAddress`, mints SHARES_PER_NFT.
 *             - Otherwise, mints 0.
 *         - Burns those same shares to withdraw the NFT.
 *         - Exposes `requiredPool()` so the factory can call `depositNftForVault`.
 *
 *         This code is intentionally minimal for testing upgrades and deposits.
 */
contract MinimalVaultImplementation is 
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IERC721Receiver
{
    /// @dev The Uniswap V3 pool required by the factory.
    address public requiredPoolAddress;

    /// @dev For demonstration, we'll store but not deeply use these in this minimal example.
    address public positionManager;
    address public oracleManager;
    address public rebalancer;
    address public liquidator;

    /// @dev Fixed shares minted per valid NFT deposit.
    uint256 public constant SHARES_PER_NFT = 100 * 1e18;

    /// @dev Data we track for each NFT stored in the vault.
    struct NftData {
        address depositor;    // who originally deposited
        uint256 mintedShares; // how many shares we minted for it
        bool exists;
    }
    /// @dev tokenId => NftData
    mapping(uint256 => NftData) public nftRecords;

    /// @dev Event when an NFT is deposited but 0 shares minted (pool mismatch).
    event NftDepositedButNoShares(address indexed user, uint256 tokenId);

    /// @dev Event when an NFT is deposited with shares minted (pool match).
    event NftDeposited(address indexed user, uint256 tokenId, uint256 mintedShares);

    /**
     * @notice UUPS + OZ initializer function, called once by the proxy.
     * @param _v3Pool         The Uniswap V3 pool (required or optional usage).
     * @param _positionMgr    The NonfungiblePositionManager (optional usage).
     * @param _oracleMgr      The OracleManager (unused in minimal version).
     * @param _rebalancer     The Rebalancer (unused in minimal version).
     * @param _liquidator     The Liquidator (unused in minimal version).
     * @param _owner          The owner of this vault (set via Ownable).
     * @param _name           The ERC20 name for vault shares.
     * @param _symbol         The ERC20 symbol for vault shares.
     */
    function initialize(
        address _v3Pool,
        address _positionMgr,
        address _oracleMgr,
        address _rebalancer,
        address _liquidator,
        address _owner,
        string memory _name,
        string memory _symbol
    )
        external
        initializer
    {
        // Some older OZ versions require an argument in Ownable_init:
        __Ownable_init(_owner);      
        __UUPSUpgradeable_init();
        __ERC20_init(_name, _symbol);

        // Store references
        requiredPoolAddress = _v3Pool;
        positionManager     = _positionMgr;
        oracleManager       = _oracleMgr;
        rebalancer          = _rebalancer;
        liquidator          = _liquidator;
    }

    /**
     * @notice UUPS authorization. Only owner can upgrade.
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}


    function requiredPool() external view returns (address) {
        return requiredPoolAddress;
    }

    /**
     * @notice onERC721Received so this contract can accept NFTs.
     *         - If NFT matches `requiredPoolAddress`, we mint SHARES_PER_NFT.
     *         - Otherwise, we mint 0 shares but do not revert.
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata
    ) 
        external 
        override
        returns (bytes4) 
    {
        // Avoid double deposit of the same token
        require(!nftRecords[tokenId].exists, "Already in vault");

        // Decide how many shares to mint
        bool poolOk = _checkPoolMatch(tokenId);
        uint256 mintedShares = poolOk ? SHARES_PER_NFT : 0;

        // Record NFT deposit
        nftRecords[tokenId] = NftData({
            depositor: from,
            mintedShares: mintedShares,
            exists: true
        });

        // If mintedShares == 0, we do not revert. 
        // Mint 0 => no effect, but doesn't revert either.
        _mint(from, mintedShares);

        // Emit events
        if (mintedShares == 0) {
            emit NftDepositedButNoShares(from, tokenId);
        } else {
            emit NftDeposited(from, tokenId, mintedShares);
        }

        // Return the required receiver signature
        return this.onERC721Received.selector;
    }

    /**
     * @notice Withdraw an NFT by burning the shares minted for it.
     * @param tokenId The NFT to withdraw.
     * @param nftContract The ERC721 contract address (e.g. Uniswap NFPM).
     */
    function withdrawNft(uint256 tokenId, address nftContract) external {
        NftData storage record = nftRecords[tokenId];
        require(record.exists, "NFT not in vault");

        // User must have at least mintedShares in their balance
        // (this is the "exact same amount" requirement to withdraw)
        require(balanceOf(msg.sender) >= record.mintedShares, "Not enough shares");

        // Burn the shares
        _burn(msg.sender, record.mintedShares);

        // Clear record
        record.exists = false;

        // Transfer NFT back
        IERC721(nftContract).safeTransferFrom(address(this), msg.sender, tokenId);
    }

    /**
     * @dev Checks if the NFT’s (token0, token1, fee) correspond to `requiredPoolAddress`.
     *      If any part is missing or mismatched, returns false => minted=0 shares.
     */
    function _checkPoolMatch(uint256 tokenId) internal view returns (bool) {
        if (requiredPoolAddress == address(0)) {
            // If no pool is set, treat everything as mismatch => 0 shares
            return false;
        }

        // 1) Read positions data from the NFPM
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
        ) = ILocalNonfungiblePositionManager(positionManager).positions(tokenId);

        // 2) Check if pool(token0, token1, fee) == requiredPoolAddress

        return (derivedPool == requiredPoolAddress);
    }
}
