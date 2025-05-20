// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IPulseXFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPulseXRouter {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256 amountB);
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

interface IPulseXPair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
}

contract xBOND is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Errors
    error ZeroAmount();
    error BelowMinimumShareAmount();
    error InsufficientBalance();
    error ZeroSupply();
    error ZeroAddress();
    error IssuancePeriodEnded();
    error InvalidTokenDecimals();
    error InsufficientContractBalance();
    error PoolAlreadyExists();
    error InsufficientInitialLiquidity();
    error NoPoolCreated();
    error PoolCreationFailed();
    error InsufficientAllowance();
    error WithdrawalPeriodNotElapsed();
    error InsufficientLiquidity();
    error InsufficientFee();
    error InsufficientTransferAmount();
    error InsufficientSwapOutput();
    error SwapFailed();

    // Immutable state variables
    address private immutable _pulseXFactory = 0x1715a3E4A142d8b698131108995174F37aEBA10D;
    address private immutable _pulseXRouter = 0x98bf93ebf5c380C0e6Ae8e192A7e2AE08edAcc02;
    address private immutable _plsx = 0x95B303987A60C71504D99Aa1b13B4DA07b0790ab;
    address private immutable _creator;
    uint48 private immutable _deploymentTime;

    // Mutable state variables
    address private _pairAddress;
    address[2] private _swapPath; // [0] = tokenIn, [1] = tokenOut
    uint256 private _lastLiquidityWithdrawal;
    // Bitfield for contract state: Bit 0 = poolCreated (1 if pool exists), Bit 1 = isXBONDToken0 (1 if xBOND is token0 in pair)
    uint256 private _stateFlags;
    uint256 private totalBurned; // Tracks total xBOND burned
    uint256 private totalPLSXTaxed; // Tracks total PLSX from tax swaps

    // Constants
    // 5% fee for share issuance after pool creation
    uint16 private constant _STRATEGY_FEE_BASIS_POINTS = 500;
    // 50% fee for initial share issuance to bootstrap liquidity pool
    uint16 private constant _INITIAL_FEE_BASIS_POINTS = 5000;
    // 5% tax on transfers, distributed as 5% to creator, 20% burned, 75% swapped to PLSX
    uint16 private constant _TRANSFER_TAX_BASIS_POINTS = 500;
    uint256 private constant _MIN_SHARE_AMOUNT = 10e18;
    uint256 private constant _ISSUANCE_PERIOD = 90 days;
    uint256 private constant _MIN_INITIAL_LIQUIDITY = 10e18;
    uint16 private constant _MIN_OUTPUT_PERCENTAGE = 90; // 90%
    uint16 private constant _BASIS_POINTS_DENOMINATOR = 1e4; // 10000
    uint16 private constant _PERCENTAGE_DENOMINATOR = 100; // 100
    uint16 private constant _CREATOR_SHARE_PERCENT = 5; // 5%
    uint16 private constant _BURN_SHARE_PERCENT = 20; // 20%
    uint16 private constant _SWAP_SHARE_PERCENT = 75; // 75%
    uint256 private constant _WITHDRAWAL_PERIOD = 90 days;
    uint16 private constant _WITHDRAWAL_PERCENTAGE = 1250; // 12.5%
    uint256 private constant _SWAP_DEADLINE = 5 minutes;
    uint256 private constant _POOL_CREATED_BIT = 1;
    uint256 private constant _IS_XBOND_TOKEN0_BIT = 2;
    uint256 private constant _MIN_TRANSFER_AMOUNT = 1000e18; // Minimum transfer amount (1000 xBOND)

    // Struct for liquidity parameters
    struct TokenOrder {
        address tokenA;
        address tokenB;
        uint256 amountADesired;
        uint256 amountBDesired;
    }

    // Events
    event SharesIssuedWithLiquidity(
        address indexed buyer,
        uint256 shares,
        uint256 totalFee,
        uint256 liquidityAdded,
        address pair,
        bool isXBONDToken0
    );
    event SharesRedeemed(address indexed redeemer, uint256 shares, uint256 plsx);
    event LiquidityWithdrawnAndReinvested(
        address indexed caller,
        uint256 lpTokensWithdrawn,
        uint256 xBONDAmount,
        uint256 plsxAmount,
        uint256 plsxFromSwap,
        uint256 totalPLSXAdded,
        uint256 remainingLPBalance // Added: Remaining LP tokens held by contract
    );
    event PoolStateUpdated(address indexed pairAddress, bool poolCreated, bool isXBONDToken0);
    event TransferTaxApplied(
        address indexed from,
        address indexed to,
        uint256 amountAfterTax,
        uint256 creatorShare,
        uint256 burnShare,
        uint256 swapShare
    );
    event PoolCreatedAndLiquidityAdded(
        address indexed pair,
        uint256 liquidity,
        bool isXBONDToken0,
        uint256 xBONDAmount,
        uint256 plsxAmount
    );

    constructor() ERC20("xBOND", "xBOND") {
        if (_pulseXFactory == address(0) || _pulseXRouter == address(0) || _plsx == address(0))
            revert ZeroAddress();
        if (IERC20Metadata(_plsx).decimals() != 18) revert InvalidTokenDecimals();
        _creator = msg.sender;
        _deploymentTime = uint48(block.timestamp);
        _lastLiquidityWithdrawal = block.timestamp;
    }

    // Internal: Optimize token allowance to minimize gas
    function _optimizeAllowance(address token, address spender, uint256 amount) internal {
        uint256 currentAllowance = IERC20(token).allowance(address(this), spender);
        if (currentAllowance < amount) {
            SafeERC20.safeIncreaseAllowance(IERC20(token), spender, amount - currentAllowance);
        }
    }

    // Internal: Update balances without emitting Transfer event
    function _update(address from, address to, uint256 amount) internal virtual override {
        if (from != address(0)) {
            uint256 fromBalance = balanceOf(from);
            if (fromBalance < amount) revert InsufficientBalance();
        }
        super._update(from, to, amount);
    }

    // Internal: Get token order for liquidity operations
    function _getTokenOrderParams(
        uint256 xBONDAmount,
        uint256 plsxAmount
    ) internal view returns (TokenOrder memory order) {
        uint256 stateFlags = _stateFlags;
        bool isXBONDToken0 = (stateFlags & _IS_XBOND_TOKEN0_BIT) != 0;
        order = TokenOrder({
            tokenA: isXBONDToken0 ? address(this) : _plsx,
            tokenB: isXBONDToken0 ? _plsx : address(this),
            amountADesired: isXBONDToken0 ? xBONDAmount : plsxAmount,
            amountBDesired: isXBONDToken0 ? plsxAmount : xBONDAmount
        });
    }

    // Internal: Apply transfer tax and split according to distribution
    function _applyTransferTax(
        address from,
        address to,
        uint256 amount
    ) internal nonReentrant returns (uint256 amountAfterTax) {
        if (from == address(this) || to == address(this)) {
            _transfer(from, to, amount);
            return amount;
        }
        uint256 stateFlags = _stateFlags; // Cache stateFlags
        if ((stateFlags & _POOL_CREATED_BIT) == 0) revert NoPoolCreated();
        address pairAddress = _pairAddress;
        if (pairAddress == address(0)) revert ZeroAddress();

        // Calculate tax and distribution amounts
        uint256 tax;
        uint256 creatorShare;
        uint256 burnShare;
        uint256 swapShare;
        unchecked {
            tax = amount * _TRANSFER_TAX_BASIS_POINTS / _BASIS_POINTS_DENOMINATOR;
            creatorShare = tax * _CREATOR_SHARE_PERCENT / _PERCENTAGE_DENOMINATOR;
            burnShare = tax * _BURN_SHARE_PERCENT / _PERCENTAGE_DENOMINATOR;
            swapShare = tax * _SWAP_SHARE_PERCENT / _PERCENTAGE_DENOMINATOR;
        }
        amountAfterTax = amount - tax;

        // Validate balance
        uint256 totalDebit = creatorShare + burnShare + amountAfterTax;
        if (balanceOf(from) < totalDebit) revert InsufficientBalance();

        // Perform transfers
        if (amountAfterTax > 0) _update(from, to, amountAfterTax);
        if (creatorShare > 0) _update(from, _creator, creatorShare);
        if (burnShare > 0) {
            _burn(from, burnShare);
            totalBurned += burnShare;
        }

        // Swap remaining tax to PLSX and revert if swap fails
        if (swapShare > 0) {
            (uint112 reserve0, uint112 reserve1, ) = IPulseXPair(pairAddress).getReserves();
            bool isXBONDToken0 = (stateFlags & _IS_XBOND_TOKEN0_BIT) != 0;
            uint256 plsxReceived = _swapToPLSX(swapShare, reserve0, reserve1, isXBONDToken0);
            if (plsxReceived == 0) revert SwapFailed();
        }

        emit TransferTaxApplied(from, to, amountAfterTax, creatorShare, burnShare, swapShare);
    }

    // Internal: Swap xBOND to PLSX
    function _swapToPLSX(
        uint256 xBONDAmount,
        uint112 reserve0,
        uint112 reserve1,
        bool isXBONDToken0
    ) internal returns (uint256) {
        if (xBONDAmount == 0) return 0;
        uint256 stateFlags = _stateFlags; // Cache stateFlags
        if ((stateFlags & _POOL_CREATED_BIT) == 0 || _swapPath[0] == address(0) || _swapPath[1] == address(0))
            revert NoPoolCreated();

        // Calculate minimum output using router's quote
        (uint256 reserveIn, uint256 reserveOut) = isXBONDToken0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
        uint256 amountOutMin = IPulseXRouter(_pulseXRouter)
            .quote(xBONDAmount, reserveIn, reserveOut)
            .mulDiv(_MIN_OUTPUT_PERCENTAGE, _PERCENTAGE_DENOMINATOR);
        if (amountOutMin == 0) revert InsufficientSwapOutput();

        // Perform swap
        address[] memory path = new address[](2);
        path[0] = _swapPath[0];
        path[1] = _swapPath[1];
        _optimizeAllowance(address(this), _pulseXRouter, xBONDAmount);
        uint256[] memory amounts = IPulseXRouter(_pulseXRouter).swapExactTokensForTokens(
            xBONDAmount,
            amountOutMin,
            path,
            address(this),
            block.timestamp + _SWAP_DEADLINE
        );
        if (amounts[1] == 0) revert SwapFailed();
        
        totalPLSXTaxed += amounts[1]; // Track PLSX received
        return amounts[1];
    }

    // Internal: Add fee to liquidity pool
    function _addFeeToLiquidity(uint256 xBONDAmount, uint256 plsxAmount) internal returns (uint256 liquidity) {
        address pairAddress = _pairAddress;
        if (pairAddress == address(0)) revert ZeroAddress();
        uint256 stateFlags = _stateFlags; // Cache stateFlags
        bool isXBONDToken0 = (stateFlags & _IS_XBOND_TOKEN0_BIT) != 0;
        (uint112 reserve0, uint112 reserve1, ) = IPulseXPair(pairAddress).getReserves();
        (uint256 reserveXBOND, uint256 reservePLSX) = isXBONDToken0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));

        // Calculate optimal amounts based on pool ratio
        uint256 xBONDAmountOptimal = reservePLSX == 0 ? xBONDAmount : plsxAmount.mulDiv(reserveXBOND, reservePLSX);
        uint256 plsxAmountOptimal = reserveXBOND == 0 ? plsxAmount : xBONDAmount.mulDiv(reservePLSX, reserveXBOND);
        
        // Use the smaller of the calculated amounts to avoid exceeding provided amounts
        if (xBONDAmountOptimal > xBONDAmount) {
            xBONDAmountOptimal = xBONDAmount;
            plsxAmountOptimal = xBONDAmount.mulDiv(reservePLSX, reserveXBOND);
        } else if (plsxAmountOptimal > plsxAmount) {
            plsxAmountOptimal = plsxAmount;
            xBONDAmountOptimal = plsxAmount.mulDiv(reserveXBOND, reservePLSX);
        }

        // Prepare liquidity parameters
        TokenOrder memory order = _getTokenOrderParams(xBONDAmountOptimal, plsxAmountOptimal);

        // Track xBOND balance before adding liquidity
        uint256 xBONDBalanceBefore = balanceOf(address(this));

        // Add liquidity with optimized approvals
        _optimizeAllowance(order.tokenA, _pulseXRouter, order.amountADesired);
        _optimizeAllowance(order.tokenB, _pulseXRouter, order.amountBDesired);
        (,, liquidity) = IPulseXRouter(_pulseXRouter).addLiquidity(
            order.tokenA,
            order.tokenB,
            order.amountADesired,
            order.amountBDesired,
            order.amountADesired.mulDiv(_MIN_OUTPUT_PERCENTAGE, _PERCENTAGE_DENOMINATOR),
            order.amountBDesired.mulDiv(_MIN_OUTPUT_PERCENTAGE, _PERCENTAGE_DENOMINATOR),
            address(this),
            block.timestamp + _SWAP_DEADLINE
        );
        if (liquidity == 0) revert InsufficientLiquidity();

        // Burn excess xBOND
        uint256 xBONDBalanceAfter = balanceOf(address(this));
        if (xBONDBalanceAfter > xBONDBalanceBefore) {
            uint256 excessXBOND = xBONDBalanceAfter - xBONDBalanceBefore;
            _burn(address(this), excessXBOND);
            totalBurned += excessXBOND;
        }
    }

    // Internal: Create pool and add initial liquidity
    function _createPoolAndAddLiquidity(uint256 plsxAmount, uint256 xBONDAmount) internal returns (uint256) {
        if (plsxAmount == 0 || xBONDAmount == 0) revert ZeroAmount();
        address pair = IPulseXFactory(_pulseXFactory).getPair(address(this), _plsx);
        if (pair != address(0)) revert PoolAlreadyExists();
        pair = IPulseXFactory(_pulseXFactory).createPair(address(this), _plsx);
        if (pair == address(0)) revert PoolCreationFailed();

        // Set state
        _pairAddress = pair;
        bool isXBONDToken0 = IPulseXPair(pair).token0() == address(this);
        _stateFlags = (_stateFlags | _POOL_CREATED_BIT) |
            (isXBONDToken0 ? _IS_XBOND_TOKEN0_BIT : 0);
        _swapPath = [isXBONDToken0 ? address(this) : _plsx, isXBONDToken0 ? _plsx : address(this)];

        emit PoolStateUpdated(pair, true, isXBONDToken0);
        _mint(address(this), xBONDAmount);

        // Track xBOND balance before adding liquidity
        uint256 xBONDBalanceBefore = balanceOf(address(this));

        // Add liquidity
        TokenOrder memory order = _getTokenOrderParams(xBONDAmount, plsxAmount);
        _optimizeAllowance(order.tokenA, _pulseXRouter, order.amountADesired);
        _optimizeAllowance(order.tokenB, _pulseXRouter, order.amountBDesired);
        (,, uint256 liquidityReceived) = IPulseXRouter(_pulseXRouter).addLiquidity(
            order.tokenA,
            order.tokenB,
            order.amountADesired,
            order.amountBDesired,
            order.amountADesired.mulDiv(_MIN_OUTPUT_PERCENTAGE, _PERCENTAGE_DENOMINATOR),
            order.amountBDesired.mulDiv(_MIN_OUTPUT_PERCENTAGE, _PERCENTAGE_DENOMINATOR),
            address(this),
            block.timestamp + _SWAP_DEADLINE
        );

        // Burn excess xBOND
        uint256 xBONDBalanceAfter = balanceOf(address(this));
        if (xBONDBalanceAfter > xBONDBalanceBefore) {
            uint256 excessXBOND = xBONDBalanceAfter - xBONDBalanceBefore;
            _burn(address(this), excessXBOND);
            totalBurned += excessXBOND;
        }

        emit PoolCreatedAndLiquidityAdded(pair, liquidityReceived, isXBONDToken0, xBONDAmount, plsxAmount);
        return liquidityReceived;
    }

    // External: Transfer with tax
    function transfer(address to, uint256 amount) public override nonReentrant returns (bool) {
        if (amount < _MIN_TRANSFER_AMOUNT) revert InsufficientTransferAmount();
        if (to == address(0)) revert ZeroAddress();
        _applyTransferTax(msg.sender, to, amount);
        return true;
    }

    // External: Transfer from with tax
    function transferFrom(address from, address to, uint256 amount) public override nonReentrant returns (bool) {
        if (amount < _MIN_TRANSFER_AMOUNT) revert InsufficientTransferAmount();
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        uint256 allowed = allowance(from, msg.sender);
        if (allowed < amount) revert InsufficientAllowance();

        _applyTransferTax(from, to, amount);
        if (allowed != type(uint256).max) {
            _approve(from, msg.sender, allowed - amount);
        }
        return true;
    }

    // External: Issue shares with PLSX
    function issueShares(uint256 totalAmount) external nonReentrant {
        if (msg.sender == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert ZeroAmount();
        if (block.timestamp > _deploymentTime + _ISSUANCE_PERIOD) revert IssuancePeriodEnded();
        if (totalAmount < _MIN_INITIAL_LIQUIDITY) revert InsufficientInitialLiquidity();

        IERC20(_plsx).safeTransferFrom(msg.sender, address(this), totalAmount);
        uint16 feeBasisPoints = (_stateFlags & _POOL_CREATED_BIT) != 0
            ? _STRATEGY_FEE_BASIS_POINTS
            : _INITIAL_FEE_BASIS_POINTS;
        uint256 totalFee;
        unchecked {
            totalFee = totalAmount * feeBasisPoints / _BASIS_POINTS_DENOMINATOR;
        }
        if (totalFee == 0) revert InsufficientFee();
        uint256 shares = totalAmount - totalFee;
        if (shares < _MIN_SHARE_AMOUNT) revert BelowMinimumShareAmount();

        _mint(msg.sender, shares);
        uint256 liquidity;
        bool isNewPool = (_stateFlags & _POOL_CREATED_BIT) == 0;
        if (isNewPool) {
            uint256 plsxForLiquidity = totalFee / 2;
            uint256 xBONDFee = plsxForLiquidity;
            liquidity = _createPoolAndAddLiquidity(plsxForLiquidity, xBONDFee);
            if ((_stateFlags & _POOL_CREATED_BIT) == 0) revert PoolCreationFailed();
        } else {
            uint256 plsxFee = totalFee / 2;
            uint256 remainingFee = totalFee - plsxFee;
            uint256 contractPLSX = IERC20(_plsx).balanceOf(address(this));
            uint256 totalShares = totalSupply();
            uint256 xBONDFee = contractPLSX == 0 || totalShares == 0
                ? remainingFee
                : remainingFee.mulDiv(totalShares, contractPLSX);
            _mint(address(this), xBONDFee);
            liquidity = _addFeeToLiquidity(xBONDFee, plsxFee);
        }
        emit SharesIssuedWithLiquidity(
            msg.sender,
            shares,
            totalFee,
            liquidity,
            isNewPool ? _pairAddress : address(0),
            isNewPool ? ((_stateFlags & _IS_XBOND_TOKEN0_BIT) != 0) : false
        );
    }

    // External: Redeem shares for PLSX
    function redeemShares(uint256 amount) external nonReentrant {
        if (msg.sender == address(0)) revert ZeroAddress();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
        uint256 totalShares = totalSupply();
        if (totalShares == 0) revert ZeroSupply();
        uint256 contractBalance = IERC20(_plsx).balanceOf(address(this));
        if (contractBalance == 0) revert InsufficientContractBalance();
        uint256 plsxAmount;
        unchecked {
            plsxAmount = amount.mulDiv(contractBalance, totalShares);
        }
        if (plsxAmount == 0) revert InsufficientContractBalance();
        _burn(msg.sender, amount);
        IERC20(_plsx).safeTransfer(msg.sender, plsxAmount);
        emit SharesRedeemed(msg.sender, amount, plsxAmount);
    }

    // External: Withdraw 12.5% of liquidity pool tokens every 90 days, swap xBOND to PLSX, and hold PLSX in reserves to back xBOND shares
    function withdrawLiquidityAndReinvest() external nonReentrant {
        if (msg.sender == address(0)) revert ZeroAddress();
        uint256 stateFlags = _stateFlags; // Cache stateFlags
        if ((stateFlags & _POOL_CREATED_BIT) == 0) revert NoPoolCreated();
        if (block.timestamp < _lastLiquidityWithdrawal + _WITHDRAWAL_PERIOD)
            revert WithdrawalPeriodNotElapsed();
        address pairAddress = _pairAddress;
        if (pairAddress == address(0)) revert ZeroAddress();

        uint256 lpBalance = IERC20(pairAddress).balanceOf(address(this));
        uint256 lpToWithdraw;
        unchecked {
            lpToWithdraw = lpBalance * _WITHDRAWAL_PERCENTAGE / _BASIS_POINTS_DENOMINATOR;
        }
        if (lpToWithdraw == 0 || lpToWithdraw < _MIN_INITIAL_LIQUIDITY)
            revert InsufficientLiquidity();

        (uint112 reserve0, uint112 reserve1, ) = IPulseXPair(pairAddress).getReserves();
        bool isXBONDToken0 = (stateFlags & _IS_XBOND_TOKEN0_BIT) != 0;
        (uint256 amountAMin, uint256 amountBMin) = _calculateMinAmounts(
            lpToWithdraw,
            reserve0,
            reserve1,
            isXBONDToken0,
            IERC20(pairAddress).totalSupply()
        );

        _optimizeAllowance(pairAddress, _pulseXRouter, lpToWithdraw);
        (uint256 amountA, uint256 amountB) = IPulseXRouter(_pulseXRouter).removeLiquidity(
            IPulseXPair(pairAddress).token0(),
            IPulseXPair(pairAddress).token1(),
            lpToWithdraw,
            amountAMin,
            amountBMin,
            address(this),
            block.timestamp + _SWAP_DEADLINE
        );

        (uint256 xBONDAmount, uint256 plsxAmount) = isXBONDToken0
            ? (amountA, amountB)
            : (amountB, amountA);
        uint256 plsxFromSwap = _swapToPLSX(xBONDAmount, reserve0, reserve1, isXBONDToken0);

        _lastLiquidityWithdrawal = block.timestamp;
        uint256 remainingLPBalance = IERC20(pairAddress).balanceOf(address(this)); // Added: Track remaining LP balance
        emit LiquidityWithdrawnAndReinvested(
            msg.sender,
            lpToWithdraw,
            xBONDAmount,
            plsxAmount,
            plsxFromSwap,
            plsxAmount + plsxFromSwap,
            remainingLPBalance // Added: Emit remaining LP balance
        );
    }

    // Internal: Calculate minimum amounts for liquidity withdrawal
    function _calculateMinAmounts(
        uint256 lpToWithdraw,
        uint112 reserve0,
        uint112 reserve1,
        bool isXBONDToken0,
        uint256 lpTotalSupply
    ) internal pure returns (uint256 amountAMin, uint256 amountBMin) {
        if (lpTotalSupply == 0 || lpToWithdraw == 0) revert ZeroAmount();
        uint256 reserveA = isXBONDToken0 ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveB = isXBONDToken0 ? uint256(reserve1) : uint256(reserve0);
        amountAMin = lpToWithdraw.mulDiv(reserveA, lpTotalSupply);
        amountBMin = lpToWithdraw.mulDiv(reserveB, lpTotalSupply);
        unchecked {
            amountAMin = amountAMin * _MIN_OUTPUT_PERCENTAGE / _PERCENTAGE_DENOMINATOR;
            amountBMin = amountBMin * _MIN_OUTPUT_PERCENTAGE / _PERCENTAGE_DENOMINATOR;
        }
    }

    // View: Calculate shares received
    function calculateSharesReceived(uint256 totalAmount)
        public
        view
        returns (uint256 shares, uint256 totalFee)
    {
        if (totalAmount == 0 || ((_stateFlags & _POOL_CREATED_BIT) == 0 && totalAmount < _MIN_INITIAL_LIQUIDITY)) {
            return (0, 0);
        }
        uint16 feeBasisPoints = (_stateFlags & _POOL_CREATED_BIT) != 0
            ? _STRATEGY_FEE_BASIS_POINTS
            : _INITIAL_FEE_BASIS_POINTS;
        unchecked {
            totalFee = totalAmount * feeBasisPoints / _BASIS_POINTS_DENOMINATOR;
        }
        shares = totalAmount - totalFee;
        if (shares < _MIN_SHARE_AMOUNT) {
            return (0, 0);
        }
    }

    // View: Get user share balance
    function getUserShareInfo(address user) external view returns (uint256 shareBalance) {
        if (user == address(0)) revert ZeroAddress();
        shareBalance = balanceOf(user);
    }

    // View: Get contract info
    function getContractInfo() external view returns (uint256 contractBalance, uint256 remainingIssuancePeriod) {
        contractBalance = IERC20(_plsx).balanceOf(address(this));
        remainingIssuancePeriod = block.timestamp < _deploymentTime + _ISSUANCE_PERIOD
            ? _deploymentTime + _ISSUANCE_PERIOD - block.timestamp
            : 0;
    }

    // View: Get redeemable PLSX
    function getRedeemablePLSX(uint256 shareAmount) external view returns (uint256 plsxAmount) {
        uint256 totalShares = totalSupply();
        uint256 contractBalance = IERC20(_plsx).balanceOf(address(this));
        plsxAmount = (shareAmount == 0 || totalShares == 0) ? 0 : shareAmount.mulDiv(contractBalance, totalShares);
    }

    // View: Get PLSX backing ratio
    function getPLSXBackingRatio() external view returns (uint256) {
        uint256 totalShares = totalSupply();
        if (totalShares == 0) return 0;
        return IERC20(_plsx).balanceOf(address(this)).mulDiv(1e18, totalShares);
    }

    // View: Get pool address
    function getPoolAddress() external view returns (address) {
        return _pairAddress;
    }

    // View: Get pool liquidity (total xBOND and PLSX reserves in the pool)
    function getPoolLiquidity() external view returns (uint256 xBONDAmount, uint256 plsxAmount) {
        if (_pairAddress == address(0)) return (0, 0);
        (uint112 reserve0, uint112 reserve1, ) = IPulseXPair(_pairAddress).getReserves();
        bool isXBONDToken0 = (_stateFlags & _IS_XBOND_TOKEN0_BIT) != 0;
        return isXBONDToken0 ? (uint256(reserve0), uint256(reserve1)) : (uint256(reserve1), uint256(reserve0));
    }

    // View: Get pool depth ratio (PLSX reserves per LP token)
    function getPoolDepthRatio() external view returns (uint256) {
        if (_pairAddress == address(0)) return 0;
        (uint112 reserve0, uint112 reserve1, ) = IPulseXPair(_pairAddress).getReserves();
        bool isXBONDToken0 = (_stateFlags & _IS_XBOND_TOKEN0_BIT) != 0;
        uint256 plsxReserve = isXBONDToken0 ? uint256(reserve1) : uint256(reserve0);
        uint256 totalSupply = IERC20(_pairAddress).totalSupply();
        if (totalSupply == 0) return 0;
        return plsxReserve.mulDiv(1e18, totalSupply); // PLSX per LP token, scaled by 1e18
    }

    // View: Get held LP tokens
    function getHeldLPTokens() external view returns (uint256 heldLPTokens) {
        if ((_stateFlags & _POOL_CREATED_BIT) == 0) revert NoPoolCreated();
        heldLPTokens = IERC20(_pairAddress).balanceOf(address(this));
    }

    // View: Get LP token holder
    function getLPTokenHolder() external view returns (address) {
        return address(this);
    }

    // View: Get time until next withdrawal
    function getTimeUntilNextWithdrawal() external view returns (uint256) {
        return block.timestamp < _lastLiquidityWithdrawal + _WITHDRAWAL_PERIOD
            ? _lastLiquidityWithdrawal + _WITHDRAWAL_PERIOD - block.timestamp
            : 0;
    }

    // View: Get total xBOND burned
    function getTotalBurned() external view returns (uint256) {
        return totalBurned;
    }

    // View: Get total PLSX from tax swaps
    function getTotalPLSXTaxed() external view returns (uint256) {
        return totalPLSXTaxed;
    }
}