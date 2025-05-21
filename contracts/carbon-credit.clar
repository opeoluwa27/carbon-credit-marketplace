;; carbon-credit.clar
;; Carbon Credit Marketplace Smart Contract
;; This contract manages the lifecycle of carbon credits on the Stacks blockchain,
;; from initial verification and minting to trading and retirement.
;; It creates a transparent, verifiable registry of carbon credits that represent
;; real-world carbon offsets, allowing users to purchase, trade, and retire credits
;; to offset their carbon footprint.
;; ========== Error Constants ==========
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INVALID-VERIFIER (err u101))
(define-constant ERR-ALREADY-REGISTERED (err u102))
(define-constant ERR-NOT-REGISTERED (err u103))
(define-constant ERR-INVALID-PROJECT-DEVELOPER (err u104))
(define-constant ERR-INVALID-CREDIT-ID (err u105))
(define-constant ERR-CREDIT-ALREADY-EXISTS (err u106))
(define-constant ERR-INSUFFICIENT-CREDITS (err u107))
(define-constant ERR-CREDIT-RETIRED (err u108))
(define-constant ERR-LISTING-NOT-FOUND (err u109))
(define-constant ERR-INVALID-PRICE (err u110))
(define-constant ERR-LISTING-ALREADY-EXISTS (err u111))
(define-constant ERR-NOT-OWNER (err u112))
(define-constant ERR-PAYMENT-FAILED (err u113))
;; ========== Data Space Definitions ==========
;; Governance
;; Contract administrator - can add/remove verifiers
(define-data-var contract-owner principal tx-sender)
;; Registry of authorized verifiers who can approve project developers
(define-map authorized-verifiers
  principal
  bool
)
;; Registry of verified project developers who can mint carbon credits
(define-map verified-project-developers
  {
    developer: principal,
    verifier: principal,
  }
  {
    approved: bool,
    timestamp: uint,
    project-name: (string-ascii 100),
  }
)
;; Carbon Credit Metadata
(define-map carbon-credits
  { credit-id: uint }
  {
    owner: principal,
    project-developer: principal,
    amount: uint, ;; in metric tons of CO2e
    project-type: (string-ascii 50), ;; e.g., "Reforestation", "Renewable Energy"
    location: (string-ascii 50), ;; country or region
    verification-standard: (string-ascii 50), ;; e.g., "Verra", "Gold Standard"
    vintage-year: uint, ;; year when the offset occurred
    serial-number: (string-ascii 100), ;; unique identifier from verification body
    issuance-date: uint, ;; timestamp of minting
    retired: bool, ;; whether the credit has been used for offsetting
    retirement-beneficiary: (optional principal), ;; who claimed the offset, if retired
    retirement-date: (optional uint), ;; when the credit was retired
  }
)
;; Tracks total credits owned by each user
(define-map credit-balances
  {
    owner: principal,
    credit-id: uint,
  }
  {
    active-amount: uint,
    retired-amount: uint,
  }
)
;; Marketplace listings
(define-map marketplace-listings
  { listing-id: uint }
  {
    seller: principal,
    credit-id: uint,
    amount: uint,
    price-per-ton: uint, ;; in microSTX per ton
    active: bool,
  }
)
;; Counter for credit IDs
(define-data-var next-credit-id uint u1)
;; Counter for listing IDs
(define-data-var next-listing-id uint u1)
;; Total volume statistics
(define-data-var total-credits-minted uint u0)
(define-data-var total-credits-retired uint u0)
(define-data-var total-credits-traded uint u0)
;; ========== Private Functions ==========
;; Check if the caller is the contract owner
(define-private (is-contract-owner)
  (is-eq tx-sender (var-get contract-owner))
)

;; Check if a principal is an authorized verifier
(define-private (is-authorized-verifier (verifier principal))
  (default-to false (map-get? authorized-verifiers verifier))
)

;; Check if a principal is a verified project developer
(define-private (is-verified-developer (developer principal))
  (match (map-get? verified-project-developers {
    developer: developer,
    verifier: tx-sender,
  })
    developer-data (get approved developer-data)
    false
  )
)

;; Check if credit exists and is active (not retired)
(define-private (is-active-credit (credit-id uint))
  (match (map-get? carbon-credits { credit-id: credit-id })
    credit-data (not (get retired credit-data))
    false
  )
)

