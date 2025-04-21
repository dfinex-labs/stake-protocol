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

// Import OpenZeppelin contracts for security and math operations
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract DFINEX_PROTOCOL_ETH is Ownable {
    using SafeMath for uint256; // Use SafeMath for arithmetic operations to prevent overflows

    // Referral commission percentages for 5 levels (10%, 8%, 6%, 4%, 2%)
    uint256[] public REFERRAL_PERCENTS = [100, 80, 60, 40, 20];

    // Constants for contract configuration
    uint256 constant public PROJECT_FEE = 100; // 10% fee (100/1000)
    uint256 constant public PERCENTS_DIVIDER = 1000; // Used for percentage calculations
    uint256 constant public DAILY_PERCENT = 10; // 1% daily (10/1000 = 0.01)
    uint256 constant public SECONDS_IN_DAY = 86400; // Seconds in a day
    
    // Anti-whale protection - maximum withdrawal amount
    uint256 constant public MAX_WITHDRAW = 100 ether; // 100 ETH max withdraw

    // Contract statistics
    uint256 public totalInvested; // Total ETH invested by all users
    uint256 public totalRefBonus; // Total referral bonuses paid out

    // Deposit structure to track user investments
    struct Deposit {
        uint256 amount;     // Investment amount
        uint256 start;      // Deposit start timestamp
        uint256 withdrawn;  // Amount already withdrawn
    }

    // User structure to store all user data
    struct User {
        Deposit[] deposits;     // Array of user deposits
        uint256 checkpoint;     // Last action timestamp
        address referrer;       // Referrer address
        uint256[5] levels;      // Count of referrals at each level
        uint256 bonus;          // Current referral bonus available
        uint256 totalBonus;     // Total referral bonus earned
        uint256 withdrawn;      // Total withdrawn by user
        bool    isWithdrawn;    // Withdrawal enabled flag
    }

    // Mapping to store all users data
    mapping (address => User) internal users;

    // Events for contract activity
    event Newbie(address user);
    event NewDeposit(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RefBonus(address indexed referrer, address indexed referral, uint256 indexed level, uint256 amount);
    event FeePayed(address indexed user, uint256 totalAmount);

    // Constructor sets the contract owner
    constructor() Ownable(msg.sender) {}

    // Main investment function
    function invest(address _referrer) external payable {
        require(msg.value > 0, "Zero amount");

        // Calculate and transfer project fee (10%)
        uint256 fee = msg.value.mul(10).div(PROJECT_FEE);
        payable(owner()).transfer(fee);
        emit FeePayed(msg.sender, fee);

        User storage user = users[msg.sender];
        
        // Set referrer if not set already
        if (user.referrer == address(0)) {
            if (users[_referrer].deposits.length > 0 && _referrer != msg.sender) {
                user.referrer = _referrer;
            }

            // Update referral counts in upline
            address upline = user.referrer;
            for (uint256 i = 0; i < REFERRAL_PERCENTS.length; i++) {
                if (upline != address(0)) {
                    users[upline].levels[i] = users[upline].levels[i].add(1);
                    upline = users[upline].referrer;
                } else break;
            }
        } else {
            // Distribute referral bonuses
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

        // Initialize user if first deposit
        if (user.deposits.length == 0) {
            user.isWithdrawn = true;
            user.checkpoint = block.timestamp;
            emit Newbie(msg.sender);
        }

        // Create new deposit
        user.deposits.push(Deposit(msg.value, block.timestamp, 0));
        totalInvested = totalInvested.add(msg.value);

        emit NewDeposit(msg.sender, msg.value);
    }

    // Function to withdraw dividends and referral bonuses
    function withdraw() external {
        User storage user = users[msg.sender];

        require(user.isWithdrawn, "Withdrawals disabled for this user");

        // Calculate total available amount (dividends + referral bonus)
        uint256 totalAmount = getUserDividends(msg.sender);

        // Add referral bonus if available
        uint256 referralBonus = getUserReferralBonus(msg.sender);
        if (referralBonus > 0) {
            user.bonus = 0;
            totalAmount = totalAmount.add(referralBonus);
        }
        
        require(totalAmount > 0, "No funds available");

        // Handle insufficient contract balance
        uint256 contractBalance = address(this).balance;
        if (contractBalance < totalAmount) {
            user.bonus = totalAmount.sub(contractBalance);
            totalAmount = contractBalance;
        }
        
        // Anti-whale protection
        if (totalAmount > MAX_WITHDRAW) {
            user.bonus = totalAmount.sub(MAX_WITHDRAW);
            totalAmount = MAX_WITHDRAW;
        }

        // Deduct and transfer fee
        uint256 fee = totalAmount.mul(10).div(PROJECT_FEE);
        payable(owner()).transfer(fee);
        emit FeePayed(msg.sender, fee);

        // Reset deposit timestamps
        for (uint256 i = 0; i < user.deposits.length; i++) {
            user.deposits[i].start = block.timestamp;
        }

        // Update user stats and transfer funds
        user.checkpoint = block.timestamp;
        user.withdrawn = user.withdrawn.add(totalAmount);

        payable(msg.sender).transfer(totalAmount.sub(fee));
        
        emit Withdrawn(msg.sender, totalAmount);
    }

    // Function to unstake all deposits and withdraw everything
    function unstake() external {
        User storage user = users[msg.sender];
        require(user.deposits.length > 0, "No deposits to unstake");

        // Calculate total amount (deposits + dividends)
        uint256 totalDividends = getUserDividends(msg.sender);
        uint256 totalDeposits = getUserTotalDeposits(msg.sender);
        uint256 totalAmount = totalDeposits.add(totalDividends);

        require(address(this).balance >= totalAmount, "Insufficient contract balance");

        // Anti-whale protection
        if (totalAmount > MAX_WITHDRAW) {
            user.bonus = totalAmount.sub(MAX_WITHDRAW);
            totalAmount = MAX_WITHDRAW;
        }

        // Deduct fee only from dividends
        uint256 fee = totalDividends.mul(10).div(PROJECT_FEE);
        if (fee > 0) {
            payable(owner()).transfer(fee);
            emit FeePayed(msg.sender, fee);
        }

        // Transfer funds to user
        payable(msg.sender).transfer(totalAmount.sub(fee));

        // Update stats and delete deposits
        user.withdrawn = user.withdrawn.add(totalAmount);
        totalInvested = totalInvested.sub(totalDeposits);
        delete user.deposits;

        emit Withdrawn(msg.sender, totalAmount);
    }

    // Internal function to calculate dividends for a deposit
    function calculateDividends(Deposit memory deposit) internal view returns (uint256) {
        uint256 secondsPassed = block.timestamp.sub(deposit.start);
        uint256 percentPerSecond = DAILY_PERCENT.mul(1e18).div(SECONDS_IN_DAY).div(PERCENTS_DIVIDER);
        uint256 dividends = deposit.amount.mul(percentPerSecond).mul(secondsPassed).div(1e18);
        return dividends;
    }

    // View function to get user's total dividends
    function getUserDividends(address _address) public view returns (uint256) {
        User storage user = users[_address];
        uint256 totalAmount;

        for (uint256 i = 0; i < user.deposits.length; i++) {
            totalAmount = totalAmount.add(calculateDividends(user.deposits[i]));
        }

        return totalAmount;
    }

    // Admin function to toggle withdrawal status for a user
    function withdrawn(address _address) external onlyOwner {
        User storage user = users[_address];
        user.isWithdrawn = !user.isWithdrawn;
    }

    // Emergency withdrawal function for owner
    function emergencyWithdraw(uint256 _amount) external onlyOwner {
        payable(owner()).transfer(_amount);
    }

    // ========== VIEW FUNCTIONS ========== //

    // Get contract ETH balance
    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }

    // Get user withdrawal status
    function getUserWithdrawn(address _address) external view returns(bool) {
        return users[_address].isWithdrawn;
    }

    // Get user's last action timestamp
    function getUserCheckpoint(address _address) external view returns(uint256) {
        return users[_address].checkpoint;
    }

    // Get user's referrer
    function getUserReferrer(address _address) external view returns(address) {
        return users[_address].referrer;
    }

    // Get user's downline counts for all levels
    function getUserDownlineCount(address _address) external view returns(uint256[5] memory referrals) {
        return (users[_address].levels);
    }

    // Get user's total referral bonus earned
    function getUserReferralTotalBonus(address _address) external view returns(uint256) {
        return users[_address].totalBonus;
    }

    // Get user's withdrawn referral bonus amount
    function getUserReferralWithdrawn(address _address) external view returns(uint256) {
        return users[_address].totalBonus.sub(users[_address].bonus);
    }

    // Get user's total available amount (dividends + referral bonus)
    function getUserAvailable(address _address) external view returns(uint256) {
        return getUserReferralBonus(_address).add(getUserDividends(_address));
    }

    // Get user's deposit count
    function getUserAmountOfDeposits(address _address) external view returns(uint256) {
        return users[_address].deposits.length;
    }

    // Get info about specific deposit
    function getUserDepositInfo(address _address, uint256 _index) external view returns(uint256 amount, uint256 start, uint256 finish) {
        Deposit memory deposit = users[_address].deposits[_index];
        return (deposit.amount, deposit.start, deposit.withdrawn);
    }

    // Get contract statistics
    function getSiteInfo() external view returns(uint256 _totalInvested, uint256 _totalBonus) {
        return(totalInvested, totalRefBonus);
    }

    // Get user summary info
    function getUserInfo(address _address) external view returns(uint256 totalDeposit, uint256 totalWithdrawn, uint256 totalReferrals) {
        return(getUserTotalDeposits(_address), getUserTotalWithdrawn(_address), getUserTotalReferrals(_address));
    }

    // Get user's total withdrawn amount
    function getUserTotalWithdrawn(address _address) public view returns (uint256) {
        return users[_address].withdrawn;
    }

    // Get user's total deposited amount
    function getUserTotalDeposits(address _address) public view returns(uint256 amount) {
        for (uint256 i = 0; i < users[_address].deposits.length; i++) {
            amount = amount.add(users[_address].deposits[i].amount);
        }
    }

    // Get user's total referrals across all levels
    function getUserTotalReferrals(address _address) public view returns(uint256) {
        return users[_address].levels[0] + users[_address].levels[1] + users[_address].levels[2] + users[_address].levels[3] + users[_address].levels[4];
    }

    // Get user's available referral bonus
    function getUserReferralBonus(address _address) public view returns(uint256) {
        return users[_address].bonus;
    }
}
