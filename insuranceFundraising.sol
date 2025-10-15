// SPDX-License-Identifier: MIT

//for educational purposes only

pragma solidity ^0.8.9;

contract InsuranceFundraising{
    address payable public owner;   // the owner of the contract is the insurer
    uint public startTime;          // fundraising has started
    uint public totalMinimumGoal;   // is the minimum amount of bonds that need to be sold to make the fundraising successful
    uint public minimumAmount;      // minimum amount of Bonds purchased per investor
    uint public bondPrice;          // price of a single bond
    uint public maxBonds;           // how many bonds can be sold in total
    uint public bondsSold;          // how many bonds are already sold
    uint public deadline;           // deadline for the fundraising
    



// Events
    event FundraisingStarted(address indexed insurer, uint goal, uint startTime, uint deadline);
    event FundraisingEnded(uint bondsSold);
    event FundraisingFailed();  // kann in unserem Projekt das fundraising überhaupt failen??? Alex: wir können das als theoretischen Fall reinnehmen würde ich sagen
    event FundraisingSuccessful(uint totalRaised);
    event BondPurchased(address indexed investor, uint amount); // folie 189
    event FundsWithdrawn(address indexed insurer, uint amount);
   // noch eins für extended deadline??
   // gibt es für den investor eine möglichkeit investment vor ende des fundraisings zurückzuziehen? Alex: würde sagen das sollte möglich sein



//Constructor 
    constructor(uint _minimumAmount, uint _bondPrice, uint _maxBonds, uint _deadline, uint _totalMinimumGoal) {
        owner = payable(msg.sender);                     // owner = insurer is the msg.sender <- insurer saved as owner of the contract
        startTime = block.timestamp;
        minimumAmount = _minimumAmount;
        totalMinimumGoal = _totalMinimumGoal;
        bondPrice = _bondPrice;
        maxBonds = _maxBonds;
        deadline = block.timestamp + (_deadline * 1 days);

        emit FundraisingStarted(owner, totalMinimumGoal, startTime, deadline);
    }



// modifier
    modifier onlyOwner() {
        require(msg.sender == owner, "only insurer can call this function.");   // requiremenmt is true or error message
        _;
    }

    modifier fundraisingActive() {
        require(block.timestamp > startTime, "Fundraising has not started");
        require(block.timestamp < deadline, "Fundraising ended.");
        _;
    }

    modifier fundraisingClosed() {
        require(block.timestamp > deadline, "Fundraising still active.");
        _;
    }

    // mapping
    mapping(address => uint256) public bondHolders;  // to track purchased bonds per investor

    // Functions

    function buyBonds(uint _amount) external payable fundraisingActive {
        require(block.timestamp >= startTime, "Fundraising hasn't started yet.");
        require(block.timestamp < deadline, "Fundraising has ended.");
        require(_amount >= minimumAmount, "Amount must be greater (or equal) than minimum amount.");
        require(bondsSold < maxBonds, "Fundraising goal already reached.");    // noch eins, dass bondsSold + amount < maxBonds ist
        uint totalCost = _amount * bondPrice;
        require(msg.value == totalCost, "Incorrect amount of ETH sent.");
        require(bondsSold + _amount <= maxBonds, "Maximum number of bonds reached.");
        bondsSold += _amount;
        owner.transfer(totalCost);
        bondHolders[msg.sender] += _amount;             // add to bondholder´s address to see how many bonds he has
        emit BondPurchased(msg.sender, _amount);
    }

    function endFundraising() external onlyOwner fundraisingClosed {
        require(block.timestamp > deadline, "Fundraising still active.");

        if (bondsSold >= totalMinimumGoal) {
            emit FundraisingSuccessful(bondsSold);
        }
        else {
            emit FundraisingFailed();
        }

    emit FundraisingEnded(bondsSold);
    }
}
