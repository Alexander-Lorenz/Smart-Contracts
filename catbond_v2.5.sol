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

    // 🔒 Fixed bond price: 0.2 ETH per bond
    uint public constant bondPrice = 0.2 ether;

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
    uint public maxyieldRate;               // max yield per quarter (bps), for random 0–10% per coupon, deploy with maxyieldRate = 1000
    uint public riskPremiumRate;         // risk premium per quarter (bps)

    uint public constant CONTRACT_DURATION = 180 seconds; // 3 minutes for testing
    uint public constant QUARTER_DURATION = 60 seconds;    // 1 minute for testing
    uint public constant TOTAL_COUPONS = CONTRACT_DURATION / QUARTER_DURATION;
    uint public nextCouponTime;
    uint public totalCouponsPaid;

    // For diagnostics: which random yield was used for the last coupon?
    uint public lastCouponYieldBps;

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

    // Struct to reduce stack usage in liquidation
    struct LiquidationContext {
        uint256 notional;
        uint16  lossBp;
        uint256 issuerNotional;
        uint256 investorsNotional;
        uint256 available;
        uint256 issuerPaid;
        uint256 totalBonds;
        uint256 investorsPaid;
    }

    constructor(
        address payable _owner,
        address oracleAddr,
        uint256 _maxDataAgeSeconds,
        uint _minimumAmount,
        uint _maxBonds,
        uint _fundraisingSeconds,
        uint _totalMinimumGoal,
        uint _triggerThreshold,
        uint _maxyieldRateBasisPoints,     // max yield per quarter in basis points
        uint _riskPremiumBasisPoints,   // risk premium per quarter
        bytes32 _locationId,
        uint256 _exhaustionSpeedX100
    ) {
        owner = _owner;                          // ✅ owner = issuer/EOA, not factory
        startTime = block.timestamp;

        minimumAmount     = _minimumAmount;
        totalMinimumGoal  = _totalMinimumGoal;
        maxBonds          = _maxBonds;
        fundraisingDeadline = block.timestamp + _fundraisingSeconds;

        triggerThreshold  = _triggerThreshold;
        maxyieldRate         = _maxyieldRateBasisPoints;
        riskPremiumRate   = _riskPremiumBasisPoints;

        yieldToken        = new MockYieldToken();
        oracle            = IWindOracle(oracleAddr);
        maxDataAgeSeconds = _maxDataAgeSeconds;
        locationId        = _locationId;

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
    // Loss curve: windspeed → loss in basis points
    // --------------------------------------------
    function _lossBpFromWind(uint64 speedX100) internal view returns (uint16) {
        uint256 s = uint256(speedX100);

        if (s < triggerThreshold) {
            return 0;
        }
        if (s >= exhaustionSpeedX100) {
            return 10000; // 100%
        }

        uint256 num = (s - triggerThreshold) * 10000;
        uint256 den = exhaustionSpeedX100 - triggerThreshold;
        return uint16(num / den);
    }

    // --------------------------------------------
    // Pseudo-random yield in [0, yieldRate] bps
    // (deterministic per (bond, couponIndex))
    // --------------------------------------------
    function _drawRandomYieldBps(uint256 couponIndex) internal view returns (uint256) {
        if (maxyieldRate == 0) return 0;

        // Deterministic pseudo-"random": DO NOT use in production.
        uint256 rand = uint256(
            keccak256(
                abi.encodePacked(
                    address(this),
                    couponIndex
                )
            )
        );

        // Result in [0, maxyieldRate] inclusive
        return rand % (maxyieldRate + 1);
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

        uint totalCost = _amount * bondPrice;  // 0.2 ETH * amount
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
    function investInYieldToken() external onlyOwner fundraisingClosed {
        require(!fundsInvested, "Already invested");
        require(bondsSold >= totalMinimumGoal, "Goal not met");

        uint256 amountToInvest = address(this).balance;
        require(amountToInvest > 0, "No funds available");

        yieldToken.mint(address(this), amountToInvest);
        fundsInvested = true;
        nextCouponTime = block.timestamp + QUARTER_DURATION;

        emit FundsInvested(amountToInvest);
    }

    // -----------------------------
    // Helper: How much ETH to top up
    // -----------------------------
    function requiredTopUp() external view returns (uint256) {
        uint256 principal = yieldToken.balanceOf(address(this));
        if (principal <= address(this).balance) {
            return 0;
        }
        return principal - address(this).balance;
    }

    function topUpForMaturity() external payable onlyOwner {
        require(fundsInvested, "not invested");
        require(!contractEnded, "already ended");

        // Either all coupons are paid OR overall contract duration has passed
        require(
            totalCouponsPaid >= TOTAL_COUPONS || block.timestamp >= startTime + CONTRACT_DURATION,
            "not at maturity yet"
        );

        uint256 principal = yieldToken.balanceOf(address(this));

        // Check that, after this call, we have enough ETH to repay principal
        require(address(this).balance >= principal, "Still underfunded; send more ETH");

        // Now mature the contract and pay out principal
        matureContract();
    }

    // --------------------------------------------
    // PAY QUARTERLY COUPONS (YIELD + PREMIUM)
    // --------------------------------------------
    function payQuarterlyCoupon() external payable onlyOwner {
        require(fundsInvested, "Funds not invested");
        require(!triggerActivated, "Trigger occurred, contract halted");
        require(block.timestamp >= nextCouponTime, "Too early for next coupon");
        require(!contractEnded, "Contract ended");
        require(bondsSold > 0, "No bondholders");
        require(totalCouponsPaid < TOTAL_COUPONS, "All coupons already paid");

        // couponIndex = 1, 2, 3, ...
        uint256 couponIndex = totalCouponsPaid + 1;
        totalCouponsPaid = couponIndex;
        nextCouponTime += QUARTER_DURATION;

        uint256 beforeBalance = yieldToken.balanceOf(address(this));

        // dynamic random yield between 0 and maxyieldRate bps (e.g. 0–10%)
        uint256 couponYieldBps = _drawRandomYieldBps(couponIndex);
        lastCouponYieldBps = couponYieldBps;

        if (beforeBalance > 0 && couponYieldBps > 0) {
            uint256 yieldGrowth = (beforeBalance * couponYieldBps) / 10000;
            if (yieldGrowth > 0) {
                yieldToken.mint(address(this), yieldGrowth);
            }
        }

        uint256 newBalance = yieldToken.balanceOf(address(this));
        uint256 premium = (newBalance * riskPremiumRate) / 10000;

        require(premium > 0, "Premium is zero");
        require(msg.value == premium, "Incorrect ETH sent for premium");

        uint256 totalBondsLocal = bondsSold;
        for (uint256 i = 0; i < investors.length; i++) {
            address investor = investors[i];
            uint256 investorBonds = bondHolders[investor];
            if (investorBonds == 0) continue;

            uint256 share = (premium * investorBonds) / totalBondsLocal;
            if (share > 0) {
                (bool ok, ) = payable(investor).call{value: share}("");
                require(ok, "coupon payout failed");
                emit CouponPaid(investor, share, couponIndex);
            }
        }
    }

    function nextCouponAmount() external view returns (uint256) {
        if (contractEnded || !fundsInvested || bondsSold == 0 || totalCouponsPaid >= TOTAL_COUPONS) {
            return 0;
        }

        uint256 couponIndex = totalCouponsPaid + 1;

        uint256 beforeBalance = yieldToken.balanceOf(address(this));
        uint256 couponYieldBps = _drawRandomYieldBps(couponIndex);

        uint256 projectedBalance = beforeBalance;
        if (beforeBalance > 0 && couponYieldBps > 0) {
            uint256 yieldGrowth = (beforeBalance * couponYieldBps) / 10000;
            projectedBalance = beforeBalance + yieldGrowth;
        }

        uint256 premium = (projectedBalance * riskPremiumRate) / 10000;
        return premium;
    }

    // --------------------------------------------
    // PARAMETRIC TRIGGER (PUSH-BASED ORACLE)
    // --------------------------------------------
    function oraclePushWind(
        bytes32 _locationId,
        uint64 speedX100,
        uint64 /*gustX100*/,
        int16  /*directionDeg*/,
        uint64 updatedAt,
        address /*updater*/
    ) external onlyOracle {
        if (contractEnded || triggerActivated) return;
        if (_locationId != locationId) return;

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

        LiquidationContext memory ctx;

        ctx.notional = yieldToken.balanceOf(address(this));
        require(ctx.notional > 0, "No yield tokens");
        yieldToken.burn(address(this), ctx.notional);

        ctx.lossBp = _lossBpFromWind(speedX100);

        lastTriggerSpeedX100 = speedX100;
        lastTriggerTs        = oracleTs;
        lastLossBp           = ctx.lossBp;

        ctx.issuerNotional    = (ctx.notional * ctx.lossBp) / 10000;
        ctx.investorsNotional = ctx.notional - ctx.issuerNotional;

        ctx.available = address(this).balance;

        if (ctx.issuerNotional > 0 && ctx.available > 0) {
            ctx.issuerPaid = ctx.issuerNotional > ctx.available
                ? ctx.available
                : ctx.issuerNotional;

            if (ctx.issuerPaid > 0) {
                (bool ok, ) = owner.call{value: ctx.issuerPaid}("");
                require(ok, "issuer payout failed");
                ctx.available -= ctx.issuerPaid;
            }
        }

        ctx.totalBonds = bondsSold;

        if (ctx.investorsNotional > 0 && ctx.totalBonds > 0 && ctx.available > 0) {
            uint256 payoutPool = ctx.investorsNotional <= ctx.available
                ? ctx.investorsNotional
                : ctx.available;

            for (uint256 i = 0; i < investors.length; i++) {
                address investor = investors[i];
                uint256 b = bondHolders[investor];
                if (b == 0) continue;

                uint256 share = (payoutPool * b) / ctx.totalBonds;
                if (share > 0) {
                    (bool ok, ) = payable(investor).call{value: share}("");
                    require(ok, "payout transfer failed");
                    ctx.investorsPaid += share;
                }
            }
        }

        fundsInvested    = false;
        contractEnded    = true;
        triggerActivated = true;

        emit YieldInvestmentSold(ctx.issuerPaid + ctx.investorsPaid);
    }

    // --------------------------------------------
    // MATURITY PAYOUT AFTER 3 Quarters
    // --------------------------------------------
    function matureContract() internal {
        require(!contractEnded, "Already ended");

        uint256 principal = yieldToken.balanceOf(address(this));
        yieldToken.burn(address(this), principal);

        uint256 totalBondsLocal = bondsSold;
        for (uint i = 0; i < investors.length; i++) {
            address investor = investors[i];
            uint256 share = (bondHolders[investor] * principal) / totalBondsLocal;
            if (share > 0) {
                (bool ok, ) = payable(investor).call{value: share}("");
                require(ok, "principal payout failed");
            }
        }

        fundsInvested = false;
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

    function triggerInfo()
        external
        view
        returns (bool activated, uint64 speedX100, uint64 ts, uint256 threshold)
    {
        return (triggerActivated, lastTriggerSpeedX100, lastTriggerTs, triggerThreshold);
    }

    function forceMatureNow() external onlyOwner {
        require(!contractEnded, "Already ended");
        require(block.timestamp > fundraisingDeadline, "fundraising still active");
        require(fundsInvested, "not invested");

        uint256 principal = yieldToken.balanceOf(address(this));
        if (principal > 0) {
            yieldToken.burn(address(this), principal);
        }

        uint256 available = address(this).balance;
        uint256 totalBondsLocal = bondsSold;
        uint256 totalPaid;

        if (available > 0 && totalBondsLocal > 0) {
            for (uint i = 0; i < investors.length; i++) {
                address investor = investors[i];
                uint256 share = (bondHolders[investor] * available) / totalBondsLocal;
                if (share > 0) {
                    (bool ok, ) = payable(investor).call{value: share}("");
                    require(ok, "payout transfer failed");
                    totalPaid += share;
                }
            }
        }

        fundsInvested    = false;
        triggerActivated = true;
        contractEnded    = true;

        emit ForcedMaturity(principal, totalPaid);
    }

    receive() external payable {}
}
/* -------------------------------------------------------------------------- */
/*                               CatBondFactory                               */
/* -------------------------------------------------------------------------- */
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
        uint256 _maxBonds,
        uint256 _fundraisingSeconds,
        uint256 _totalMinimumGoal,
        uint256 _triggerThreshold,
        uint256 _maxyieldRateBasisPoints,
        uint256 _riskPremiumBasisPoints,
        bytes32 _locationId,
        uint256 _exhaustionSpeedX100
    ) external returns (uint256 bondId, address bondAddress) {
        InsuranceFundraising bond = new InsuranceFundraising(
            payable(msg.sender),        // ✅ your EOA becomes owner
            oracleAddr,
            maxDataAgeSeconds,
            _minimumAmount,
            _maxBonds,
            _fundraisingSeconds,
            _totalMinimumGoal,
            _triggerThreshold,
            _maxyieldRateBasisPoints,
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
