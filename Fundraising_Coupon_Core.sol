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


/* -----------------------------------------------------------
 *                         Oracle
 * ----------------------------------------------------------- */
interface IWindOracle {
    function lastReading() external view returns (uint256);
    function lastUpdatedAt() external view returns (uint256);
}

contract SimpleWindOracle is IWindOracle {
    address public owner;
    uint256 public override lastReading;
    uint256 public override lastUpdatedAt;

    event Updated(uint256 reading, uint256 timestamp);
    event OwnerChanged(address indexed prev, address indexed next);

    constructor(address _owner) {
        owner = _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function setReading(uint256 reading) external onlyOwner {
        lastReading = reading;
        lastUpdatedAt = block.timestamp;
        emit Updated(reading, block.timestamp);
    }

    function setOwner(address next) external onlyOwner {
        require(next != address(0), "zero");
        emit OwnerChanged(owner, next);
        owner = next;
    }
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

    uint public triggerThreshold;        // e.g. windspeed in km/h
    bool public triggerActivated = false;
    bool public fundsInvested = false;
    bool public contractEnded = false;

    // Oracle wiring
    IWindOracle public oracle;
    uint256 public maxDataAgeSeconds; // e.g., 30 minutes

    // Configurable parameters
    uint public yieldRate;               // e.g. 200 = 2.00% per quarter (basis points)
    uint public riskPremiumRate;         // e.g. 150 = 1.50% per quarter (basis points)

    uint public constant CONTRACT_DURATION = 3 * 365 days; // 3 years
    uint public constant QUARTER_DURATION = 90 days;
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
        uint _riskPremiumBasisPoints    // risk premium per quarter (e.g., 150 = 1.5%)
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
        yieldToken = new MockYieldToken();

        emit OracleUpdated(oracleAddr, _maxDataAgeSeconds);
        emit FundraisingStarted(owner, totalMinimumGoal, startTime, fundraisingDeadline);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only insurer can call this function.");
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

        bondsSold += _amount;

        require(bondsSold + _amount <= maxBonds, "Maximum amount of bonds that can be sold exceeded after purchase.");     

        bondHolders[msg.sender] += _amount;

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
        uint256 wind = oracle.lastReading();
        uint256 ts   = oracle.lastUpdatedAt();
        require(ts != 0 && block.timestamp - ts <= maxDataAgeSeconds, "stale oracle");

        if (wind >= triggerThreshold) {
            triggerActivated = true;
            emit TriggerActivated(wind, ts);
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
        uint256 _riskPremiumBasisPoints
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
            _riskPremiumBasisPoints
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
