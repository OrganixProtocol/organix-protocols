pragma solidity ^0.5.16;

// Stub functions required by the DebtCache and FeePool contracts.
contract EmptyBNBWrapper {
    constructor() public {}

    /* ========== VIEWS ========== */

    function totalIssuedSynths() public view returns (uint) {
        return 0;
    }

    function distributeFees() external {}
}
