// SPDX-License-Identifier: MIT

// for educational purposes only! Do not use real funds!

pragma solidity ^0.8.9;

// ------------------------------------
// Mock Yield Token for demonstration
// ------------------------------------
contract MockYieldToken {
    string public name = "MockYieldToken";
    string public symbol = "MYT";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "Not enough balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

interface IOraclePushReceiver {
    function oraclePushWind(
        bytes32 locationId,
        uint64 speedX100,
        uint64 gustX100,
        int16  directionDeg,
        uint64 updatedAt,
        address updater
    ) external;
}
// ------------------------------------
// Wind Oracle Interface
// ------------------------------------
interface IWindOracle {
    function getWind(bytes32 locationId)
        external
        view
        returns (
            uint64 speedX100,     // m/s * 100
            uint64 gustX100,      // m/s * 100
            int16  directionDeg,  // 0..359 or -1
            uint64 updatedAt,     // unix epoch
            address updater
        );
}

// ------------------------------------
// Parametric Cat Bond Prototype
// ------------------------------------
contract InsuranceFundraising {
    address payable public owner;
    uint public startTime;
    uint public totalMinimumGoal;
    uint public minimumAmount;
    uint public bondPrice;
    uint public maxBonds;
    uint public bondsSold;
    uint public fundraisingDeadline;

    uint public triggerThreshold;        // windspeed in m/s * 100
    bool public triggerActivated = false;
    bool public fundsInvested = false;
    bool public contractEnded = false;

    // Oracle wiring
    IWindOracle public oracle;
    uint256 public maxDataAgeSeconds; // e.g., 30 minutes
    bytes32 public locationId;

    // Severity curve (linear between threshold and exhaustion)
    uint64 public exhaustionSpeedX100;   // where principal loss reaches 100%

    // Last trigger info (for UI / diagnostics)
    uint64 public lastTriggerSpeedX100;
    uint64 public lastTriggerTs;
    uint16 public lastLossBp;            // 0..10000 = 0%..100%

    // Configurable parameters
    uint public yieldRate;               // e.g. 200 = 2.00% per quarter (basis points)
    uint public riskPremiumRate;         // e.g. 150 = 1.50% per quarter (basis points)

    uint public constant CONTRACT_DURATION = 3 * 365 days; // 3 years
    uint public constant QUARTER_DURATION = 25 seconds;
    uint public nextCouponTime;
    uint public totalCouponsPaid;

    MockYieldToken public yieldToken;

    mapping(address => uint256) public bondHolders;
    address[] public investors;

    // Events
    event FundraisingStarted(address insurer, uint goal, uint startTime, uint deadline);
    event FundraisingEnded(uint bondsSold);
    event FundraisingFailed();
    event FundraisingSuccessful(uint totalRaised);
    event BondPurchased(address indexed investor, uint amount);
    event FundsInvested(uint256 amount);
    event CouponPaid(address indexed investor, uint256 amount, uint quarter);
    event TriggerActivated(uint256 windspeed, uint256 oracleTs);
    event YieldInvestmentSold(uint256 proceeds);
    event ContractMatured(uint256 totalPayout);
    event OracleUpdated(address indexed oracle, uint256 maxAge);
    event RefundClaimed(address indexed investor, uint256 bonds, uint256 amount);
    event ForcedMaturity(uint256 principalBurned, uint256 totalPayout);

    constructor(
        address payable _owner,
        address oracleAddr,
        uint256 _maxDataAgeSeconds,
        uint _minimumAmount,
        uint _bondPrice,
        uint _maxBonds,
        uint _fundraisingDays,
        uint _totalMinimumGoal,
        uint _triggerThreshold,
        uint _yieldRateBasisPoints,     // yield per quarter in basis points (e.g., 200 = 2%)
        uint _riskPremiumBasisPoints,    // risk premium per quarter (e.g., 150 = 1.5%)
        bytes32 _locationId,
        uint256 _exhaustionSpeedX100
    ) {
        owner = _owner;
        startTime = block.timestamp;
        minimumAmount = _minimumAmount;
        totalMinimumGoal = _totalMinimumGoal;
        bondPrice = _bondPrice;
        maxBonds = _maxBonds;
        fundraisingDeadline = block.timestamp + (_fundraisingDays * 1 days);
        triggerThreshold = _triggerThreshold;
        yieldRate = _yieldRateBasisPoints;
        riskPremiumRate = _riskPremiumBasisPoints;
        yieldToken = new MockYieldToken();
        oracle = IWindOracle(oracleAddr);
        maxDataAgeSeconds = _maxDataAgeSeconds;
        locationId = _locationId; 

        exhaustionSpeedX100 = uint64(_exhaustionSpeedX100);
        require(exhaustionSpeedX100 > triggerThreshold, "exhaust > trigger");

        emit OracleUpdated(oracleAddr, _maxDataAgeSeconds);
        emit FundraisingStarted(owner, totalMinimumGoal, startTime, fundraisingDeadline);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only insurer can call this function.");
        _;
    }

modifier onlyOracle() {
    require(msg.sender == address(oracle), "not oracle");
    _;
}

    modifier fundraisingActive() {
        require(block.timestamp > startTime, "Fundraising not started");
        require(block.timestamp < fundraisingDeadline, "Fundraising ended.");
        _;
    }

    modifier fundraisingClosed() {
        require(block.timestamp > fundraisingDeadline, "Fundraising still active.");
        _;
    }

    // --------------------------------------------
    // Calculate Principalpayoutratio
    // --------------------------------------------
    function _lossBpFromWind(uint64 speedX100) internal view returns (uint16) {
        uint256 s = uint256(speedX100);

        // Below trigger: no trigger, but guard just in case
        if (s < triggerThreshold) {
            return 0;
        }

        // At or above exhaustion: full principal loss
        if (s >= exhaustionSpeedX100) {
            return 10000; // 100%
        }

        // Between triggerThreshold and exhaustionSpeedX100: linear ramp 0..100%
        uint256 num = (s - triggerThreshold) * 10000;
        uint256 den = exhaustionSpeedX100 - triggerThreshold;
        uint16 lossBp = uint16(num / den);
        return lossBp;
    }

    // --------------------------------------------
    // ADMIN
    // --------------------------------------------
// checken ob notwendig -Bo
    function setOracle(address oracleAddr, uint256 _maxDataAgeSeconds) external onlyOwner {
        oracle = IWindOracle(oracleAddr);
        maxDataAgeSeconds = _maxDataAgeSeconds;
        emit OracleUpdated(oracleAddr, _maxDataAgeSeconds);
    }

    // --------------------------------------------
    // FUNDRAISING
    // --------------------------------------------
    function buyBonds(uint _amount) external payable fundraisingActive {
        require(_amount >= minimumAmount, "Below minimum purchase");
        require(bondsSold + _amount <= maxBonds, "Exceeds max bonds");
        uint totalCost = _amount * bondPrice;
        require(msg.value == totalCost, "Incorrect ETH sent");

        if (bondHolders[msg.sender] == 0) {
            investors.push(msg.sender);
        }   

        bondHolders[msg.sender] += _amount;

        bondsSold += _amount;

        emit BondPurchased(msg.sender, _amount);
    }

    function endFundraising() external onlyOwner fundraisingClosed {
        if (bondsSold >= totalMinimumGoal) {
            emit FundraisingSuccessful(bondsSold);
        } else {
            emit FundraisingFailed();
        }
        emit FundraisingEnded(bondsSold);
    }

/// @notice Owner can bring the fundraising deadline forward (for testing / emergency).
/// @dev After this, `fundraisingClosed` will pass and you can call `endFundraising()`
///      and `investInYieldToken()` as usual.
/// @param newDeadline Unix timestamp that must be <= now and < current fundraisingDeadline.
function forceCloseFundraising(uint256 newDeadline) external onlyOwner {
    require(!contractEnded, "contract already ended");
    require(block.timestamp < fundraisingDeadline, "already closed");
    require(newDeadline <= block.timestamp, "must be in the past or now");
    require(newDeadline < fundraisingDeadline, "must reduce deadline");

    fundraisingDeadline = newDeadline;
}
    // --------------------------------------------
    // INVESTMENT INTO YIELD TOKEN
    // --------------------------------------------
    function investInYieldToken() external onlyOwner fundraisingClosed {    //sollte hier nicht fundraisingEnded stehen, weil wir haebn mit closed nichts definiert oder???
        require(!fundsInvested, "Already invested");
        require(bondsSold >= totalMinimumGoal, "Goal not met");
        uint256 amountToInvest = address(this).balance;
        require(amountToInvest > 0, "No funds available");

        yieldToken.mint(address(this), amountToInvest);
        fundsInvested = true;
        nextCouponTime = block.timestamp + QUARTER_DURATION;

        emit FundsInvested(amountToInvest);
    }

    // --------------------------------------------
    // PAY QUARTERLY COUPONS (YIELD + PREMIUM)
    // simulated yield by minting MockYieldToken
    // coupon is only risk premium, funded by issuer (Coupon grows with balance)
    // Principal is only touched at the end
    // --------------------------------------------
    function payQuarterlyCoupon() external payable onlyOwner {
        require(fundsInvested, "Funds not invested");
        require(!triggerActivated, "Trigger occurred, contract halted");
        require(block.timestamp >= nextCouponTime, "Too early for next coupon");
        require(!contractEnded, "Contract ended");
        require(bondsSold > 0, "No bondholders");

        totalCouponsPaid += 1;
        nextCouponTime += QUARTER_DURATION;

        // Simulate base yield growth (compounding)
        uint256 beforeBalance = yieldToken.balanceOf(address(this));

        if (beforeBalance > 0 && yieldRate > 0) {
            uint256 yieldGrowth = (beforeBalance * yieldRate) / 10000; // basis points
            if (yieldGrowth > 0) {
                yieldToken.mint(address(this), yieldGrowth);
            }
        }

        uint256 newBalance = yieldToken.balanceOf(address(this));

        // Calculate total coupon = insurer premium (funded by issuer)
        uint256 premium = (newBalance * riskPremiumRate) / 10000;

        require(premium > 0, "Premium is zero");
        require(msg.value == premium, "Incorrect ETH sent for premium");

        // Distribute premium to investors
        uint256 totalBonds = bondsSold;
        for (uint256 i = 0; i < investors.length; i++) {
            address investor = investors[i];
            uint256 investorBonds = bondHolders[investor];
            if (investorBonds == 0) continue;

            uint256 share = (premium * investorBonds) / totalBonds;
            if (share > 0) {
                payable(investor).transfer(share);
                emit CouponPaid(investor, share, totalCouponsPaid);
            }
        }

        // Check for maturity
        if (block.timestamp >= startTime + CONTRACT_DURATION) {
            matureContract();
        }
    }

    // --------------------------------------------
    // PARAMETRIC TRIGGER (e.g. windspeed)
    // --------------------------------------------
    function checkTrigger() external {
        require(!triggerActivated, "already");

        (uint64 speedX100,, , uint64 ts, ) = oracle.getWind(locationId);
        require(ts != 0 && block.timestamp - ts <= maxDataAgeSeconds, "stale oracle");

        if (speedX100 >= triggerThreshold) {
            triggerActivated = true;
            emit TriggerActivated(speedX100, ts);
            sellYieldInvestment(speedX100, ts);
            }
    }

// Alternative für checktrigger, muss ich noch testen - Bo

    //function checkTrigger() external {
    // 1) Already finished or triggered? Do nothing.
   // if (contractEnded || triggerActivated) return;

    // 2) Read oracle
    //(uint64 speedX100,, , uint64 ts, ) = oracle.getWind(locationId);

    // 3) Freshness soft-guard: just ignore if stale/no data (no revert)
    //if (ts == 0 || block.timestamp - ts > maxDataAgeSeconds) return;

    // 4) Threshold not met? Do nothing.
   // if (speedX100 < triggerThreshold) return;

    // 5) Trigger, emit, liquidate
   // triggerActivated = true;
   // lastTriggerSpeedX100 = speedX100;
   // lastTriggerTs = ts;
   // emit TriggerActivated(speedX100, ts);
   // sellYieldInvestment();
//}

/// @notice Oracle push entrypoint. Verifies freshness and triggers if threshold hit.
/// @dev The oracle must call this (enforced by onlyOracle).
function oraclePushWind(
    bytes32 _locationId,
    uint64 speedX100,
    uint64 /*gustX100*/,
    int16  /*directionDeg*/,
    uint64 updatedAt,
    address /*updater*/
) external onlyOracle {
    if (contractEnded || triggerActivated) return; // ignore if already finished/triggered
    if (_locationId != locationId) return;         // ignore other feeds/locations

    // Freshness check identical to checkTrigger()
    require(updatedAt != 0 && block.timestamp - updatedAt <= maxDataAgeSeconds, "stale oracle");

    if (speedX100 >= triggerThreshold) {
        triggerActivated = true;
        emit TriggerActivated(speedX100, updatedAt);
        sellYieldInvestment(speedX100, updatedAt);
    }
}
    // --------------------------------------------
    // EARLY TERMINATION ON TRIGGER
    // --------------------------------------------
    function sellYieldInvestment(uint64 speedX100, uint64 oracleTs) internal {
        require(fundsInvested, "No active investment");

        uint256 notional = yieldToken.balanceOf(address(this));
        require(notional > 0, "No yield tokens");

        // Close the synthetic investment
        yieldToken.burn(address(this), notional);

        // Compute loss fraction in basis points
        uint16 lossBp = _lossBpFromWind(speedX100);

        // Record trigger info
        lastTriggerSpeedX100 = speedX100;
        lastTriggerTs        = oracleTs;
        lastLossBp           = lossBp;

        // Intended splits (in "notional units")
        uint256 issuerNotional    = (notional * lossBp) / 10000;
        uint256 investorsNotional = notional - issuerNotional;

        // Map notional to ETH, assume 1:1, but cap to available ETH to avoid overpaying.
        uint256 available = address(this).balance;

        // 1) Pay issuer (cat payout)
        uint256 issuerPaid = issuerNotional > available ? available : issuerNotional;
        if (issuerPaid > 0) {
            (bool ok, ) = owner.call{value: issuerPaid}("");
            require(ok, "issuer payout failed");
            available -= issuerPaid;
        }

        // 2) Pay remaining to investors pro-rata (if any)
        uint256 totalBonds = bondsSold;
        uint256 investorsPaid;

        if (investorsNotional > 0 && totalBonds > 0 && available > 0) {
            uint256 payoutPool = investorsNotional <= available
                ? investorsNotional
                : available;

            for (uint256 i = 0; i < investors.length; i++) {
                address investor = investors[i];
                uint256 b = bondHolders[investor];
                if (b == 0) continue;

                uint256 share = (payoutPool * b) / totalBonds;
                if (share > 0) {
                    (bool ok, ) = payable(investor).call{value: share}("");
                    require(ok, "payout transfer failed");
                    investorsPaid += share;
                }
            }
        }

        fundsInvested   = false;
        contractEnded   = true;
        triggerActivated = true;

        emit YieldInvestmentSold(issuerPaid + investorsPaid);
    }

    // --------------------------------------------
    // MATURITY PAYOUT AFTER 3 YEARS
    // --------------------------------------------
    function matureContract() internal {
        require(!contractEnded, "Already ended");

        uint256 principal = yieldToken.balanceOf(address(this));
        yieldToken.burn(address(this), principal);

        uint256 totalBonds = bondsSold;
        for (uint i = 0; i < investors.length; i++) {
            address investor = investors[i];
            uint256 share = (bondHolders[investor] * principal) / totalBonds;
            payable(investor).transfer(share);
        }

        contractEnded = true;
        emit ContractMatured(principal);
    }

    function claimRefund() external {
        require(block.timestamp >= fundraisingDeadline, "Fundraising still active");
        require(bondsSold < totalMinimumGoal, "Goal met; no refunds");
        uint256 bonds = bondHolders[msg.sender];
        require(bonds > 0, "Nothing to refund");

        uint256 amount = bonds * bondPrice;
        bondHolders[msg.sender] = 0;

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        require(ok, "Refund transfer failed");

        emit RefundClaimed(msg.sender, bonds, amount);
    }

    // --------------------------------------------
    // VIEW HELPER: TRIGGER INFO
    // --------------------------------------------
    function triggerInfo()
        external
        view
        returns (bool activated, uint64 speedX100, uint64 ts, uint256 threshold)
    {
        return (triggerActivated, lastTriggerSpeedX100, lastTriggerTs, triggerThreshold);
    }

    // --------------------------------------------
    // EMERGENCY / TEST: FORCE MATURITY NOW
    /// @notice Emergency / test helper: end the contract now and distribute available ETH pro-rata.
    /// @dev Burns all MockYieldToken and pays out up to the contract's ETH balance.
    ///      If ETH < token "principal", payout is capped to available ETH (no revert).
    // --------------------------------------------

    function forceMatureNow() external onlyOwner {
        require(!contractEnded, "Already ended");
        require(block.timestamp > fundraisingDeadline, "fundraising still active"); //brauchen wir vielleicht nicht
        require(fundsInvested, "not invested"); //brauchen wir vielleicht nicht

        // Read & burn synthetic principal
        uint256 principal = yieldToken.balanceOf(address(this));
        if (principal > 0) {
            yieldToken.burn(address(this), principal);
        }

        // Payout = available ETH (capped), pro-rata by bond holdings
        uint256 available = address(this).balance;
        uint256 totalBonds = bondsSold;
        uint256 totalPaid;

        if (available > 0 && totalBonds > 0) {
            for (uint i = 0; i < investors.length; i++) {
                address investor = investors[i];
                uint256 share = (bondHolders[investor] * available) / totalBonds;
                if (share > 0) {
                    (bool ok, ) = payable(investor).call{value: share}("");
                    require(ok, "payout transfer failed");
                    totalPaid += share;
                }
            }
        }

        fundsInvested = false;
        triggerActivated = true; // optional: mark as no further coupons
        contractEnded = true;

        emit ForcedMaturity(principal, totalPaid);
    }

    receive() external payable {}
}

/* -------------------------------------------------------------------------- */
/*                               CatBondFactory                               */
/* -------------------------------------------------------------------------- */
/**
 * @title CatBondFactory
 * @notice Deploys new InsuranceFundraising instances and indexes them.
 */
contract CatBondFactory {
    event BondCreated(
        uint256 indexed bondId,
        address indexed issuer,
        address bondAddress,
        uint256 createdAt
    );

    address[] public bonds; // index = bondId

    function createBond(
        address oracleAddr,
        uint256 maxDataAgeSeconds,
        uint256 _minimumAmount,
        uint256 _bondPrice,
        uint256 _maxBonds,
        uint256 _fundraisingDays,
        uint256 _totalMinimumGoal,
        uint256 _triggerThreshold,
        uint256 _yieldRateBasisPoints,
        uint256 _riskPremiumBasisPoints,
        bytes32 _locationId,
        uint256 _exhaustionSpeedX100
    ) external returns (uint256 bondId, address bondAddress) {
        // Deployer (msg.sender) will be the owner inside InsuranceFundraising constructor
        InsuranceFundraising bond = new InsuranceFundraising(
            payable(msg.sender),
            oracleAddr,
            maxDataAgeSeconds,
            _minimumAmount,
            _bondPrice,
            _maxBonds,
            _fundraisingDays,
            _totalMinimumGoal,
            _triggerThreshold,
            _yieldRateBasisPoints,
            _riskPremiumBasisPoints,
            _locationId,
            _exhaustionSpeedX100
        );

        bonds.push(address(bond));
        bondId = bonds.length - 1;
        bondAddress = address(bond);

        emit BondCreated(bondId, msg.sender, bondAddress, block.timestamp);
    }

    function bondsCount() external view returns (uint256) {
        return bonds.length;
    }

    function bondAt(uint256 bondId) external view returns (address) {
        require(bondId < bonds.length, "invalid bondId");
        return bonds[bondId];
    }
}
