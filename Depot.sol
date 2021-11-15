pragma solidity ^0.5.16;

// Inheritance
import "./Owned.sol";
import "./Pausable.sol";
import "./lib/ReentrancyGuard.sol";
import "./MixinResolver.sol";
import "./interfaces/IDepot.sol";

// Libraries
import "./SafeDecimalMath.sol";

// Internal references
import "./interfaces/IERC20.sol";
import "./interfaces/IExchangeRates.sol";

contract Depot is Owned, Pausable, ReentrancyGuard, MixinResolver, IDepot {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    bytes32 internal constant OGX = "OGX";
    bytes32 internal constant BNB = "BNB";

    /* ========== STATE VARIABLES ========== */

    // Address where the BNB and Synths raised for selling OGX is transfered to
    // Any BNB raised for selling Synths gets sent back to whoever deposited the Synths,
    // and doesn't have anything to do with this address.
    address payable public fundsWallet;

    /* Stores deposits from users. */
    struct SynthDepositEntry {
        // The user that made the deposit
        address payable user;
        // The amount (in Synths) that they deposited
        uint amount;
    }

    /* User deposits are sold on a FIFO (First in First out) basis. When users deposit
       synths with us, they get added this queue, which then gets fulfilled in order.
       Conceptually this fits well in an array, but then when users fill an order we
       end up copying the whole array around, so better to use an index mapping instead
       for gas performance reasons.

       The indexes are specified (inclusive, exclusive), so (0, 0) means there's nothing
       in the array, and (3, 6) means there are 3 elements at 3, 4, and 5. You can obtain
       the length of the "array" by querying depositEndIndex - depositStartIndex. All index
       operations use safeAdd, so there is no way to overflow, so that means there is a
       very large but finite amount of deposits this contract can handle before it fills up. */
    mapping(uint => SynthDepositEntry) public deposits;
    // The starting index of our queue inclusive
    uint public depositStartIndex;
    // The ending index of our queue exclusive
    uint public depositEndIndex;

    /* This is a convenience variable so users and dApps can just query how much oUSD
       we have available for purchase without having to iterate the mapping with a
       O(n) amount of calls for something we'll probably want to display quite regularly. */
    uint public totalSellableDeposits;

    // The minimum amount of oUSD required to enter the FiFo queue
    uint public minimumDepositAmount = 50 * SafeDecimalMath.unit();

    // A cap on the amount of oUSD you can buy with BNB in 1 transaction
    uint public maxBNBPurchase = 500 * SafeDecimalMath.unit();

    // If a user deposits a synth amount < the minimumDepositAmount the contract will keep
    // the total of small deposits which will not be sold on market and the sender
    // must call withdrawMyDepositedSynths() to get them back.
    mapping(address => uint) public smallDeposits;

    /* ========== ADDRESS RESOLVER CONFIGURATION ========== */

    bytes32 private constant CONTRACT_SYNTHOUSD = "SynthoUSD";
    bytes32 private constant CONTRACT_EXRATES = "ExchangeRates";
    bytes32 private constant CONTRACT_ORGANIX = "Organix";

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address payable _fundsWallet,
        address _resolver
    ) public Owned(_owner) Pausable() MixinResolver(_resolver) {
        fundsWallet = _fundsWallet;
    }

    /* ========== SETTERS ========== */

    function setMaxBNBPurchase(uint _maxBNBPurchase) external onlyOwner {
        maxBNBPurchase = _maxBNBPurchase;
        emit MaxBNBPurchaseUpdated(maxBNBPurchase);
    }

    /**
     * @notice Set the funds wallet where BNB raised is held
     * @param _fundsWallet The new address to forward BNB and Synths to
     */
    function setFundsWallet(address payable _fundsWallet) external onlyOwner {
        fundsWallet = _fundsWallet;
        emit FundsWalletUpdated(fundsWallet);
    }

    /**
     * @notice Set the minimum deposit amount required to depoist oUSD into the FIFO queue
     * @param _amount The new new minimum number of oUSD required to deposit
     */
    function setMinimumDepositAmount(uint _amount) external onlyOwner {
        // Do not allow us to set it less than 1 dollar opening up to fractional desposits in the queue again
        require(_amount > SafeDecimalMath.unit(), "Minimum deposit amount must be greater than UNIT");
        minimumDepositAmount = _amount;
        emit MinimumDepositAmountUpdated(minimumDepositAmount);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
     * @notice Fallback function (exchanges BNB to oUSD)
     */
    function() external payable nonReentrant rateNotInvalid(BNB) notPaused {
        _exchangeBNBForSynths();
    }

    /**
     * @notice Exchange BNB to oUSD.
     */
    /* solhint-disable multiple-sends, reentrancy */
    function exchangeBNBForSynths()
        external
        payable
        nonReentrant
        rateNotInvalid(BNB)
        notPaused
        returns (
            uint // Returns the number of Synths (oUSD) received
        )
    {
        return _exchangeBNBForSynths();
    }

    function _exchangeBNBForSynths() internal returns (uint) {
        require(msg.value <= maxBNBPurchase, "BNB amount above maxBNBPurchase limit");
        uint BNBToSend;

        // The multiplication works here because exchangeRates().rateForCurrency(BNB) is specified in
        // 18 decimal places, just like our currency base.
        uint requestedToPurchase = msg.value.multiplyDecimal(exchangeRates().rateForCurrency(BNB));
        uint remainingToFulfill = requestedToPurchase;

        // Iterate through our outstanding deposits and sell them one at a time.
        for (uint i = depositStartIndex; remainingToFulfill > 0 && i < depositEndIndex; i++) {
            SynthDepositEntry memory deposit = deposits[i];

            // If it's an empty spot in the queue from a previous withdrawal, just skip over it and
            // update the queue. It's already been deleted.
            if (deposit.user == address(0)) {
                depositStartIndex = depositStartIndex.add(1);
            } else {
                // If the deposit can more than fill the order, we can do this
                // without touching the structure of our queue.
                if (deposit.amount > remainingToFulfill) {
                    // Ok, this deposit can fulfill the whole remainder. We don't need
                    // to change anything about our queue we can just fulfill it.
                    // Subtract the amount from our deposit and total.
                    uint newAmount = deposit.amount.sub(remainingToFulfill);
                    deposits[i] = SynthDepositEntry({user: deposit.user, amount: newAmount});

                    totalSellableDeposits = totalSellableDeposits.sub(remainingToFulfill);

                    // Transfer the BNB to the depositor. Send is used instead of transfer
                    // so a non payable contract won't block the FIFO queue on a failed
                    // BNB payable for synths transaction. The proceeds to be sent to the
                    // organix foundation funds wallet. This is to protect all depositors
                    // in the queue in this rare case that may occur.
                    BNBToSend = remainingToFulfill.divideDecimal(exchangeRates().rateForCurrency(BNB));

                    // We need to use send here instead of transfer because transfer reverts
                    // if the recipient is a non-payable contract. Send will just tell us it
                    // failed by returning false at which point we can continue.
                    if (!deposit.user.send(BNBToSend)) {
                        fundsWallet.transfer(BNBToSend);
                        emit NonPayableContract(deposit.user, BNBToSend);
                    } else {
                        emit ClearedDeposit(msg.sender, deposit.user, BNBToSend, remainingToFulfill, i);
                    }

                    // And the Synths to the recipient.
                    // Note: Fees are calculated by the Synth contract, so when
                    //       we request a specific transfer here, the fee is
                    //       automatically deducted and sent to the fee pool.
                    synthoUSD().transfer(msg.sender, remainingToFulfill);

                    // And we have nothing left to fulfill on this order.
                    remainingToFulfill = 0;
                } else if (deposit.amount <= remainingToFulfill) {
                    // We need to fulfill this one in its entirety and kick it out of the queue.
                    // Start by kicking it out of the queue.
                    // Free the storage because we can.
                    delete deposits[i];
                    // Bump our start index forward one.
                    depositStartIndex = depositStartIndex.add(1);
                    // We also need to tell our total it's decreased
                    totalSellableDeposits = totalSellableDeposits.sub(deposit.amount);

                    // Now fulfill by transfering the BNB to the depositor. Send is used instead of transfer
                    // so a non payable contract won't block the FIFO queue on a failed
                    // BNB payable for synths transaction. The proceeds to be sent to the
                    // organix foundation funds wallet. This is to protect all depositors
                    // in the queue in this rare case that may occur.
                    BNBToSend = deposit.amount.divideDecimal(exchangeRates().rateForCurrency(BNB));

                    // We need to use send here instead of transfer because transfer reverts
                    // if the recipient is a non-payable contract. Send will just tell us it
                    // failed by returning false at which point we can continue.
                    if (!deposit.user.send(BNBToSend)) {
                        fundsWallet.transfer(BNBToSend);
                        emit NonPayableContract(deposit.user, BNBToSend);
                    } else {
                        emit ClearedDeposit(msg.sender, deposit.user, BNBToSend, deposit.amount, i);
                    }

                    // And the Synths to the recipient.
                    // Note: Fees are calculated by the Synth contract, so when
                    //       we request a specific transfer here, the fee is
                    //       automatically deducted and sent to the fee pool.
                    synthoUSD().transfer(msg.sender, deposit.amount);

                    // And subtract the order from our outstanding amount remaining
                    // for the next iteration of the loop.
                    remainingToFulfill = remainingToFulfill.sub(deposit.amount);
                }
            }
        }

        // Ok, if we're here and 'remainingToFulfill' isn't zero, then
        // we need to refund the remainder of their BNB back to them.
        if (remainingToFulfill > 0) {
            msg.sender.transfer(remainingToFulfill.divideDecimal(exchangeRates().rateForCurrency(BNB)));
        }

        // How many did we actually give them?
        uint fulfilled = requestedToPurchase.sub(remainingToFulfill);

        if (fulfilled > 0) {
            // Now tell everyone that we gave them that many (only if the amount is greater than 0).
            emit Exchange("BNB", msg.value, "oUSD", fulfilled);
        }

        return fulfilled;
    }

    /* solhint-enable multiple-sends, reentrancy */

    /**
     * @notice Exchange BNB to oUSD while insisting on a particular rate. This allows a user to
     *         exchange while protecting against frontrunning by the contract owner on the exchange rate.
     * @param guaranteedRate The exchange rate (BNB price) which must be honored or the call will revert.
     */
    function exchangeBNBForSynthsAtRate(uint guaranteedRate)
        external
        payable
        rateNotInvalid(BNB)
        notPaused
        returns (
            uint // Returns the number of Synths (oUSD) received
        )
    {
        require(guaranteedRate == exchangeRates().rateForCurrency(BNB), "Guaranteed rate would not be received");

        return _exchangeBNBForSynths();
    }

    function _exchangeBNBForOGX() internal returns (uint) {
        // How many OGX are they going to be receiving?
        uint organixToSend = organixReceivedForBNB(msg.value);

        // Store the BNB in our funds wallet
        fundsWallet.transfer(msg.value);

        // And send them the OGX.
        organix().transfer(msg.sender, organixToSend);

        emit Exchange("BNB", msg.value, "OGX", organixToSend);

        return organixToSend;
    }

    /**
     * @notice Exchange BNB to OGX.
     */
    function exchangeBNBForOGX()
        external
        payable
        rateNotInvalid(OGX)
        rateNotInvalid(BNB)
        notPaused
        returns (
            uint // Returns the number of OGX received
        )
    {
        return _exchangeBNBForOGX();
    }

    /**
     * @notice Exchange BNB to OGX while insisting on a particular set of rates. This allows a user to
     *         exchange while protecting against frontrunning by the contract owner on the exchange rates.
     * @param guaranteedBNBRate The BNB exchange rate which must be honored or the call will revert.
     * @param guaranteedOrganixRate The organix exchange rate which must be honored or the call will revert.
     */
    function exchangeBNBForOGXAtRate(uint guaranteedBNBRate, uint guaranteedOrganixRate)
        external
        payable
        rateNotInvalid(OGX)
        rateNotInvalid(BNB)
        notPaused
        returns (
            uint // Returns the number of OGX received
        )
    {
        require(guaranteedBNBRate == exchangeRates().rateForCurrency(BNB), "Guaranteed BNB rate would not be received");
        require(
            guaranteedOrganixRate == exchangeRates().rateForCurrency(OGX),
            "Guaranteed organix rate would not be received"
        );

        return _exchangeBNBForOGX();
    }

    function _exchangeSynthsForOGX(uint synthAmount) internal returns (uint) {
        // How many OGX are they going to be receiving?
        uint organixToSend = organixReceivedForSynths(synthAmount);

        // Ok, transfer the Synths to our funds wallet.
        // These do not go in the deposit queue as they aren't for sale as such unless
        // they're sent back in from the funds wallet.
        synthoUSD().transferFrom(msg.sender, fundsWallet, synthAmount);

        // And send them the OGX.
        organix().transfer(msg.sender, organixToSend);

        emit Exchange("oUSD", synthAmount, "OGX", organixToSend);

        return organixToSend;
    }

    /**
     * @notice Exchange oUSD for OGX
     * @param synthAmount The amount of synths the user wishes to exchange.
     */
    function exchangeSynthsForOGX(uint synthAmount)
        external
        rateNotInvalid(OGX)
        notPaused
        returns (
            uint // Returns the number of OGX received
        )
    {
        return _exchangeSynthsForOGX(synthAmount);
    }

    /**
     * @notice Exchange oUSD for OGX while insisting on a particular rate. This allows a user to
     *         exchange while protecting against frontrunning by the contract owner on the exchange rate.
     * @param synthAmount The amount of synths the user wishes to exchange.
     * @param guaranteedRate A rate (organix price) the caller wishes to insist upon.
     */
    function exchangeSynthsForOGXAtRate(uint synthAmount, uint guaranteedRate)
        external
        rateNotInvalid(OGX)
        notPaused
        returns (
            uint // Returns the number of OGX received
        )
    {
        require(guaranteedRate == exchangeRates().rateForCurrency(OGX), "Guaranteed rate would not be received");

        return _exchangeSynthsForOGX(synthAmount);
    }

    /**
     * @notice Allows the owner to withdraw OGX from this contract if needed.
     * @param amount The amount of OGX to attempt to withdraw (in 18 decimal places).
     */
    function withdrawOrganix(uint amount) external onlyOwner {
        organix().transfer(owner, amount);

        // We don't emit our own events here because we assume that anyone
        // who wants to watch what the Depot is doing can
        // just watch ERC20 events from the Synth and/or Organix contracts
        // filtered to our address.
    }

    /**
     * @notice Allows a user to withdraw all of their previously deposited synths from this contract if needed.
     *         Developer note: We could keep an index of address to deposits to make this operation more efficient
     *         but then all the other operations on the queue become less efficient. It's expected that this
     *         function will be very rarely used, so placing the inefficiency here is intentional. The usual
     *         use case does not involve a withdrawal.
     */
    function withdrawMyDepositedSynths() external {
        uint synthsToSend = 0;

        for (uint i = depositStartIndex; i < depositEndIndex; i++) {
            SynthDepositEntry memory deposit = deposits[i];

            if (deposit.user == msg.sender) {
                // The user is withdrawing this deposit. Remove it from our queue.
                // We'll just leave a gap, which the purchasing logic can walk past.
                synthsToSend = synthsToSend.add(deposit.amount);
                delete deposits[i];
                //Let the DApps know we've removed this deposit
                emit SynthDepositRemoved(deposit.user, deposit.amount, i);
            }
        }

        // Update our total
        totalSellableDeposits = totalSellableDeposits.sub(synthsToSend);

        // Check if the user has tried to send deposit amounts < the minimumDepositAmount to the FIFO
        // queue which would have been added to this mapping for withdrawal only
        synthsToSend = synthsToSend.add(smallDeposits[msg.sender]);
        smallDeposits[msg.sender] = 0;

        // If there's nothing to do then go ahead and revert the transaction
        require(synthsToSend > 0, "You have no deposits to withdraw.");

        // Send their deposits back to them (minus fees)
        synthoUSD().transfer(msg.sender, synthsToSend);

        emit SynthWithdrawal(msg.sender, synthsToSend);
    }

    /**
     * @notice depositSynths: Allows users to deposit synths via the approve / transferFrom workflow
     * @param amount The amount of oUSD you wish to deposit (must have been approved first)
     */
    function depositSynths(uint amount) external {
        // Grab the amount of synths. Will fail if not approved first
        synthoUSD().transferFrom(msg.sender, address(this), amount);

        // A minimum deposit amount is designed to protect purchasers from over paying
        // gas for fullfilling multiple small synth deposits
        if (amount < minimumDepositAmount) {
            // We cant fail/revert the transaction or send the synths back in a reentrant call.
            // So we will keep your synths balance seperate from the FIFO queue so you can withdraw them
            smallDeposits[msg.sender] = smallDeposits[msg.sender].add(amount);

            emit SynthDepositNotAccepted(msg.sender, amount, minimumDepositAmount);
        } else {
            // Ok, thanks for the deposit, let's queue it up.
            deposits[depositEndIndex] = SynthDepositEntry({user: msg.sender, amount: amount});
            emit SynthDeposit(msg.sender, amount, depositEndIndex);

            // Walk our index forward as well.
            depositEndIndex = depositEndIndex.add(1);

            // And add it to our total.
            totalSellableDeposits = totalSellableDeposits.add(amount);
        }
    }

    /* ========== VIEWS ========== */

    function resolverAddressesRequired() public view returns (bytes32[] memory addresses) {
        addresses = new bytes32[](3);
        addresses[0] = CONTRACT_SYNTHOUSD;
        addresses[1] = CONTRACT_EXRATES;
        addresses[2] = CONTRACT_ORGANIX;
    }

    /**
     * @notice Calculate how many OGX you will receive if you transfer
     *         an amount of synths.
     * @param amount The amount of synths (in 18 decimal places) you want to ask about
     */
    function organixReceivedForSynths(uint amount) public view returns (uint) {
        // And what would that be worth in OGX based on the current price?
        return amount.divideDecimal(exchangeRates().rateForCurrency(OGX));
    }

    /**
     * @notice Calculate how many OGX you will receive if you transfer
     *         an amount of BNB.
     * @param amount The amount of BNB (in wei) you want to ask about
     */
    function organixReceivedForBNB(uint amount) public view returns (uint) {
        // How much is the BNB they sent us worth in oUSD (ignoring the transfer fee)?
        uint valueSentInSynths = amount.multiplyDecimal(exchangeRates().rateForCurrency(BNB));

        // Now, how many OGX will that USD amount buy?
        return organixReceivedForSynths(valueSentInSynths);
    }

    /**
     * @notice Calculate how many synths you will receive if you transfer
     *         an amount of BNB.
     * @param amount The amount of BNB (in wei) you want to ask about
     */
    function synthsReceivedForBNB(uint amount) public view returns (uint) {
        // How many synths would that amount of BNB be worth?
        return amount.multiplyDecimal(exchangeRates().rateForCurrency(BNB));
    }

    /* ========== INTERNAL VIEWS ========== */

    function synthoUSD() internal view returns (IERC20) {
        return IERC20(requireAndGetAddress(CONTRACT_SYNTHOUSD));
    }

    function organix() internal view returns (IERC20) {
        return IERC20(requireAndGetAddress(CONTRACT_ORGANIX));
    }

    function exchangeRates() internal view returns (IExchangeRates) {
        return IExchangeRates(requireAndGetAddress(CONTRACT_EXRATES));
    }

    // ========== MODIFIERS ==========

    modifier rateNotInvalid(bytes32 currencyKey) {
        require(!exchangeRates().rateIsInvalid(currencyKey), "Rate invalid or not a synth");
        _;
    }

    /* ========== EVENTS ========== */

    event MaxBNBPurchaseUpdated(uint amount);
    event FundsWalletUpdated(address newFundsWallet);
    event Exchange(string fromCurrency, uint fromAmount, string toCurrency, uint toAmount);
    event SynthWithdrawal(address user, uint amount);
    event SynthDeposit(address indexed user, uint amount, uint indexed depositIndex);
    event SynthDepositRemoved(address indexed user, uint amount, uint indexed depositIndex);
    event SynthDepositNotAccepted(address user, uint amount, uint minimum);
    event MinimumDepositAmountUpdated(uint amount);
    event NonPayableContract(address indexed receiver, uint amount);
    event ClearedDeposit(
        address indexed fromAddress,
        address indexed toAddress,
        uint fromBNBAmount,
        uint toAmount,
        uint indexed depositIndex
    );
}
