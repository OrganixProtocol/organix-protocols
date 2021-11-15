pragma solidity >=0.4.24;

interface ISystemSettings {
    // Views
    function priceDeviationThresholdFactor() external view returns (uint);

    function waitingPeriodSecs() external view returns (uint);

    function issuanceRatio() external view returns (uint);

    function feePeriodDuration() external view returns (uint);

    function targetThreshold() external view returns (uint);

    function liquidationDelay() external view returns (uint);

    function liquidationRatio() external view returns (uint);

    function liquidationPenalty() external view returns (uint);

    function rateStalePeriod() external view returns (uint);

    function exchangeFeeRate(bytes32 currencyKey) external view returns (uint);

    function minimumStakeTime() external view returns (uint);

    function BNBWrapperMaxBNB() external view returns (uint);

    function BNBWrapperBurnFeeRate() external view returns (uint);

    function BNBWrapperMintFeeRate() external view returns (uint);

    function minCratio(address collateral) external view returns (uint);

    function collateralManager(address collateral) external view returns (address);

    function interactionDelay(address collateral) external view returns (uint);
}
