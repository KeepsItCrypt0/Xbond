// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

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
}

contract xBOND is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

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
    error BelowMinimumRedemption();
    error WithdrawalPeriodNotElapsed();
    error InsufficientLiquidity();

    address private immutable _pulseXFactory;
    address private immutable _pulseXRouter;
    address private immutable _plsx;
    address private immutable _creator;
    uint48 private immutable _deploymentTime;
    uint256 private _stateFlags;
    address private _pairAddress;
    address[2] private _swapPath;
    uint256 private _lastLiquidityWithdrawal;

    uint16 private constant _STRATEGY_FEE_BASIS_POINTS = 500;
    uint16 private constant _INITIAL_FEE_BASIS_POINTS = 5000;
    uint16 private constant _TRANSFER_TAX_BASIS_POINTS = 500;
    uint256 private constant _MIN_SHARE_AMOUNT = 5000e18;
    uint256 private constant _ISSUANCE_PERIOD = 90 days;
    uint256 private constant _MIN_INITIAL_LIQUIDITY = 5000e18;
    uint256 private constant _MIN_OUTPUT_PERCENTAGE = 90;
    uint16 private constant _BASIS_POINTS_DENOMINATOR = 1e4;
    uint16 private constant _PERCENTAGE_DENOMINATOR = 100;
    uint16 private constant _CREATOR_SHARE_PERCENT = 25;
    uint256 private constant _DEADLINE_BUFFER = 300;
    uint256 private constant _IS_XBOND_TOKEN0_BIT = 2;
    uint256 private constant _WITHDRAWAL_PERIOD = 180 days;
    uint16 private constant _WITHDRAWAL_PERCENTAGE = 1250;

    struct TokenOrder {
        address tokenA;
        address tokenB;
        uint256 amountADesired;
        uint256 amountBDesired;
    }

    event SharesIssuedWithLiquidity(
        address indexed buyer,
        uint256 shares,
        uint256 totalFee,
        uint256 liquidityAdded
    );
    event SharesRedeemed(address indexed redeemer, uint256 shares, uint256 plsx);
    event TransferTaxCollected(
        address indexed from,
        address indexed to,
        uint256 taxAmount
    );
    event LiquidityPoolCreated(address indexed pair, uint256 xBONDAmount, uint256 plsxAmount, uint256 liquidity);
    event PoolStateUpdated(address indexed pairAddress, bool poolCreated, bool isXBONDToken0);
    event LiquidityWithdrawnAndReinvested(
        address indexed caller,
        uint256 lpTokensWithdrawn,
        uint256 xBONDAmount,
        uint256 plsxAmount,
        uint256 plsxFromSwap,
        uint256 totalPLSXAdded
    );

    constructor(
        address pulseXFactory,
        address pulseXRouter,
        address plsx
    ) ERC20("xBOND", "xBOND") {
        if (
            pulseXFactory == address(0) ||
            pulseXRouter == address(0) ||
            plsx == address(0)
        ) revert ZeroAddress();
        if (IERC20Metadata(plsx).decimals() != 18) revert InvalidTokenDecimals();
        _pulseXFactory = pulseXFactory;
        _pulseXRouter = pulseXRouter;
        _plsx = plsx;
        _creator = msg.sender;
        _deploymentTime = uint48(block.timestamp);
        _swapPath = [address(this), plsx];
        _lastLiquidityWithdrawal = block.timestamp;
    }

    function _getTokenOrderParams(
        address pair,
        uint256 xBONDAmount,
        uint256 plsxAmount
    ) internal view returns (TokenOrder memory order) {
        bool isXBONDToken0 = IPulseXPair(pair).token0() == address(this);
        order = TokenOrder({
            tokenA: isXBONDToken0 ? address(this) : _plsx,
            tokenB: isXBONDToken0 ? _plsx : address(this),
            amountADesired: isXBONDToken0 ? xBONDAmount : plsxAmount,
            amountBDesired: isXBONDToken0 ? plsxAmount : xBONDAmount
        });
    }

    function _applyTransferTax(
        address from,
        address to,
        uint256 amount
    ) internal nonReentrant returns (uint256 amountAfterTax) {
        if (from == address(this) || to == address(this)) {
            _transfer(from, to, amount);
            return amount;
        }
        if ((_stateFlags & 1) == 0) revert NoPoolCreated();
        if (_pairAddress == address(0)) revert ZeroAddress();

        // Calculate tax and creator share
        uint256 tax = amount.mulDiv(_TRANSFER_TAX_BASIS_POINTS, _BASIS_POINTS_DENOMINATOR);
        uint256 creatorShare = tax.mulDiv(_CREATOR_SHARE_PERCENT, _PERCENTAGE_DENOMINATOR);
        amountAfterTax = amount - tax;

        // Transfer creator share
        if (creatorShare > 0) {
            _transfer(from, _creator, creatorShare);
        }

        // Swap remaining tax to PLSX if applicable
        if (tax > creatorShare) {
            _swapTaxToPLSX(tax - creatorShare);
        }

        // Transfer the amount after tax to the recipient
        _transfer(from, to, amountAfterTax);
        emit TransferTaxCollected(from, to, tax);
        return amountAfterTax;
    }

    function _swapTaxToPLSX(uint256 taxAmount) private {
        bool isXBONDToken0 = (_stateFlags & _IS_XBOND_TOKEN0_BIT) != 0;
        (uint112 reserve0, uint112 reserve1, ) = IPulseXPair(_pairAddress).getReserves();
        (uint256 reserveIn, uint256 reserveOut) = isXBONDToken0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));

        // Approve tokens if needed
        if (IERC20(address(this)).allowance(address(this), _pulseXRouter) == 0) {
            SafeERC20.safeIncreaseAllowance(IERC20(address(this)), _pulseXRouter, type(uint256).max);
        }

        // Prepare swap path
        address[] memory path = new address[](2);
        path[0] = _swapPath[0];
        path[1] = _swapPath[1];

        // Calculate minimum output
        uint256 amountOutMin = IPulseXRouter(_pulseXRouter)
            .quote(taxAmount, reserveIn, reserveOut)
            .mulDiv(_MIN_OUTPUT_PERCENTAGE, _PERCENTAGE_DENOMINATOR);

        // Perform swap
        IPulseXRouter(_pulseXRouter).swapExactTokensForTokens(
            taxAmount,
            amountOutMin,
            path,
            address(this),
            block.timestamp + _DEADLINE_BUFFER
        );
    }

    function _addFeeToLiquidity(uint256 xBONDAmount, uint256 plsxAmount) internal returns (uint256 liquidity) {
        bool isXBONDToken0 = (_stateFlags & _IS_XBOND_TOKEN0_BIT) != 0;
        (uint112 reserve0, uint112 reserve1, ) = IPulseXPair(_pairAddress).getReserves();
        (uint256 reserveXBOND, uint256 reservePLSX) = isXBONDToken0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
        uint256 xBONDAmountAdjusted = reservePLSX == 0 || reserveXBOND == 0
            ? xBONDAmount
            : plsxAmount.mulDiv(reserveXBOND, reservePLSX);
        if (xBONDAmountAdjusted > xBONDAmount) {
            xBONDAmountAdjusted = xBONDAmount;
            plsxAmount = reserveXBOND == 0 ? plsxAmount : xBONDAmount.mulDiv(reservePLSX, reserveXBOND);
        }
        TokenOrder memory order = _getTokenOrderParams(_pairAddress, xBONDAmountAdjusted, plsxAmount);
        (,, liquidity) = IPulseXRouter(_pulseXRouter).addLiquidity(
            order.tokenA,
            order.tokenB,
            order.amountADesired,
            order.amountBDesired,
            order.amountADesired.mulDiv(_MIN_OUTPUT_PERCENTAGE, _PERCENTAGE_DENOMINATOR),
            order.amountBDesired.mulDiv(_MIN_OUTPUT_PERCENTAGE, _PERCENTAGE_DENOMINATOR),
            address(this),
            block.timestamp + _DEADLINE_BUFFER
        );
    }

    function _createPoolAndAddLiquidity(uint256 plsxAmount, uint256 xBONDAmount) internal {
        address pair = IPulseXFactory(_pulseXFactory).getPair(address(this), _plsx);
        if (pair != address(0)) revert PoolAlreadyExists();
        pair = IPulseXFactory(_pulseXFactory).createPair(address(this), _plsx);
        if (pair == address(0)) revert PoolCreationFailed();
        _pairAddress = pair;
        bool isXBONDToken0 = IPulseXPair(pair).token0() == address(this);
        _stateFlags = (_stateFlags | 1) & (isXBONDToken0 ? (_stateFlags | _IS_XBOND_TOKEN0_BIT) : (_stateFlags & ~uint256(_IS_XBOND_TOKEN0_BIT)));
        emit PoolStateUpdated(pair, true, isXBONDToken0);
        _mint(address(this), xBONDAmount);
        TokenOrder memory order = _getTokenOrderParams(pair, xBONDAmount, plsxAmount);
        if (IERC20(address(this)).allowance(address(this), _pulseXRouter) == 0) {
            SafeERC20.safeIncreaseAllowance(IERC20(address(this)), _pulseXRouter, type(uint256).max);
        }
        if (IERC20(_plsx).allowance(address(this), _pulseXRouter) == 0) {
            SafeERC20.safeIncreaseAllowance(IERC20(_plsx), _pulseXRouter, type(uint256).max);
        }
        (,, uint256 liquidityReceived) = IPulseXRouter(_pulseXRouter).addLiquidity(
            order.tokenA,
            order.tokenB,
            order.amountADesired,
            order.amountBDesired,
            order.amountADesired.mulDiv(_MIN_OUTPUT_PERCENTAGE, _PERCENTAGE_DENOMINATOR),
            order.amountBDesired.mulDiv(_MIN_OUTPUT_PERCENTAGE, _PERCENTAGE_DENOMINATOR),
            address(this),
            block.timestamp + _DEADLINE_BUFFER
        );
        emit LiquidityPoolCreated(pair, order.amountADesired, order.amountBDesired, liquidityReceived);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        uint256 amountAfterTax = _applyTransferTax(msg.sender, to, amount);
        _transfer(msg.sender, to, amountAfterTax);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (amount == 0) revert ZeroAmount();
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        uint256 allowed = allowance(from, msg.sender);
        if (allowed < amount) revert InsufficientAllowance();
        uint256 amountAfterTax = _applyTransferTax(from, to, amount);
        if (allowed != type(uint256).max) {
            _approve(from, msg.sender, allowed - amountAfterTax);
        }
        _transfer(from, to, amountAfterTax);
        return true;
    }

    function issueShares(uint256 totalAmount) external nonReentrant {
        if (msg.sender == address(0)) revert ZeroAddress();
        if (totalAmount == 0) revert ZeroAmount();
        if (block.timestamp > _deploymentTime + _ISSUANCE_PERIOD) revert IssuancePeriodEnded();
        if (totalAmount < _MIN_INITIAL_LIQUIDITY) revert InsufficientInitialLiquidity();
        IERC20(_plsx).safeTransferFrom(msg.sender, address(this), totalAmount);
        uint16 feeBasisPoints = (_stateFlags & 1) != 0 ? _STRATEGY_FEE_BASIS_POINTS : _INITIAL_FEE_BASIS_POINTS;
        uint256 totalFee = totalAmount.mulDiv(feeBasisPoints, _BASIS_POINTS_DENOMINATOR);
        uint256 shares = totalAmount - totalFee;
        if (shares < _MIN_SHARE_AMOUNT) revert BelowMinimumShareAmount();
        _mint(msg.sender, shares);
        uint256 liquidity;
        if ((_stateFlags & 1) == 0) {
            _createPoolAndAddLiquidity(totalFee, totalFee);
        } else if (totalFee > 0) {
            uint256 plsxFee = (totalFee + 1) >> 1;
            uint256 contractPLSX = IERC20(_plsx).balanceOf(address(this));
            uint256 totalShares = totalSupply();
            uint256 xBONDFee = contractPLSX == 0 || totalShares == 0 ? plsxFee : plsxFee.mulDiv(totalShares, contractPLSX);
            _mint(address(this), xBONDFee);
            liquidity = _addFeeToLiquidity(xBONDFee, plsxFee);
        }
        emit SharesIssuedWithLiquidity(msg.sender, shares, totalFee, liquidity);
    }

    function redeemShares(uint256 amount) external nonReentrant {
        if (msg.sender == address(0)) revert ZeroAddress();
        if (amount == 0) revert BelowMinimumRedemption();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
        uint256 totalShares = totalSupply();
        if (totalShares == 0) revert ZeroSupply();
        uint256 contractBalance = IERC20(_plsx).balanceOf(address(this));
        uint256 plsxAmount = amount.mulDiv(contractBalance, totalShares);
        if (plsxAmount == 0) revert InsufficientContractBalance();
        _burn(msg.sender, amount);
        IERC20(_plsx).safeTransfer(msg.sender, plsxAmount);
        emit SharesRedeemed(msg.sender, amount, plsxAmount);
    }

    function withdrawLiquidityAndReinvest() external nonReentrant {
        if (msg.sender == address(0)) revert ZeroAddress();
        if ((_stateFlags & 1) == 0) revert NoPoolCreated();
        if (block.timestamp < _lastLiquidityWithdrawal + _WITHDRAWAL_PERIOD) revert WithdrawalPeriodNotElapsed();
        if (_pairAddress == address(0)) revert ZeroAddress();

        uint256 lpBalance = IERC20(_pairAddress).balanceOf(address(this));
        if (lpBalance < _MIN_INITIAL_LIQUIDITY) revert InsufficientLiquidity();
        uint256 lpToWithdraw = lpBalance.mulDiv(_WITHDRAWAL_PERCENTAGE, _BASIS_POINTS_DENOMINATOR);
        if (lpToWithdraw == 0) revert ZeroAmount();

        if (IERC20(_pairAddress).allowance(address(this), _pulseXRouter) == 0) {
            SafeERC20.safeIncreaseAllowance(IERC20(_pairAddress), _pulseXRouter, type(uint256).max);
        }

        (uint112 reserve0, uint112 reserve1, ) = IPulseXPair(_pairAddress).getReserves();
        bool isXBONDToken0 = (_stateFlags & _IS_XBOND_TOKEN0_BIT) != 0;

        (uint256 amountAMin, uint256 amountBMin) = _calculateMinAmounts(
            lpToWithdraw,
            reserve0,
            reserve1,
            isXBONDToken0,
            IERC20(_pairAddress).totalSupply()
        );

        (uint256 amountA, uint256 amountB) = IPulseXRouter(_pulseXRouter).removeLiquidity(
            IPulseXPair(_pairAddress).token0(),
            IPulseXPair(_pairAddress).token1(),
            lpToWithdraw,
            amountAMin,
            amountBMin,
            address(this),
            block.timestamp + _DEADLINE_BUFFER
        );

        (uint256 xBONDAmount, uint256 plsxAmount) = isXBONDToken0
            ? (amountA, amountB)
            : (amountB, amountA);

        uint256 plsxFromSwap = _swapXBONDToPLSX(xBONDAmount, reserve0, reserve1, isXBONDToken0);

        _lastLiquidityWithdrawal = block.timestamp;
        emit LiquidityWithdrawnAndReinvested(
            msg.sender,
            lpToWithdraw,
            xBONDAmount,
            plsxAmount,
            plsxFromSwap,
            plsxAmount + plsxFromSwap
        );
    }

    function _calculateMinAmounts(
        uint256 lpToWithdraw,
        uint112 reserve0,
        uint112 reserve1,
        bool isXBONDToken0,
        uint256 lpTotalSupply
    ) internal pure returns (uint256 amountAMin, uint256 amountBMin) {
        uint256 reserveA = isXBONDToken0 ? uint256(reserve0) : uint256(reserve1);
        uint256 reserveB = isXBONDToken0 ? uint256(reserve1) : uint256(reserve0);
        amountAMin = lpToWithdraw.mulDiv(reserveA, lpTotalSupply)
            .mulDiv(_MIN_OUTPUT_PERCENTAGE, _PERCENTAGE_DENOMINATOR);
        amountBMin = lpToWithdraw.mulDiv(reserveB, lpTotalSupply)
            .mulDiv(_MIN_OUTPUT_PERCENTAGE, _PERCENTAGE_DENOMINATOR);
    }

    function _swapXBONDToPLSX(
        uint256 xBONDAmount,
        uint112 reserve0,
        uint112 reserve1,
        bool isXBONDToken0
    ) internal returns (uint256) {
        if (xBONDAmount == 0) return 0;

        if (IERC20(address(this)).allowance(address(this), _pulseXRouter) == 0) {
            SafeERC20.safeIncreaseAllowance(IERC20(address(this)), _pulseXRouter, type(uint256).max);
        }

        (uint256 reserveIn, uint256 reserveOut) = isXBONDToken0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
        uint256 expectedOut = IPulseXRouter(_pulseXRouter).quote(xBONDAmount, reserveIn, reserveOut);
        uint256 amountOutMin = expectedOut.mulDiv(_MIN_OUTPUT_PERCENTAGE, _PERCENTAGE_DENOMINATOR);

        address[] memory path = new address[](2);
        path[0] = _swapPath[0];
        path[1] = _swapPath[1];

        uint256[] memory amounts = IPulseXRouter(_pulseXRouter).swapExactTokensForTokens(
            xBONDAmount,
            amountOutMin,
            path,
            address(this),
            block.timestamp + _DEADLINE_BUFFER
        );
        return amounts[1];
    }

    function calculateSharesReceived(uint256 totalAmount)
        public
        view
        returns (uint256 shares, uint256 totalFee)
    {
        if (totalAmount == 0) return (0, 0);
        if ((_stateFlags & 1) == 0 && totalAmount < _MIN_INITIAL_LIQUIDITY) revert InsufficientInitialLiquidity();
        uint16 feeBasisPoints = (_stateFlags & 1) != 0 ? _STRATEGY_FEE_BASIS_POINTS : _INITIAL_FEE_BASIS_POINTS;
        totalFee = totalAmount.mulDiv(feeBasisPoints, _BASIS_POINTS_DENOMINATOR);
        shares = totalAmount - totalFee;
        if (shares < _MIN_SHARE_AMOUNT) revert BelowMinimumShareAmount();
    }

    function getUserShareInfo(address user) external view returns (uint256 shareBalance) {
        if (user == address(0)) revert ZeroAddress();
        shareBalance = balanceOf(user);
    }

    function getContractInfo() external view returns (
        uint256 contractBalance,
        uint256 remainingIssuancePeriod
    ) {
        contractBalance = IERC20(_plsx).balanceOf(address(this));
        remainingIssuancePeriod = block.timestamp < _deploymentTime + _ISSUANCE_PERIOD
            ? _deploymentTime + _ISSUANCE_PERIOD - block.timestamp
            : 0;
    }

    function getRedeemablePLSX(uint256 shareAmount) external view returns (uint256 plsxAmount) {
        uint256 totalShares = totalSupply();
        uint256 contractBalance = IERC20(_plsx).balanceOf(address(this));
        plsxAmount = (shareAmount == 0 || totalShares == 0) ? 0 : shareAmount.mulDiv(contractBalance, totalShares);
    }

    function getPLSXBackingRatio() external view returns (uint256) {
        uint256 totalShares = totalSupply();
        if (totalShares == 0) return 0;
        return IERC20(_plsx).balanceOf(address(this)).mulDiv(1e18, totalShares);
    }

    function getPoolAddress() external view returns (address) {
        return _pairAddress;
    }

    function getPoolLiquidity() external view returns (uint256 xBONDAmount, uint256 plsxAmount) {
        if (_pairAddress == address(0)) return (0, 0);
        (uint112 reserve0, uint112 reserve1, ) = IPulseXPair(_pairAddress).getReserves();
        bool isXBONDToken0 = (_stateFlags & _IS_XBOND_TOKEN0_BIT) != 0;
        return isXBONDToken0
            ? (uint256(reserve0), uint256(reserve1))
            : (uint256(reserve1), uint256(reserve0));
    }

    function getHeldLPTokens() external view returns (uint256 heldLPTokens) {
        if ((_stateFlags & 1) == 0) revert NoPoolCreated();
        if (_pairAddress == address(0)) revert ZeroAddress();
        heldLPTokens = IERC20(_pairAddress).balanceOf(address(this));
    }

    function getLPTokenHolder() external view returns (address) {
        return address(this);
    }

    function getTimeUntilNextWithdrawal() external view returns (uint256) {
        return block.timestamp < _lastLiquidityWithdrawal + _WITHDRAWAL_PERIOD
            ? _lastLiquidityWithdrawal + _WITHDRAWAL_PERIOD - block.timestamp
            : 0;
    }
}