;; Check if sender owns sufficient active credits
(define-private (has-sufficient-credits
    (owner principal)
    (credit-id uint)
    (amount uint)
  )
  (match (map-get? credit-balances {
    owner: owner,
    credit-id: credit-id,
  })
    balance-data (>= (get active-amount balance-data) amount)
    false
  )
)

;; ========== Read-Only Functions ==========
;; Get credit details by ID
(define-read-only (get-credit-details (credit-id uint))
  (map-get? carbon-credits { credit-id: credit-id })
)

;; Helper function to get verifier from developer-verifier pair
(define-read-only (get-verifier-from-developer (developer-verifier {
  developer: principal,
  verifier: principal,
}))
  (get verifier developer-verifier)
)

;; Helper functions for querying developer-verifier relationships
(define-read-only (add-developer-to-tuple (verifier principal))
  {
    developer: tx-sender,
    verifier: verifier,
  }
)

(define-read-only (has-developer-verifier (developer-verifier {
  developer: principal,
  verifier: principal,
}))
  (is-some (map-get? verified-project-developers developer-verifier))
)

;; Get marketplace listing details
(define-read-only (get-listing-details (listing-id uint))
  (map-get? marketplace-listings { listing-id: listing-id })
)

;; Get marketplace statistics
(define-read-only (get-market-stats)
  {
    total-minted: (var-get total-credits-minted),
    total-retired: (var-get total-credits-retired),
    total-traded: (var-get total-credits-traded),
  }
)

;; ========== Public Functions ==========
;; Administrative Functions
;; Transfer contract ownership
(define-public (transfer-ownership (new-owner principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)

;; Add an authorized verifier
(define-public (add-verifier (verifier principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (not (is-authorized-verifier verifier)) ERR-ALREADY-REGISTERED)
    (map-set authorized-verifiers verifier true)
    (ok true)
  )
)

;; Remove an authorized verifier
(define-public (remove-verifier (verifier principal))
  (begin
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)
    (asserts! (is-authorized-verifier verifier) ERR-NOT-REGISTERED)
    (map-delete authorized-verifiers verifier)
    (ok true)
  )
)

;; Project Developer Registration
;; Register a new project developer (can only be called by authorized verifiers)
(define-public (register-project-developer
    (developer principal)
    (project-name (string-ascii 100))
  )
  (begin
    (asserts! (is-authorized-verifier tx-sender) ERR-NOT-AUTHORIZED)
    (map-set verified-project-developers {
      developer: developer,
      verifier: tx-sender,
    } {
      approved: true,
      timestamp: block-height,
      project-name: project-name,
    })
    (ok true)
  )
)

;; Revoke project developer status
(define-public (revoke-project-developer (developer principal))
  (begin
    (asserts! (is-authorized-verifier tx-sender) ERR-NOT-AUTHORIZED)
    (match (map-get? verified-project-developers {
      developer: developer,
      verifier: tx-sender,
    })
      developer-data (begin
        (map-set verified-project-developers {
          developer: developer,
          verifier: tx-sender,
        }
          (merge developer-data { approved: false })
        )
        (ok true)
      )
      ERR-NOT-REGISTERED
    )
  )
)


;; Marketplace Functions
;; List carbon credits for sale
(define-public (list-credits-for-sale
    (credit-id uint)
    (amount uint)
    (price-per-ton uint)
  )
  (let (
      (seller tx-sender)
      (listing-id (var-get next-listing-id))
    )
    (asserts! (is-active-credit credit-id) ERR-CREDIT-RETIRED)
    (asserts! (has-sufficient-credits seller credit-id amount)
      ERR-INSUFFICIENT-CREDITS
    )
    (asserts! (> price-per-ton u0) ERR-INVALID-PRICE)
    ;; Create listing
    (map-set marketplace-listings { listing-id: listing-id } {
      seller: seller,
      credit-id: credit-id,
      amount: amount,
      price-per-ton: price-per-ton,
      active: true,
    })
    ;; Update listing counter
    (var-set next-listing-id (+ listing-id u1))
    (ok listing-id)
  )
)

;; Cancel a listing
(define-public (cancel-listing (listing-id uint))
  (let ((listing (unwrap! (map-get? marketplace-listings { listing-id: listing-id })
      ERR-LISTING-NOT-FOUND
    )))
    (asserts! (is-eq tx-sender (get seller listing)) ERR-NOT-OWNER)
    (asserts! (get active listing) ERR-LISTING-NOT-FOUND)
    ;; Deactivate listing
    (map-set marketplace-listings { listing-id: listing-id }
      (merge listing { active: false })
    )
    (ok true)
  )
)
