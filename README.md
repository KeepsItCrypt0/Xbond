#xBOND Smart Contract

#Overview

xBOND is an PRC20 token contract on the PulseChain network. It integrates with the PulseX DEX to manage a xBOND/PLSX liquidity pool. 

Key features:

• Token Issuance: Mint xBOND shares by depositing PLSX during a 90-day period.

• Liquidity Pool: Fees from deposits fund a xBOND/PLSX pool on PulseX.

• Transfer Tax: 5% tax on xBOND transfers (25% to PLSTR, 75% swapped to PLSX an reinvested into reserves.

• Share Redemption: Redeem xBOND for proportional amount of PLSX in contract balance.

• Liquidity Reinvestment: public function allows Withdraw and reinvestment of 12.5% of LP tokens every 180 days.

Built with OpenZeppelin for security, including reentrancy protection and safe math.



View Functions

• calculateSharesReceived: Shares and fees for PLSX deposit.

• getUserShareInfo: User’s xBOND balance.

• getContractInfo: PLSX balance and issuance period.

• getRedeemablePLSX: PLSX for share amount.

• getPLSXBackingRatio: PLSX per xBOND.

• getPoolAddress: Liquidity pool address.

• getPoolLiquidity: Pool reserves.

• getHeldLPTokens: Contract’s LP tokens.

• getTimeUntilNextWithdrawal: Time until next withdrawal.

Security
• Reentrancy: Protected with ReentrancyGuard.

• Safe Math: Uses OpenZeppelin’s Math and SafeERC20.

• PulseX: Relies on trusted PulseX contracts.

• Validation: Enforces minimums and 18-decimal PLSX.

License
MIT License. See LICENSE.

Contact

@PulseStrategy on X
