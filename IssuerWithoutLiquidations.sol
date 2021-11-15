pragma solidity ^0.5.16;

// Internal references
import "./Issuer.sol";

contract IssuerWithoutLiquidations is Issuer {
    constructor(address _owner, address _resolver) public Issuer(_owner, _resolver) {}

    function liquidateDelinquentAccount(
        address account,
        uint ousdAmount,
        address liquidator
    ) external onlyOrganix returns (uint totalRedeemed, uint amountToLiquidate) {}
}
