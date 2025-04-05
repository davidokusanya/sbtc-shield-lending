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
(define-constant ERR-INVALID-TOKEN (err u1010))
(define-constant ERR-INVALID-PRINCIPAL (err u1011))

;; Data Variables
(define-data-var protocol-paused bool false)
(define-data-var governance-address principal 'SP000000000000000000002Q6VF78)
(define-data-var contract-owner principal tx-sender) ;; Store contract deployer as owner
(define-data-var liquidation-threshold uint u150) ;; 150% = minimum collateral ratio required to avoid liquidation
(define-data-var collateralization-ratio uint u200) ;; 200% = required collateral ratio for new loans (higher than liquidation threshold)
(define-data-var liquidation-penalty uint u10) ;; 10% penalty on liquidated positions
(define-data-var minimum-collateral-amount uint u1000000) ;; Minimum amount in sats (0.01 BTC = 1,000,000 sats)
(define-data-var protocol-fee uint u1) ;; 1% fee on borrowed amount
(define-data-var price-stale-threshold uint u3600) ;; Price staleness threshold in seconds (1 hour)
(define-data-var btc-price-in-cents uint u0) ;; Current BTC price in cents
(define-data-var price-last-updated uint u0) ;; Timestamp when price was last updated

;; Define SIP-010 Trait for Fungible Tokens locally
(define-trait ft-trait
  (
    ;; Transfer from the caller to a new principal
    (transfer (uint principal principal (optional (buff 34))) (response bool uint))
    ;; Get the token balance of a principal
    (get-balance (principal) (response uint uint))
    ;; Get the total supply of the token
    (get-total-supply () (response uint uint))
    ;; Get the token name
    (get-name () (response (string-ascii 32) uint))
    ;; Get the token symbol
    (get-symbol () (response (string-ascii 32) uint))
    ;; Get the number of decimals used by the token
    (get-decimals () (response uint uint))
    ;; Get the URI containing token metadata
    (get-token-uri () (response (optional (string-utf8 256)) uint))
    ;; Mint new tokens
    (mint (uint principal) (response bool uint))
    ;; Burn tokens
    (burn (uint principal) (response bool uint))
  )
)

;; Oracle trait definition
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

;; Get current price data
(define-read-only (get-current-price)
  (var-get btc-price-in-cents)
)

(define-read-only (get-price-last-updated)
  (var-get price-last-updated)
)

;; Get contract owner
(define-read-only (get-contract-owner)
  (var-get contract-owner)
)

;; Check if price is stale
(define-read-only (is-price-stale)
  (let (
    (current-time stacks-block-height)
    (last-updated (var-get price-last-updated))
  )
    (> (- current-time last-updated) (var-get price-stale-threshold))
  )
)

;; Get loan health percentage (collateral value / loan value * 100)
;; Returns 0 if no loan, or the health percentage (e.g., 200 = 200% collateralized)
(define-read-only (get-loan-health (user principal))
  (let (
    (collateral (get-user-collateral user))
    (loan (get-user-loan user))
    (price-in-cents (var-get btc-price-in-cents))
  )
    (if (or (is-eq loan u0) (is-eq collateral u0))
      u0
      ;; Calculate loan health: (collateral * price) / (loan * 100) * 100
      ;; Convert sats to BTC by dividing by 100,000,000
      (/ (* (* collateral price-in-cents) u100) (* loan u100000000))
    )
  )
)

;; Check if loan is eligible for liquidation
(define-read-only (is-liquidatable (user principal))
  (let (
    (health (get-loan-health user))
    (threshold (var-get liquidation-threshold))
  )
    (and 
      (> (get-user-loan user) u0)  ;; Has a loan
      (> (get-user-collateral user) u0)  ;; Has collateral
      (< health threshold)  ;; Below threshold
      (not (is-price-stale))  ;; Only if price is fresh
    )
  )
)

;; Access control modifier for governance functions
(define-private (is-governance-or-owner)
  (or (is-eq tx-sender (var-get governance-address)) (is-eq tx-sender (var-get contract-owner)))
)

;; Add these validation functions at the beginning of your contract
(define-private (is-valid-token (token <ft-trait>))
  (is-some (some (contract-of token)))  ;; Check if the trait reference has a valid contract
)

(define-private (is-valid-principal (address principal))
  (and 
    (not (is-eq address 'SP000000000000000000002Q6VF78))  ;; Check it's not a standard principal
    (not (is-eq address tx-sender))  ;; Optional: prevent setting to current sender for certain functions
  )
)

;; Protocol governance functions
(define-public (set-governance-address (new-address principal))
  (begin
    (asserts! (is-governance-or-owner) ERR-NOT-AUTHORIZED)
    (asserts! (is-valid-principal new-address) ERR-INVALID-PRINCIPAL)
    (ok (var-set governance-address new-address))
  )
)


(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (is-valid-principal new-owner) ERR-INVALID-PRINCIPAL)
    (ok (var-set contract-owner new-owner))
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

;; Update price from oracle (only governance or contract owner)
(define-public (update-price (oracle <oracle-trait>))
  (begin
    (asserts! (is-governance-or-owner) ERR-NOT-AUTHORIZED)
    
    (let (
      (price-response (contract-call? oracle get-price-in-cents))
      (time-response (contract-call? oracle get-last-update-time))
    )
      (asserts! (is-ok price-response) (err u1006))
      (asserts! (is-ok time-response) (err u1006))
      
      (var-set btc-price-in-cents (unwrap-panic price-response))
      (var-set price-last-updated (unwrap-panic time-response))
      
      (ok (var-get btc-price-in-cents))
    )
  )
)

;; Core lending protocol functions

;; Function to deposit sBTC as collateral
(define-public (deposit-collateral (sbtc-token <ft-trait>) (amount uint))
  (begin
    (asserts! (not (var-get protocol-paused)) ERR-PROTOCOL-PAUSED)
    (asserts! (> amount u0) ERR-ZERO-AMOUNT)
    (asserts! (is-valid-token sbtc-token) ERR-INVALID-TOKEN)
    
    ;; Transfer sBTC from user to contract
    (let 
      ((transfer-result (try! (contract-call? sbtc-token transfer amount tx-sender (as-contract tx-sender) none))))
      
      ;; Update user's collateral
      (map-set user-collateral tx-sender (+ (get-user-collateral tx-sender) amount))
      
      (ok amount)
    )
  )
)

;; Function to withdraw collateral (if no outstanding loans or sufficient collateral remaining)
(define-public (withdraw-collateral (sbtc-token <ft-trait>) (amount uint))
  (begin
    (asserts! (not (var-get protocol-paused)) ERR-PROTOCOL-PAUSED)
    (asserts! (> amount u0) ERR-ZERO-AMOUNT)
    (asserts! (not (is-price-stale)) ERR-PRICE-STALE)
    (asserts! (is-valid-token sbtc-token) ERR-INVALID-TOKEN)
    
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
          (new-health (/ (* (* new-collateral (var-get btc-price-in-cents)) u100) (* current-loan u100000000)))
        )
          ;; Ensure sufficient collateral remains after withdrawal
          (asserts! (>= new-collateral (var-get minimum-collateral-amount)) ERR-COLLATERAL-BELOW-MINIMUM)
          (asserts! (>= new-health (var-get collateralization-ratio)) ERR-LOAN-UNDERCOLLATERALIZED)
          
          ;; Update collateral amount
          (map-set user-collateral tx-sender new-collateral)
          
          ;; Transfer sBTC from contract to user - using try! to handle the response
          (try! (as-contract (contract-call? sbtc-token transfer amount (as-contract tx-sender) tx-sender none)))
          (ok amount)
        )
        (begin
          ;; If no loan, simply update and transfer
          (map-set user-collateral tx-sender (- current-collateral amount))
          ;; Transfer sBTC from contract to user - using try! to handle the response
          (try! (as-contract (contract-call? sbtc-token transfer amount (as-contract tx-sender) tx-sender none)))
          (ok amount)
        )
      )
    )
  )
)

