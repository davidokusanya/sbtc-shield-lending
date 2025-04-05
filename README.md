# sBTC Pegged Asset Lending Protocol (sPAL) Documentation

## Overview

The sBTC Pegged Asset Lending Protocol (sPAL) is a decentralized lending platform enabling Bitcoin holders to access liquidity while maintaining Bitcoin-grade security through Stacks L2. This protocol allows users to:

- Deposit sBTC as collateral
- Borrow stablecoins against collateral
- Manage debt positions
- Participate in liquidations
- Govern protocol parameters

## Key Features

1. **Bitcoin-Secured Debt Positions**
2. **Trustless Stablecoin Borrowing**
3. **Decentralized Governance**
4. **Liquidation Mechanism**
5. **Protocol Fee Structure**
6. **Real-Time Price Oracle**
7. **Collateral Health Monitoring**

## Technical Specifications

### Constants

| Constant                      | Value   | Description                                 |
| ----------------------------- | ------- | ------------------------------------------- |
| `ERR-NOT-AUTHORIZED`          | u1000   | Authorization failure                       |
| `ERR-INSUFFICIENT-COLLATERAL` | u1001   | Insufficient collateral                     |
| `LIQUIDATION_THRESHOLD`       | 150%    | Minimum collateral ratio before liquidation |
| `COLLATERALIZATION_RATIO`     | 200%    | Required ratio for new loans                |
| `MIN_COLLATERAL`              | 1M sats | Minimum deposit (0.01 BTC)                  |

### Core Components

```clarity
(define-map user-collateral principal uint)
(define-map user-loan-amount principal uint)
(define-data-var protocol-fee uint u1) ;; 1% fee
```

## Contract Functions

### 1. Collateral Management

#### `deposit-collateral`

- **Params**: `sbtc-token`, `amount`
- **Purpose**: Lock sBTC as collateral
- **Checks**:
  - Protocol not paused
  - Valid SIP-010 token
  - Non-zero amount

#### `withdraw-collateral`

- **Params**: `sbtc-token`, `amount`
- **Requirements**:
  - Maintains collateralization ratio
  - Price freshness check
  - Minimum collateral balance

### 2. Loan Operations

#### `borrow`

- **Params**: `stablecoin`, `amount`
- **Mechanics**:
  1. Calculate max borrow amount:  
     `(collateral * price) / collateralization_ratio`
  2. Apply 1% protocol fee
  3. Mint stablecoins to borrower

#### `repay`

- **Params**: `stablecoin`, `amount`
- **Effects**:
  - Burns repaid stablecoins
  - Updates loan balance
  - Clears position if fully repaid

### 3. Liquidation Engine

#### `liquidate`

- **Params**: `user`, `sbtc-token`, `stablecoin`
- **Conditions**:
  - Collateral ratio < 150%
  - Fresh price data
  - 10% liquidation penalty

### 4. Governance Functions

| Function                    | Parameters | Governance Control |
| --------------------------- | ---------- | ------------------ |
| `set-governance-address`    | principal  | Owner/Governance   |
| `set-liquidation-threshold` | uint       | Governance         |
| `update-price`              | oracle     | Authorized Oracles |

## Security Architecture

### Key Protections

1. **Multi-Layer Authorization**

   - Governance functions restricted to `governance-address`
   - Oracle updates require privileged access

2. **Collateral Safeguards**

   ```clarity
   (asserts! (>= new-health collateralization-ratio) ;; 200% check
   (asserts! (>= collateral minimum-collateral-amount)) ;; 0.01 BTC floor
   ```

3. **Price Integrity**

   - Staleness threshold: 1 hour
   - Oracle validity checks

4. **Liquidation Incentives**
   - 10% penalty on liquidated positions
   - First-come liquidation system

## Usage Examples

### 1. Deposit & Borrow

```clarity
;; Deposit 0.05 BTC (5,000,000 sats)
(deposit-collateral sbtc-token u5000000)

;; Borrow 10,000 stablecoins (USD)
(borrow stablecoin-token u10000)
```

### 2. Repayment

```clarity
;; Repay 5,000 stablecoins
(repay stablecoin-token u5000)
```

### 3. Liquidation Call

```clarity
;; Liquidate undercollateralized position
(liquidate user-address sbtc-token stablecoin-token)
```

## Error Reference

| Code | Constant                    | Description                   |
| ---- | --------------------------- | ----------------------------- |
| 1000 | ERR-NOT-AUTHORIZED          | Unauthorized access attempt   |
| 1001 | ERR-INSUFFICIENT-COLLATERAL | Collateral below required     |
| 1006 | ERR-PRICE-STALE             | Oracle data older than 1 hour |
| 1009 | ERR-LIQUIDATION-FAILED      | Invalid liquidation attempt   |

## Governance Parameters

### Adjustable Settings

| Parameter             | Default  | Range    | Update Function             |
| --------------------- | -------- | -------- | --------------------------- |
| Liquidation Threshold | 150%     | 110-200% | `set-liquidation-threshold` |
| Protocol Fee          | 1%       | 0-5%     | Governance vote             |
| Minimum Collateral    | 0.01 BTC | Fixed    | Governance vote             |

## Deployment Notes

1. **Initialization**
   ```clarity
   (initialize governance-address-principal)
   ```
2. **Dependencies**

   - SIP-010 compliant sBTC token
   - Price oracle implementing `oracle-trait`
   - Stablecoin with mint/burn capabilities

3. **Upgrade Path**
   - Protocol designed for proxy pattern upgrades
   - Governance-controlled parameter changes
