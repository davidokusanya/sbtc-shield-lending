;; sBTC Pegged Asset Lending Protocol (sPAL)
;; Bitcoin-Secured Debt Positions for Trustless Stablecoin Borrowing
;; Decentralized lending platform enabling sBTC holders to access liquidity while maintaining Bitcoin-grade security through Stacks L2

;; Constants
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-INSUFFICIENT-COLLATERAL (err u1001))
(define-constant ERR-LOAN-NOT-FOUND (err u1002))
(define-constant ERR-LOAN-UNDERCOLLATERALIZED (err u1003))
(define-constant ERR-COLLATERAL-BELOW-MINIMUM (err u1004))
(define-constant ERR-MAX-LOAN-EXCEEDED (err u1005))
(define-constant ERR-PRICE-STALE (err u1006))
(define-constant ERR-ZERO-AMOUNT (err u1007))
(define-constant ERR-PROTOCOL-PAUSED (err u1008))
(define-constant ERR-LIQUIDATION-FAILED (err u1009))

;; Data Variables
(define-data-var protocol-paused bool false)
(define-data-var governance-address principal 'SP000000000000000000002Q6VF78)
(define-data-var liquidation-threshold uint u150) ;; 150% = minimum collateral ratio required to avoid liquidation
(define-data-var collateralization-ratio uint u200) ;; 200% = required collateral ratio for new loans (higher than liquidation threshold)
(define-data-var liquidation-penalty uint u10) ;; 10% penalty on liquidated positions
(define-data-var minimum-collateral-amount uint u1000000) ;; Minimum amount in sats (0.01 BTC = 1,000,000 sats)
(define-data-var protocol-fee uint u1) ;; 1% fee on borrowed amount
(define-data-var price-stale-threshold uint u3600) ;; Price staleness threshold in seconds (1 hour)

;; SIP-010 Trait for Fungible Tokens
(use-trait ft-trait 'SP3FBR2AGK5H9QBDH3EEN6DF8EK8JY7RX8QJ5SVTE.sip-010-trait-ft-standard.sip-010-trait)

;; Oracle contract interface
(define-trait oracle-trait
  (
    (get-price-in-cents () (response uint uint))
    (get-last-update-time () (response uint uint))
  )
)

;; Maps for loans and collateral
(define-map user-collateral principal uint)
(define-map user-loan-amount principal uint)
(define-map user-last-interest-calc principal uint)

;; Public getters for loans and collateral
(define-read-only (get-user-collateral (user principal))
  (default-to u0 (map-get? user-collateral user))
)

(define-read-only (get-user-loan (user principal))
  (default-to u0 (map-get? user-loan-amount user))
)