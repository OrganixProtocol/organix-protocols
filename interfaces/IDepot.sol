pragma solidity >=0.4.24;

interface IDepot {
    // Views
    function fundsWallet() external view returns (address payable);

    function maxBNBPurchase() external view returns (uint);

    function minimumDepositAmount() external view returns (uint);

    function synthsReceivedForBNB(uint amount) external view returns (uint);

    function totalSellableDeposits() external view returns (uint);

    // Mutative functions
    function depositSynths(uint amount) external;

    function exchangeBNBForSynths() external payable returns (uint);

    function exchangeBNBForSynthsAtRate(uint guaranteedRate) external payable returns (uint);

    function withdrawMyDepositedSynths() external;

    // Note: On mainnet no OGX has been deposited. The following functions are kept alive for testnet OGX faucets.
    function exchangeBNBForOGX() external payable returns (uint);

    function exchangeBNBForOGXAtRate(uint guaranteedRate, uint guaranteedOrganixRate) external payable returns (uint);

    function exchangeSynthsForOGX(uint synthAmount) external returns (uint);

    function organixReceivedForBNB(uint amount) external view returns (uint);

    function organixReceivedForSynths(uint amount) external view returns (uint);

    function withdrawOrganix(uint amount) external;
}
