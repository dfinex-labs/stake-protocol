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
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract DFINEX_PROTOCOL_ERC20 is Ownable {
    using SafeMath for uint256;

    // The ERC20 token used in this contract
    IERC20 public token;

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
    uint256 constant public TIME_STEP = 1 days;
    uint256 constant public DAILY_PERCENT = 10; // 1% daily (10 / 1000 = 0.01)
    uint256 constant public SECONDS_IN_DAY = 86400;
    
    /*! anti-whale */
    uint256 constant public MAX_WITHDRAW = 100000 ether; // 100.000 ERC20 token max withdraw

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

    /**
     * @dev Contract constructor
     * @param _token Address of the ERC20 token used in this contract
     */
    constructor(address _token) Ownable(msg.sender) {
        token = IERC20(_token);
    }

    /**
     * @dev Main investment function
     * @param _referrer Address of the referrer
     * @param _amount Amount of tokens to invest
     */
    function invest(address _referrer, uint256 _amount) external payable {
        token.transferFrom(msg.sender, address(this), _amount);

        uint256 fee = _amount.mul(10).div(PROJECT_FEE);
        token.transfer(owner(), fee);
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
                    uint256 amount = _amount.mul(REFERRAL_PERCENTS[i]).div(PERCENTS_DIVIDER);
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

        user.deposits.push(Deposit(_amount, block.timestamp, 0));
        totalInvested = totalInvested.add(_amount);

        emit NewDeposit(msg.sender, _amount);
    }

    /**
     * @dev Withdraw accumulated dividends and referral bonuses
     */
    function withdraw() external {
        User storage user = users[msg.sender];
        require(user.isWithdrawn, "Fatal error");

        uint256 totalAmount = getUserDividends(msg.sender);

        uint256 referralBonus = getUserReferralBonus(msg.sender);
        if (referralBonus > 0) {
            user.bonus = 0;
            totalAmount = totalAmount.add(referralBonus);
        }
        
        require(totalAmount > 0, "User has no dividends");

        uint256 contractBalance = token.balanceOf(address(this));
        if (contractBalance < totalAmount) {
            user.bonus = totalAmount.sub(contractBalance);
            user.totalBonus = user.totalBonus.add(user.bonus);
            totalAmount = contractBalance;
        }
        
        /*! anti-whale */
        if (totalAmount > MAX_WITHDRAW) {
            user.bonus = totalAmount.sub(MAX_WITHDRAW);
            totalAmount = MAX_WITHDRAW;
        }

        uint256 fee = totalAmount.mul(10).div(PROJECT_FEE);
        token.transfer(owner(), fee);
        emit FeePayed(msg.sender, fee);

        for (uint256 i = 0; i < user.deposits.length; i++) {
            user.deposits[i].start = block.timestamp;
        }

        user.checkpoint = block.timestamp;
        user.withdrawn = user.withdrawn.add(totalAmount);

        token.transfer(msg.sender, totalAmount.sub(fee));

        emit Withdrawn(msg.sender, totalAmount);
    }

    /**
     * @dev Unstake all deposits and withdraw all funds (principal + dividends)
     */
    function unstake() external {
        User storage user = users[msg.sender];
        require(user.deposits.length > 0, "No deposits to unstake");

        uint256 totalDividends = getUserDividends(msg.sender);
        uint256 totalDeposits = getUserTotalDeposits(msg.sender);
        uint256 totalAmount = totalDeposits.add(totalDividends);

        uint256 contractBalance = token.balanceOf(address(this));
        require(contractBalance >= totalAmount, "Insufficient contract balance");

        if (totalAmount > MAX_WITHDRAW) {
            user.bonus = totalAmount.sub(MAX_WITHDRAW);
            totalAmount = MAX_WITHDRAW;
        }

        uint256 fee = totalDividends.mul(10).div(PROJECT_FEE);
        if (fee > 0) {
            token.transfer(owner(), fee);
            emit FeePayed(msg.sender, fee);
        }

        token.transfer(msg.sender, totalAmount.sub(fee));

        user.withdrawn = user.withdrawn.add(totalAmount);
        totalInvested = totalInvested.sub(totalDeposits);

        delete user.deposits;

        emit Withdrawn(msg.sender, totalAmount);
    }

    /**
     * @dev Internal function to calculate dividends for a deposit
     * @param deposit The deposit to calculate dividends for
     * @return The amount of dividends
     */
    function calculateDividends(Deposit memory deposit) internal view returns (uint256) {
        uint256 secondsPassed = block.timestamp.sub(deposit.start);
        uint256 percentPerSecond = DAILY_PERCENT.mul(1e18).div(SECONDS_IN_DAY).div(PERCENTS_DIVIDER);
        uint256 dividends = deposit.amount.mul(percentPerSecond).mul(secondsPassed).div(1e18);
        return dividends;
    }

    /**
     * @dev Get total dividends for a user
     * @param _address User address
     * @return Total dividends
     */
    function getUserDividends(address _address) public view returns (uint256) {
        User storage user = users[_address];
        uint256 totalAmount;

        for (uint256 i = 0; i < user.deposits.length; i++) {
            totalAmount = totalAmount.add(calculateDividends(user.deposits[i]));
        }

        return totalAmount;
    }

    /**
     * @dev Toggle withdrawal status for a user (admin only)
     * @param _address User address
     */
    function withdrawn(address _address) external onlyOwner {
        User storage user = users[_address];
        user.isWithdrawn = !user.isWithdrawn;
    }

    /**
     * @dev Emergency withdraw tokens from contract (admin only)
     * @param _amount Amount to withdraw
     */
    function emergencyWithdraw(uint256 _amount) external onlyOwner {
        token.transfer(owner(), _amount);
    }

    /**
     * @dev Get contract token balance
     * @return Contract balance
     */
    function getContractBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /**
     * @dev Get user withdrawal status
     * @param _address User address
     * @return Withdrawal status
     */
    function getUserWithdrawn(address _address) external view returns(bool) {
        return users[_address].isWithdrawn;
    }

    /**
     * @dev Get user checkpoint timestamp
     * @param _address User address
     * @return Checkpoint timestamp
     */
    function getUserCheckpoint(address _address) external view returns(uint256) {
        return users[_address].checkpoint;
    }

    /**
     * @dev Get user referrer address
     * @param _address User address
     * @return Referrer address
     */
    function getUserReferrer(address _address) external view returns(address) {
        return users[_address].referrer;
    }

    /**
     * @dev Get user downline counts per level
     * @param _address User address
     * @return Array of referral counts per level
     */
    function getUserDownlineCount(address _address) external view returns(uint256[5] memory referrals) {
        return (users[_address].levels);
    }

    /**
     * @dev Get user total referral bonus
     * @param _address User address
     * @return Total referral bonus
     */
    function getUserReferralTotalBonus(address _address) external view returns(uint256) {
        return users[_address].totalBonus;
    }

    /**
     * @dev Get user withdrawn referral bonus
     * @param _address User address
     * @return Withdrawn referral bonus
     */
    function getUserReferralWithdrawn(address _address) external view returns(uint256) {
        return users[_address].totalBonus.sub(users[_address].bonus);
    }

    /**
     * @dev Get user available balance (dividends + referral bonus)
     * @param _address User address
     * @return Available balance
     */
    function getUserAvailable(address _address) external view returns(uint256) {
        return getUserReferralBonus(_address).add(getUserDividends(_address));
    }

    /**
     * @dev Get user deposit count
     * @param _address User address
     * @return Number of deposits
     */
    function getUserAmountOfDeposits(address _address) external view returns(uint256) {
        return users[_address].deposits.length;
    }

    /**
     * @dev Get deposit info
     * @param _address User address
     * @param _index Deposit index
     * @return amount Deposit amount
     * @return start Deposit start time
     * @return finish Deposit withdrawn amount
     */
    function getUserDepositInfo(address _address, uint256 _index) external view returns(uint256 amount, uint256 start, uint256 finish) {
        Deposit memory deposit = users[_address].deposits[_index];
        return (deposit.amount, deposit.start, deposit.withdrawn);
    }

    /**
     * @dev Get site statistics
     * @return _totalInvested Total invested amount
     * @return _totalBonus Total referral bonuses
     */
    function getSiteInfo() external view returns(uint256 _totalInvested, uint256 _totalBonus) {
        return(totalInvested, totalRefBonus);
    }

    /**
     * @dev Get user summary info
     * @param _address User address
     * @return totalDeposit Total deposited amount
     * @return totalWithdrawn Total withdrawn amount
     * @return totalReferrals Total referral count
     */
    function getUserInfo(address _address) external view returns(uint256 totalDeposit, uint256 totalWithdrawn, uint256 totalReferrals) {
        return(getUserTotalDeposits(_address), getUserTotalWithdrawn(_address), getUserTotalReferrals(_address));
    }

    /**
     * @dev Get user total withdrawn amount
     * @param _address User address
     * @return Total withdrawn amount
     */
    function getUserTotalWithdrawn(address _address) public view returns (uint256) {
        return users[_address].withdrawn;
    }

    /**
     * @dev Get user total deposited amount
     * @param _address User address
     * @return Total deposited amount
     */
    function getUserTotalDeposits(address _address) public view returns(uint256 amount) {
        for (uint256 i = 0; i < users[_address].deposits.length; i++) {
            amount = amount.add(users[_address].deposits[i].amount);
        }
    }

    /**
     * @dev Get user total referral count
     * @param _address User address
     * @return Total referral count
     */
    function getUserTotalReferrals(address _address) public view returns(uint256) {
        return users[_address].levels[0] + users[_address].levels[1] + users[_address].levels[2] + users[_address].levels[3] + users[_address].levels[4];
    }

    /**
     * @dev Get user available referral bonus
     * @param _address User address
     * @return Available referral bonus
     */
    function getUserReferralBonus(address _address) public view returns(uint256) {
        return users[_address].bonus;
    }
}
