pragma solidity ^0.5.16;

// Inheritance
import "./interfaces/ISynth.sol";
import "./interfaces/IOrganix.sol";
import "./interfaces/IExchangeRates.sol";
import "./interfaces/IAddressResolver.sol";
import "./interfaces/IERC20.sol";

contract SynthUtil {
    IAddressResolver public addressResolverProxy;

    bytes32 internal constant CONTRACT_ORGANIX = "Organix";
    bytes32 internal constant CONTRACT_EXRATES = "ExchangeRates";
    bytes32 internal constant OUSD = "oUSD";

    constructor(address resolver) public {
        addressResolverProxy = IAddressResolver(resolver);
    }

    function _organix() internal view returns (IOrganix) {
        return IOrganix(addressResolverProxy.requireAndGetAddress(CONTRACT_ORGANIX, "Missing Organix address"));
    }

    function _exchangeRates() internal view returns (IExchangeRates) {
        return IExchangeRates(addressResolverProxy.requireAndGetAddress(CONTRACT_EXRATES, "Missing ExchangeRates address"));
    }

    function totalSynthsInKey(address account, bytes32 currencyKey) external view returns (uint total) {
        IOrganix organix = _organix();
        IExchangeRates exchangeRates = _exchangeRates();
        uint numSynths = organix.availableSynthCount();
        for (uint i = 0; i < numSynths; i++) {
            ISynth synth = organix.availableSynths(i);
            total += exchangeRates.effectiveValue(
                synth.currencyKey(),
                IERC20(address(synth)).balanceOf(account),
                currencyKey
            );
        }
        return total;
    }

    function synthsBalances(address account)
        external
        view
        returns (
            bytes32[] memory,
            uint[] memory,
            uint[] memory
        )
    {
        IOrganix organix = _organix();
        IExchangeRates exchangeRates = _exchangeRates();
        uint numSynths = organix.availableSynthCount();
        bytes32[] memory currencyKeys = new bytes32[](numSynths);
        uint[] memory balances = new uint[](numSynths);
        uint[] memory oUSDBalances = new uint[](numSynths);
        for (uint i = 0; i < numSynths; i++) {
            ISynth synth = organix.availableSynths(i);
            currencyKeys[i] = synth.currencyKey();
            balances[i] = IERC20(address(synth)).balanceOf(account);
            oUSDBalances[i] = exchangeRates.effectiveValue(currencyKeys[i], balances[i], OUSD);
        }
        return (currencyKeys, balances, oUSDBalances);
    }

    function frozenSynths() external view returns (bytes32[] memory) {
        IOrganix organix = _organix();
        IExchangeRates exchangeRates = _exchangeRates();
        uint numSynths = organix.availableSynthCount();
        bytes32[] memory frozenSynthsKeys = new bytes32[](numSynths);
        for (uint i = 0; i < numSynths; i++) {
            ISynth synth = organix.availableSynths(i);
            if (exchangeRates.rateIsFrozen(synth.currencyKey())) {
                frozenSynthsKeys[i] = synth.currencyKey();
            }
        }
        return frozenSynthsKeys;
    }

    function synthsRates() external view returns (bytes32[] memory, uint[] memory) {
        bytes32[] memory currencyKeys = _organix().availableCurrencyKeys();
        return (currencyKeys, _exchangeRates().ratesForCurrencies(currencyKeys));
    }

    function synthsTotalSupplies()
        external
        view
        returns (
            bytes32[] memory,
            uint256[] memory,
            uint256[] memory
        )
    {
        IOrganix organix = _organix();
        IExchangeRates exchangeRates = _exchangeRates();

        uint256 numSynths = organix.availableSynthCount();
        bytes32[] memory currencyKeys = new bytes32[](numSynths);
        uint256[] memory balances = new uint256[](numSynths);
        uint256[] memory oUSDBalances = new uint256[](numSynths);
        for (uint256 i = 0; i < numSynths; i++) {
            ISynth synth = organix.availableSynths(i);
            currencyKeys[i] = synth.currencyKey();
            balances[i] = IERC20(address(synth)).totalSupply();
            oUSDBalances[i] = exchangeRates.effectiveValue(currencyKeys[i], balances[i], OUSD);
        }
        return (currencyKeys, balances, oUSDBalances);
    }
}
