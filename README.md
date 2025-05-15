# xBOND Protocol
 
This readme provides a comprehensive overview of the xBOND protocol, its mechanics, and why it offers value to holders.



The protocol aims to create sustainable value for token holders by:

• Facilitating liquidity provision to a Pulsex liquidity pool (xBOND/PLSX pair).

• Implementing a tax mechanism on transfers to enhance liquidity and reward holders.

• Periodically withdrawing and reinvesting liquidity to optimize returns.

• Allowing users to redeem shares for underlying PLSX tokens.



# Core Features

• Token Issuance: Mint xBOND shares by depositing PLSX during a 90-day period.

• Liquidity Pool: Fees from deposits fund a xBOND/PLSX pool on PulseX.

• Transfer Tax: 5% tax on xBOND transfers (25% to PLSTR, 75% to PLSX an reinvested into reserves.

• Share Redemption: Redeem xBOND for proportional amount of PLSX in contract balance.

• Liquidity Reinvestment: public function allows Withdraw and reinvestment of 12.5% of LP tokens every 180 days.



# View Functions

• calculateSharesReceived: Shares and fees for PLSX deposit.

• getUserShareInfo: User’s xBOND balance.

• getContractInfo: PLSX balance and issuance period.

• getRedeemablePLSX: PLSX for share amount.

• getPLSXBackingRatio: PLSX per xBOND.

• getPoolAddress: Liquidity pool address.

• getPoolLiquidity: Pool reserves.

• getHeldLPTokens: Contract’s LP tokens.

• getTimeUntilNextWithdrawal: Time until next withdrawal.



# Why Invest in xBOND?



Passive Value Growth:

• The 5% transfer tax ensures continuous accumulation of PLSX in the contract,increasing the backing value of each XBOND share.

• liquidity withdrawal and reinvestment every 180 days optimize the contract's PLSX holdings, potentially enhancing redeemable value.



Liquidity Provision Benefits:

• By contributing to the xBOND/PLSX
liquidity pool,the protocol earns trading fees from Pulsex, indirectly benefiting holders through increased pool depth and stability.

• Deeper liquidity reduces slippage, making XBOND more attractive for trading.



Deflationary Mechanics:

• Share redemption burns xBOND tokens,reducing total supply and potentially Increasing the value of remaining tokens.

• Lower supply, combined with growing PLSX reserves, can enhance the per-share backing ratio.


 
Accessible Entry and Exit:

• Users can join during the 90-day issuance period with a reasonable minimum deposit (10 PLSX).

• Redemption is available anytime,
providing flexibility to exit with PLSX proportional to the contract's balance.

• Transparent operations via event logs and view functions build trust and engagement.



# Why xBOND Earns Value for Holders


Transfer Tax Redistribution:

• Every XBOND transfer incurs 5% tax, of which 75% is swapped for PLSX and held by the contract's reserves.

• This increases the contract's PLSX balance, directly boosting the redeemable value per xBOND share



Liquidity Withdrawal and Reinvestment:

• Every 180 days, 12.5% of LP tokens are withdrawn, yielding xBOND and PLSX.

• Withdrawn xBOND is swapped for PLSX, consolidating the contract's holdings into PLSX.

• This reinvestment increases the PLSX backing ratio, enhancing the value users can redeem per share.



Deflationary Pressure:

• Redeeming shares burns xBOND, reducing total supply.

• With a growing PLSX reserve, a
lower xBOND supply increases the PLSX per share, benefiting remaining holders.



Liquidity Pool Growth:

• Fees from share issuance and transfers are used to add liquidity, deepening the
xBOND/PLSX pool.

• A deeper pool attracts more trading volume, generating additional fees for LP token holders (the contract), which indirectly supports xBOND value.



Economic Incentives:

• Scarcity and Demand: Limited issuance (90 days) and burning via redemption create scarcity, potentially driving demand for xBOND.

• Passive Growth: Holders benefit without active management as taxes and reinvestments accrue value.

• Market Dynamics: The protocol's ability to swap xBOND for PLSX capitalizes on favorable market conditions, optimizing returns.



Getting Started

• Acquire PLSX: Obtain PLSX tokens on Pulsex or other supported platforms.

. Deposit PLSX: Call issueShares with at least 10 PLSX during the 90-day issuance period to receive XBOND shares.

Hold or Trade: Hold xBOND to benefit from tax accrual and reinvestments, or trade on PulseX
(note the 5% transfer tax).

• Redeem Shares: Call redeemShares to burn xBOND and receive PLSX anytime.

• Monitor Liquidity Events: Check
getTimeUntilNextWithdrawal to anticipate reinvestment cycles.



The xBOND protocol offers a compelling DeFi investment opportunity by combining liquidity provision, tax redistribution, and periodic reinvestment to create value for holders. 

Its transparent mechanics, secure design,and integration with PulseX make it an attractive option for both new and seasoned DeFi participants.

By holding xBOND, users can benefit from passive PLSX accumulation, deflationary tokenomics, and a growing liquidity pool, all while retaining the flexibility to redeem shares at any time.

License
MIT License. See LICENSE.

Contact
@PulseStrategy on X