;; Function to borrow stablecoin against collateral
(define-public (borrow (stablecoin <ft-trait>) (amount uint))
  (begin
    (asserts! (not (var-get protocol-paused)) ERR-PROTOCOL-PAUSED)
    (asserts! (> amount u0) ERR-ZERO-AMOUNT)
    (asserts! (not (is-price-stale)) ERR-PRICE-STALE)
    (asserts! (is-valid-token stablecoin) ERR-INVALID-TOKEN)
    
    (let (
      (collateral (get-user-collateral tx-sender))
      (current-loan (get-user-loan tx-sender))
      (price-in-cents (var-get btc-price-in-cents))
      (current-time stacks-block-height)
    )
      ;; Verify collateral exists
      (asserts! (>= collateral (var-get minimum-collateral-amount)) ERR-COLLATERAL-BELOW-MINIMUM)
      
      ;; Calculate new total loan
      (let (
        (new-total-loan (+ current-loan amount))
        ;; Calculate collateral value in cents: collateral * price-in-cents / 100000000 (sats to BTC conversion)
        (collateral-value-cents (/ (* collateral price-in-cents) u100000000))
        ;; Calculate max loan allowed: collateral value / collateralization ratio * 100
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

;; Function to repay loan
(define-public (repay (stablecoin <ft-trait>) (amount uint))
  (begin
     (asserts! (> amount u0) ERR-ZERO-AMOUNT)
    (asserts! (is-valid-token stablecoin) ERR-INVALID-TOKEN)
    
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

;; Function to liquidate undercollateralized positions
(define-public (liquidate (user principal) (sbtc-token <ft-trait>) (stablecoin <ft-trait>))
  (begin
    (asserts! (not (var-get protocol-paused)) ERR-PROTOCOL-PAUSED)
    (asserts! (not (is-price-stale)) ERR-PRICE-STALE)
    (asserts! (is-valid-token sbtc-token) ERR-INVALID-TOKEN)
    (asserts! (is-valid-token stablecoin) ERR-INVALID-TOKEN)
    
    ;; Check if position is liquidatable
    (asserts! (is-liquidatable user) ERR-LIQUIDATION-FAILED)
    
    (let (
      (loan-amount (get-user-loan user))
      (collateral-amount (get-user-collateral user))
      (price-in-cents (var-get btc-price-in-cents))
      (penalty-amount (/ (* loan-amount (var-get liquidation-penalty)) u100))
      (total-to-repay (+ loan-amount penalty-amount))
    )
      ;; Transfer stablecoin from liquidator to contract for repayment
      (try! (contract-call? stablecoin transfer loan-amount tx-sender (as-contract tx-sender) none))
      
      ;; Calculate collateral value and determine how much to give liquidator
      (let (
        ;; Calculate price per sat: price-in-cents / 100000000 (cents per BTC / sats per BTC)
        (price-per-sat (/ price-in-cents u100000000))
        ;; Calculate how much collateral to give to liquidator (including bonus)
        (liquidator-collateral (/ (* total-to-repay u100) price-per-sat))
      )
        ;; Ensure we don't take more than available
        (let ((collateral-to-take (if (> liquidator-collateral collateral-amount) 
                                    collateral-amount 
                                    liquidator-collateral)))
          ;; Update loan and collateral status
          (map-delete user-loan-amount user)
          (map-delete user-last-interest-calc user)
          
          (if (< collateral-to-take collateral-amount)
            ;; If partial liquidation, update remaining collateral
            (map-set user-collateral user (- collateral-amount collateral-to-take))
            ;; Otherwise remove collateral entry entirely
            (map-delete user-collateral user)
          )
          
          ;; Burn the loan amount
          (try! (as-contract (contract-call? stablecoin burn loan-amount (as-contract tx-sender))))
          
          ;; Transfer liquidated collateral to liquidator
          (try! (as-contract (contract-call? sbtc-token transfer collateral-to-take (as-contract tx-sender) tx-sender none)))
          
          (ok collateral-to-take)
        )
      )
    )
  )
)

;; Contract initialization
(define-public (initialize (new-governance principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    (asserts! (is-valid-principal new-governance) ERR-INVALID-PRINCIPAL)
    (var-set governance-address new-governance)
    (ok true)
  )
)