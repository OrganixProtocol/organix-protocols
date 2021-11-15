pragma solidity >=0.4.24;

import "./IWBNB.sol";

contract IBNBWrapper {
    function mint(uint amount) external;

    function burn(uint amount) external;

    function distributeFees() external;

    function capacity() external view returns (uint);

    function getReserves() external view returns (uint);

    function totalIssuedSynths() external view returns (uint);

    function calculateMintFee(uint amount) public view returns (uint);

    function calculateBurnFee(uint amount) public view returns (uint);

    function maxBNB() public view returns (uint256);

    function mintFeeRate() public view returns (uint256);

    function burnFeeRate() public view returns (uint256);

    function wbnb() public view returns (IWBNB);
}
