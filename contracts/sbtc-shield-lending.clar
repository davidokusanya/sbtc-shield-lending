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

;; Get loan health percentage (collateral value / loan value * 100)
(define-read-only (get-loan-health (user principal) (oracle <oracle-trait>))
  (let (
    (collateral (get-user-collateral user))
    (loan (get-user-loan user))
    (price-response (contract-call? oracle get-price-in-cents))
    (last-update-response (contract-call? oracle get-last-update-time))
  )
    (if (is-err price-response)
      (err (unwrap-err price-response))
      (if (is-err last-update-response)
        (err (unwrap-err last-update-response))
        (let (
          (price-in-cents (unwrap! price-response ERR-PRICE-STALE))
          (last-update (unwrap! last-update-response ERR-PRICE-STALE))
          (current-time (get-block-info time (- block-height u1)))
        )
          (if (> (- current-time last-update) (var-get price-stale-threshold))
            ERR-PRICE-STALE
            (if (or (is-eq loan u0) (is-eq collateral u0))
              (ok u0)
              ;; Calculate loan health: (collateral * price) / (loan * 100) * 100
              (ok (/ (* (* collateral price-in-cents) u100) loan))
            )
          )
        )
      )
    )
  )
)

;; Check if loan is eligible for liquidation
(define-read-only (is-liquidatable (user principal) (oracle <oracle-trait>))
  (let ((health-response (get-loan-health user oracle)))
    (if (is-err health-response)
      true
      (< (unwrap! health-response ERR-LOAN-NOT-FOUND) (var-get liquidation-threshold))
    )
  )
)

;; Access control modifier for governance functions
(define-private (is-governance-or-owner)
  (or (is-eq tx-sender (var-get governance-address)) (is-eq tx-sender contract-owner))
)

;; Protocol governance functions
(define-public (set-governance-address (new-address principal))
  (begin
    (asserts! (is-governance-or-owner) ERR-NOT-AUTHORIZED)
    (ok (var-set governance-address new-address))
  )
)

(define-public (set-protocol-paused (paused bool))
  (begin
    (asserts! (is-governance-or-owner) ERR-NOT-AUTHORIZED)
    (ok (var-set protocol-paused paused))
  )
)

(define-public (set-liquidation-threshold (new-threshold uint))
  (begin
    (asserts! (is-governance-or-owner) ERR-NOT-AUTHORIZED)
    (asserts! (>= new-threshold u110) ERR-LOAN-UNDERCOLLATERALIZED) ;; minimum 110% threshold for safety
    (ok (var-set liquidation-threshold new-threshold))
  )
)

(define-public (set-collateralization-ratio (new-ratio uint))
  (begin
    (asserts! (is-governance-or-owner) ERR-NOT-AUTHORIZED)
    (asserts! (> new-ratio (var-get liquidation-threshold)) ERR-LOAN-UNDERCOLLATERALIZED)
    (ok (var-set collateralization-ratio new-ratio))
  )
)

;; Core lending protocol functions

;; Function to deposit sBTC as collateral
(define-public (deposit-collateral (sbtc-token <ft-trait>) (amount uint))
  (begin
    (asserts! (not (var-get protocol-paused)) ERR-PROTOCOL-PAUSED)
    (asserts! (> amount u0) ERR-ZERO-AMOUNT)
    
    ;; Transfer sBTC from user to contract
    (try! (contract-call? sbtc-token transfer amount tx-sender (as-contract tx-sender) none))
    
    ;; Update user's collateral
    (map-set user-collateral tx-sender (+ (get-user-collateral tx-sender) amount))
    
    (ok amount)
  )
)

;; Function to withdraw collateral (if no outstanding loans or sufficient collateral remaining)
(define-public (withdraw-collateral (sbtc-token <ft-trait>) (amount uint) (oracle <oracle-trait>))
  (begin
    (asserts! (not (var-get protocol-paused)) ERR-PROTOCOL-PAUSED)
    (asserts! (> amount u0) ERR-ZERO-AMOUNT)
    
    (let (
      (current-collateral (get-user-collateral tx-sender))
      (current-loan (get-user-loan tx-sender))
    )
      ;; Check if user has sufficient collateral
      (asserts! (>= current-collateral amount) ERR-INSUFFICIENT-COLLATERAL)
      
      ;; If there's an outstanding loan, verify collateralization requirements
      (if (> current-loan u0)
        (let (
          (new-collateral (- current-collateral amount))
          (health-response (get-loan-health tx-sender oracle))
        )
          ;; Ensure sufficient collateral remains after withdrawal
          (asserts! (>= new-collateral (var-get minimum-collateral-amount)) ERR-COLLATERAL-BELOW-MINIMUM)
          (asserts! (is-ok health-response) (unwrap-err health-response))
          (asserts! (>= (unwrap-ok health-response) (var-get collateralization-ratio)) ERR-LOAN-UNDERCOLLATERALIZED)
          
          ;; Update collateral amount
          (map-set user-collateral tx-sender new-collateral)
          
          ;; Transfer sBTC from contract to user
          (as-contract (contract-call? sbtc-token transfer amount (as-contract tx-sender) tx-sender none))
        )
        (begin
          ;; If no loan, simply update and transfer
          (map-set user-collateral tx-sender (- current-collateral amount))
          (as-contract (contract-call? sbtc-token transfer amount (as-contract tx-sender) tx-sender none))
        )
      )
      
      (ok amount)
    )
  )
)

