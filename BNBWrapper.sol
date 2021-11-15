pragma solidity ^0.5.16;

// Inheritance
import "./Owned.sol";
import "./interfaces/IAddressResolver.sol";
import "./interfaces/IBNBWrapper.sol";
import "./interfaces/ISynth.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IWBNB.sol";

// Internal references
import "./Pausable.sol";
import "./interfaces/IIssuer.sol";
import "./interfaces/IExchangeRates.sol";
import "./interfaces/IFeePool.sol";
import "./MixinResolver.sol";
import "./MixinSystemSettings.sol";

// Libraries
import "./lib/SafeMath.sol";
import "./SafeDecimalMath.sol";

contract BNBWrapper is Owned, Pausable, MixinResolver, MixinSystemSettings, IBNBWrapper {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    /* ========== CONSTANTS ============== */

    /* ========== ENCODED NAMES ========== */

    bytes32 internal constant oUSD = "oUSD";
    bytes32 internal constant oBNB = "oBNB";
    bytes32 internal constant BNB = "BNB";
    bytes32 internal constant OGX = "OGX";

    /* ========== ADDRESS RESOLVER CONFIGURATION ========== */
    bytes32 private constant CONTRACT_SYNTHOBNB = "SynthoBNB";
    bytes32 private constant CONTRACT_SYNTHOUSD = "SynthoUSD";
    bytes32 private constant CONTRACT_ISSUER = "Issuer";
    bytes32 private constant CONTRACT_EXRATES = "ExchangeRates";
    bytes32 private constant CONTRACT_FEEPOOL = "FeePool";

    // ========== STATE VARIABLES ==========
    IWBNB internal _wbnb;

    uint public oBNBIssued = 0;
    uint public oUSDIssued = 0;
    uint public feesEscrowed = 0;

    constructor(
        address _owner,
        address _resolver,
        address payable _WBNB
    ) public Owned(_owner) Pausable() MixinSystemSettings(_resolver) {
        _wbnb = IWBNB(_WBNB);
    }

    /* ========== VIEWS ========== */
    function resolverAddressesRequired() public view returns (bytes32[] memory addresses) {
        bytes32[] memory existingAddresses = MixinSystemSettings.resolverAddressesRequired();
        bytes32[] memory newAddresses = new bytes32[](5);
        newAddresses[0] = CONTRACT_SYNTHOBNB;
        newAddresses[1] = CONTRACT_SYNTHOUSD;
        newAddresses[2] = CONTRACT_EXRATES;
        newAddresses[3] = CONTRACT_ISSUER;
        newAddresses[4] = CONTRACT_FEEPOOL;
        addresses = combineArrays(existingAddresses, newAddresses);
        return addresses;
    }

    /* ========== INTERNAL VIEWS ========== */
    function synthoUSD() internal view returns (ISynth) {
        return ISynth(requireAndGetAddress(CONTRACT_SYNTHOUSD));
    }

    function synthoBNB() internal view returns (ISynth) {
        return ISynth(requireAndGetAddress(CONTRACT_SYNTHOBNB));
    }

    function feePool() internal view returns (IFeePool) {
        return IFeePool(requireAndGetAddress(CONTRACT_FEEPOOL));
    }

    function exchangeRates() internal view returns (IExchangeRates) {
        return IExchangeRates(requireAndGetAddress(CONTRACT_EXRATES));
    }

    function issuer() internal view returns (IIssuer) {
        return IIssuer(requireAndGetAddress(CONTRACT_ISSUER));
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    // ========== VIEWS ==========

    function capacity() public view returns (uint _capacity) {
        // capacity = max(maxBNB - balance, 0)
        uint balance = getReserves();
        if (balance >= maxBNB()) {
            return 0;
        }
        return maxBNB().sub(balance);
    }

    function getReserves() public view returns (uint) {
        return _wbnb.balanceOf(address(this));
    }

    function totalIssuedSynths() public view returns (uint) {
        // This contract issues two different synths:
        // 1. oBNB
        // 2. oUSD
        //
        // The oBNB is always backed 1:1 with WBNB.
        // The oUSD fees are backed by oBNB that is withheld during minting and burning.
        return exchangeRates().effectiveValue(oBNB, oBNBIssued, oUSD).add(oUSDIssued);
    }

    function calculateMintFee(uint amount) public view returns (uint) {
        return amount.multiplyDecimalRound(mintFeeRate());
    }

    function calculateBurnFee(uint amount) public view returns (uint) {
        return amount.multiplyDecimalRound(burnFeeRate());
    }

    function maxBNB() public view returns (uint256) {
        return getBNBWrapperMaxBNB();
    }

    function mintFeeRate() public view returns (uint256) {
        return getBNBWrapperMintFeeRate();
    }

    function burnFeeRate() public view returns (uint256) {
        return getBNBWrapperBurnFeeRate();
    }

    function wbnb() public view returns (IWBNB) {
        return _wbnb;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    // Transfers `amountIn` WBNB to mint `amountIn - fees` oBNB.
    // `amountIn` is inclusive of fees, calculable via `calculateMintFee`.
    function mint(uint amountIn) external notPaused {
        require(amountIn <= _wbnb.allowance(msg.sender, address(this)), "Allowance not high enough");
        require(amountIn <= _wbnb.balanceOf(msg.sender), "Balance is too low");

        uint currentCapacity = capacity();
        require(currentCapacity > 0, "Contract has no spare capacity to mint");

        if (amountIn < currentCapacity) {
            _mint(amountIn);
        } else {
            _mint(currentCapacity);
        }
    }

    // Burns `amountIn` oBNB for `amountIn - fees` WBNB.
    // `amountIn` is inclusive of fees, calculable via `calculateBurnFee`.
    function burn(uint amountIn) external notPaused {
        uint reserves = getReserves();
        require(reserves > 0, "Contract cannot burn oBNB for WBNB, WBNB balance is zero");

        // principal = [amountIn / (1 + burnFeeRate)]
        uint principal = amountIn.divideDecimalRound(SafeDecimalMath.unit().add(burnFeeRate()));

        if (principal < reserves) {
            _burn(principal, amountIn);
        } else {
            _burn(reserves, reserves.add(calculateBurnFee(reserves)));
        }
    }

    function distributeFees() external {
        // Normalize fee to oUSD
        require(!exchangeRates().rateIsInvalid(oBNB), "Currency rate is invalid");
        uint amountOUSD = exchangeRates().effectiveValue(oBNB, feesEscrowed, oUSD);

        // Burn oBNB.
        synthoBNB().burn(address(this), feesEscrowed);
        // Pay down as much oBNB debt as we burn. Any other debt is taken on by the stakers.
        oBNBIssued = oBNBIssued < feesEscrowed ? 0 : oBNBIssued.sub(feesEscrowed);

        // Issue oUSD to the fee pool
        issuer().synths(oUSD).issue(feePool().FEE_ADDRESS(), amountOUSD);
        oUSDIssued = oUSDIssued.add(amountOUSD);

        // Tell the fee pool about this
        feePool().recordFeePaid(amountOUSD);

        feesEscrowed = 0;
    }

    // ========== RESTRICTED ==========

    /**
     * @notice Fallback function
     */
    function() external payable {
        revert("Fallback disabled, use mint()");
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _mint(uint amountIn) internal {
        // Calculate minting fee.
        uint feeAmountBNB = calculateMintFee(amountIn);
        uint principal = amountIn.sub(feeAmountBNB);

        // Transfer WBNB from user.
        _wbnb.transferFrom(msg.sender, address(this), amountIn);

        // Mint `amountIn - fees` oBNB to user.
        synthoBNB().issue(msg.sender, principal);

        // Escrow fee.
        synthoBNB().issue(address(this), feeAmountBNB);
        feesEscrowed = feesEscrowed.add(feeAmountBNB);

        // Add oBNB debt.
        oBNBIssued = oBNBIssued.add(amountIn);

        emit Minted(msg.sender, principal, feeAmountBNB, amountIn);
    }

    function _burn(uint principal, uint amountIn) internal {
        // for burn, amount is inclusive of the fee.
        uint feeAmountBNB = amountIn.sub(principal);

        require(amountIn <= IERC20(address(synthoBNB())).allowance(msg.sender, address(this)), "Allowance not high enough");
        require(amountIn <= IERC20(address(synthoBNB())).balanceOf(msg.sender), "Balance is too low");

        // Burn `amountIn` oBNB from user.
        synthoBNB().burn(msg.sender, amountIn);
        // oBNB debt is repaid by burning.
        oBNBIssued = oBNBIssued < principal ? 0 : oBNBIssued.sub(principal);

        // We use burn/issue instead of burning the principal and transferring the fee.
        // This saves an approval and is cheaper.
        // Escrow fee.
        synthoBNB().issue(address(this), feeAmountBNB);
        // We don't update oBNBIssued, as only the principal was subtracted earlier.
        feesEscrowed = feesEscrowed.add(feeAmountBNB);

        // Transfer `amount - fees` WBNB to user.
        _wbnb.transfer(msg.sender, principal);

        emit Burned(msg.sender, principal, feeAmountBNB, amountIn);
    }

    /* ========== EVENTS ========== */
    event Minted(address indexed account, uint principal, uint fee, uint amountIn);
    event Burned(address indexed account, uint principal, uint fee, uint amountIn);
}
