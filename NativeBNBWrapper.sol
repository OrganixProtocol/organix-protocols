// @unsupported: ovm
pragma solidity ^0.5.16;

// Inheritance
import "./Owned.sol";
import "./interfaces/IAddressResolver.sol";
import "./interfaces/IBNBWrapper.sol";
import "./interfaces/ISynth.sol";
import "./interfaces/IWBNB.sol";
import "./interfaces/IERC20.sol";

// Internal references
import "./MixinResolver.sol";
import "./interfaces/IBNBWrapper.sol";

contract NativeBNBWrapper is Owned, MixinResolver {
    bytes32 private constant CONTRACT_BNB_WRAPPER = "BNBWrapper";
    bytes32 private constant CONTRACT_SYNTHOBNB = "SynthoBNB";

    constructor(address _owner, address _resolver) public Owned(_owner) MixinResolver(_resolver) {}

    /* ========== PUBLIC FUNCTIONS ========== */

    /* ========== VIEWS ========== */
    function resolverAddressesRequired() public view returns (bytes32[] memory addresses) {
        bytes32[] memory addresses = new bytes32[](2);
        addresses[0] = CONTRACT_BNB_WRAPPER;
        addresses[1] = CONTRACT_SYNTHOBNB;
        return addresses;
    }

    function BNBWrapper() internal view returns (IBNBWrapper) {
        return IBNBWrapper(requireAndGetAddress(CONTRACT_BNB_WRAPPER));
    }

    function wbnb() internal view returns (IWBNB) {
        return BNBWrapper().wbnb();
    }

    function synthoBNB() internal view returns (IERC20) {
        return IERC20(requireAndGetAddress(CONTRACT_SYNTHOBNB));
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function mint() public payable {
        uint amount = msg.value;
        require(amount > 0, "msg.value must be greater than 0");

        // Convert sent BNB into WBNB.
        wbnb().deposit.value(amount)();

        // Approve for the BNBWrapper.
        wbnb().approve(address(BNBWrapper()), amount);

        // Now call mint.
        BNBWrapper().mint(amount);

        // Transfer the oBNB to msg.sender.
        synthoBNB().transfer(msg.sender, synthoBNB().balanceOf(address(this)));

        emit Minted(msg.sender, amount);
    }

    function burn(uint amount) public {
        require(amount > 0, "amount must be greater than 0");
        IWBNB wbnb = wbnb();

        // Transfer oBNB from the msg.sender.
        synthoBNB().transferFrom(msg.sender, address(this), amount);

        // Approve for the BNBWrapper.
        synthoBNB().approve(address(BNBWrapper()), amount);

        // Now call burn.
        BNBWrapper().burn(amount);

        // Convert WBNB to BNB and send to msg.sender.
        wbnb.withdraw(wbnb.balanceOf(address(this)));
        // solhint-disable avoid-low-level-calls
        msg.sender.call.value(address(this).balance)("");

        emit Burned(msg.sender, amount);
    }

    function() external payable {
        // Allow the WBNB contract to send us BNB during
        // our call to WBNB.deposit. The gas stipend it gives
        // is 2300 gas, so it's not possible to do much else here.
    }

    /* ========== EVENTS ========== */
    // While these events are replicated in the core BNBWrapper,
    // it is useful to see the usage of the NativeBNBWrapper contract.
    event Minted(address indexed account, uint amount);
    event Burned(address indexed account, uint amount);
}