;; Function to borrow stablecoin against collateral
(define-public (borrow (stablecoin <ft-trait>) (amount uint) (oracle <oracle-trait>))
  (begin
    (asserts! (not (var-get protocol-paused)) ERR-PROTOCOL-PAUSED)
    (asserts! (> amount u0) ERR-ZERO-AMOUNT)
    
    (let (
      (collateral (get-user-collateral tx-sender))
      (current-loan (get-user-loan tx-sender))
      (price-response (contract-call? oracle get-price-in-cents))
      (last-update-response (contract-call? oracle get-last-update-time))
    )
      ;; Verify collateral exists
      (asserts! (>= collateral (var-get minimum-collateral-amount)) ERR-COLLATERAL-BELOW-MINIMUM)
      
      ;; Verify price data is available and fresh
      (asserts! (is-ok price-response) (unwrap-err price-response))
      (asserts! (is-ok last-update-response) (unwrap-err last-update-response))
      
      (let (
        (price-in-cents (unwrap-ok price-response))
        (last-update (unwrap-ok last-update-response))
        (current-time (get-block-info time (- block-height u1)))
      )
        ;; Check price freshness
        (asserts! (<= (- current-time last-update) (var-get price-stale-threshold)) ERR-PRICE-STALE)
        
        ;; Calculate new total loan
        (let (
          (new-total-loan (+ current-loan amount))
          ;; Calculate collateral value in cents: collateral * price-in-cents / 100000000 (sats to BTC conversion)
          (collateral-value-cents (/ (* collateral price-in-cents) u100000000))
          ;; Calculate max loan allowed: collateral value / collateralization ratio
          (max-allowed-loan (/ (* collateral-value-cents u100) (var-get collateralization-ratio)))
        )
          ;; Ensure new loan doesn't exceed max allowed
          (asserts! (<= new-total-loan max-allowed-loan) ERR-MAX-LOAN-EXCEEDED)
          
          ;; Update loan amount
          (map-set user-loan-amount tx-sender new-total-loan)
          (map-set user-last-interest-calc tx-sender current-time)
          
          ;; Calculate protocol fee
          (let ((fee-amount (/ (* amount (var-get protocol-fee)) u100)))
            ;; Mint stablecoin to user (minus fee)
            (try! (as-contract (contract-call? stablecoin mint (- amount fee-amount) tx-sender)))
            ;; Mint fee to governance address
            (try! (as-contract (contract-call? stablecoin mint fee-amount (var-get governance-address))))
            
            (ok amount)
          )
        )
      )
    )
  )
)

;; Function to repay loan
(define-public (repay (stablecoin <ft-trait>) (amount uint))
  (begin
    (asserts! (> amount u0) ERR-ZERO-AMOUNT)
    
    (let (
      (current-loan (get-user-loan tx-sender))
    )
      ;; Ensure loan exists
      (asserts! (> current-loan u0) ERR-LOAN-NOT-FOUND)
      ;; Limit repayment to outstanding loan amount
      (let ((repay-amount (if (> amount current-loan) current-loan amount)))
        ;; Transfer stablecoin from user to contract (will be burned)
        (try! (contract-call? stablecoin transfer repay-amount tx-sender (as-contract tx-sender) none))
        
        ;; Update loan amount
        (map-set user-loan-amount tx-sender (- current-loan repay-amount))
        ;; If loan fully repaid, clear interest calculation timestamp
        (if (is-eq (- current-loan repay-amount) u0)
          (map-delete user-last-interest-calc tx-sender)
          true
        )
        
        ;; Burn the repaid tokens
        (try! (as-contract (contract-call? stablecoin burn repay-amount (as-contract tx-sender))))
        
        (ok repay-amount)
      )
    )
  )
)