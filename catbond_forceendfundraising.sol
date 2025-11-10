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
        bytes32 _locationId
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
    // --------------------------------------------
    function payQuarterlyCoupon() external onlyOwner {
        require(fundsInvested, "Funds not invested");
        require(!triggerActivated, "Trigger occurred, contract halted");
        require(block.timestamp >= nextCouponTime, "Too early for next coupon");
        require(!contractEnded, "Contract ended");

        totalCouponsPaid += 1;
        nextCouponTime += QUARTER_DURATION;

        // Simulate base yield growth (compounding)
        uint256 currentBalance = yieldToken.balanceOf(address(this));
        uint256 yieldGrowth = (currentBalance * yieldRate) / 10000; // basis points
        yieldToken.mint(address(this), yieldGrowth);

        // Calculate total coupon = yield + insurer premium (in ETH)
        uint256 totalCoupon = (currentBalance * (yieldRate + riskPremiumRate)) / 10000;

        // Ensure insurer deposits enough ETH for risk premium
        require(address(this).balance >= totalCoupon, "Insufficient ETH for coupon");

        uint256 totalBonds = bondsSold;
        for (uint i = 0; i < investors.length; i++) {
            address investor = investors[i];
            uint256 share = (bondHolders[investor] * totalCoupon) / totalBonds;
            payable(investor).transfer(share);
            emit CouponPaid(investor, share, totalCouponsPaid);
        }

        // Check for maturity (3 years)
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
            sellYieldInvestment();
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
        sellYieldInvestment();
    }
}
    // --------------------------------------------
    // EARLY TERMINATION ON TRIGGER
    // --------------------------------------------
    function sellYieldInvestment() internal {
        require(fundsInvested, "No active investment");
        uint256 yieldBalance = yieldToken.balanceOf(address(this));
        require(yieldBalance > 0, "No yield tokens");

        yieldToken.burn(address(this), yieldBalance);
        uint256 proceeds = (yieldBalance * 50) / 100; // assume 50% loss after disaster

        uint256 totalBonds = bondsSold;
        for (uint i = 0; i < investors.length; i++) {
            address investor = investors[i];
            uint256 share = (bondHolders[investor] * proceeds) / totalBonds;
            payable(investor).transfer(share);
        }

        fundsInvested = false;
        contractEnded = true;
        emit YieldInvestmentSold(proceeds);
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

    receive() external payable {}
}
function triggerInfo()
    external
    view
    returns (bool activated, uint64 speedX100, uint64 ts, uint256 threshold)
{
    return (triggerActivated, lastTriggerSpeedX100, lastTriggerTs, triggerThreshold);
}

event ForcedMaturity(uint256 principalBurned, uint256 totalPayout);

/// @notice Emergency / test helper: end the contract now and distribute available ETH pro-rata.
/// @dev Burns all MockYieldToken and pays out up to the contract's ETH balance.
///      If ETH < token "principal", payout is capped to available ETH (no revert).
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
        bytes32 _locationId
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
            _locationId
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
