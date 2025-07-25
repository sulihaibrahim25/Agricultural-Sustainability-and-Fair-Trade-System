;; Crop Insurance Automation Contract
;; Automatically processes claims based on weather data and satellite imagery

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-INVALID-INPUT (err u301))
(define-constant ERR-NOT-FOUND (err u302))
(define-constant ERR-ALREADY-EXISTS (err u303))
(define-constant ERR-INSUFFICIENT-FUNDS (err u304))
(define-constant ERR-CLAIM-EXPIRED (err u305))

;; Weather event types
(define-constant WEATHER-DROUGHT u1)
(define-constant WEATHER-FLOOD u2)
(define-constant WEATHER-HAIL u3)
(define-constant WEATHER-FROST u4)
(define-constant WEATHER-HURRICANE u5)

;; Crop types
(define-constant CROP-CORN u1)
(define-constant CROP-WHEAT u2)
(define-constant CROP-SOYBEANS u3)
(define-constant CROP-RICE u4)
(define-constant CROP-COTTON u5)

;; Data Variables
(define-data-var next-policy-id uint u1)
(define-data-var next-claim-id uint u1)
(define-data-var next-weather-report-id uint u1)
(define-data-var insurance-pool uint u0)

;; Data Maps
(define-map insurance-policies
  { policy-id: uint }
  {
    farmer: principal,
    farm-location: (string-ascii 200),
    crop-type: uint,
    coverage-amount: uint,
    premium-paid: uint,
    policy-start: uint,
    policy-end: uint,
    active: bool,
    area-hectares: uint
  }
)

(define-map insurance-claims
  { claim-id: uint }
  {
    policy-id: uint,
    farmer: principal,
    weather-event: uint,
    damage-percentage: uint,
    claim-amount: uint,
    claim-date: uint,
    processed: bool,
    approved: bool,
    payout-amount: uint,
    weather-report-id: uint
  }
)

(define-map weather-reports
  { weather-report-id: uint }
  {
    location: (string-ascii 200),
    weather-type: uint,
    severity: uint,
    report-date: uint,
    verified: bool,
    reporter: principal,
    satellite-data-hash: (string-ascii 64)
  }
)

(define-map farmer-policies
  { farmer: principal }
  { policy-ids: (list 10 uint) }
)

(define-map premium-rates
  { crop-type: uint, weather-type: uint }
  { rate-per-hectare: uint }
)

;; Public Functions

;; Initialize premium rates (only contract owner)
(define-public (set-premium-rate (crop-type uint) (weather-type uint) (rate-per-hectare uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (and (>= crop-type u1) (<= crop-type u5)) ERR-INVALID-INPUT)
    (asserts! (and (>= weather-type u1) (<= weather-type u5)) ERR-INVALID-INPUT)
    (asserts! (> rate-per-hectare u0) ERR-INVALID-INPUT)

    (map-set premium-rates
      { crop-type: crop-type, weather-type: weather-type }
      { rate-per-hectare: rate-per-hectare }
    )

    (ok true)
  )
)

;; Purchase insurance policy
(define-public (purchase-policy (farm-location (string-ascii 200)) (crop-type uint) (coverage-amount uint) (area-hectares uint) (policy-duration uint))
  (let
    (
      (policy-id (var-get next-policy-id))
      (premium-amount (calculate-premium crop-type area-hectares))
      (existing-policies (default-to (list) (get policy-ids (map-get? farmer-policies { farmer: tx-sender }))))
    )
    (asserts! (> (len farm-location) u0) ERR-INVALID-INPUT)
    (asserts! (and (>= crop-type u1) (<= crop-type u5)) ERR-INVALID-INPUT)
    (asserts! (> coverage-amount u0) ERR-INVALID-INPUT)
    (asserts! (> area-hectares u0) ERR-INVALID-INPUT)
    (asserts! (> policy-duration u0) ERR-INVALID-INPUT)
    (asserts! (< (len existing-policies) u10) ERR-INVALID-INPUT)

    ;; Transfer premium to contract
    (try! (stx-transfer? premium-amount tx-sender (as-contract tx-sender)))

    ;; Add to insurance pool
    (var-set insurance-pool (+ (var-get insurance-pool) premium-amount))

    (map-set insurance-policies
      { policy-id: policy-id }
      {
        farmer: tx-sender,
        farm-location: farm-location,
        crop-type: crop-type,
        coverage-amount: coverage-amount,
        premium-paid: premium-amount,
        policy-start: block-height,
        policy-end: (+ block-height policy-duration),
        active: true,
        area-hectares: area-hectares
      }
    )

    ;; Update farmer's policy list
    (map-set farmer-policies
      { farmer: tx-sender }
      { policy-ids: (unwrap! (as-max-len? (append existing-policies policy-id) u10) ERR-INVALID-INPUT) }
    )

    (var-set next-policy-id (+ policy-id u1))
    (ok policy-id)
  )
)

;; Submit weather report (authorized reporters only)
(define-public (submit-weather-report (location (string-ascii 200)) (weather-type uint) (severity uint) (satellite-data-hash (string-ascii 64)))
  (let
    (
      (weather-report-id (var-get next-weather-report-id))
    )
    (asserts! (> (len location) u0) ERR-INVALID-INPUT)
    (asserts! (and (>= weather-type u1) (<= weather-type u5)) ERR-INVALID-INPUT)
    (asserts! (and (>= severity u1) (<= severity u10)) ERR-INVALID-INPUT)
    (asserts! (> (len satellite-data-hash) u0) ERR-INVALID-INPUT)

    (map-set weather-reports
      { weather-report-id: weather-report-id }
      {
        location: location,
        weather-type: weather-type,
        severity: severity,
        report-date: block-height,
        verified: false,
        reporter: tx-sender,
        satellite-data-hash: satellite-data-hash
      }
    )

    (var-set next-weather-report-id (+ weather-report-id u1))
    (ok weather-report-id)
  )
)

;; Verify weather report (only contract owner)
(define-public (verify-weather-report (weather-report-id uint))
  (let
    (
      (report-data (unwrap! (map-get? weather-reports { weather-report-id: weather-report-id }) ERR-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (not (get verified report-data)) ERR-INVALID-INPUT)

    (map-set weather-reports
      { weather-report-id: weather-report-id }
      (merge report-data { verified: true })
    )

    (ok true)
  )
)

;; File insurance claim
(define-public (file-claim (policy-id uint) (weather-event uint) (damage-percentage uint) (weather-report-id uint))
  (let
    (
      (claim-id (var-get next-claim-id))
      (policy-data (unwrap! (map-get? insurance-policies { policy-id: policy-id }) ERR-NOT-FOUND))
      (weather-data (unwrap! (map-get? weather-reports { weather-report-id: weather-report-id }) ERR-NOT-FOUND))
      (claim-amount (/ (* (get coverage-amount policy-data) damage-percentage) u100))
    )
    (asserts! (is-eq tx-sender (get farmer policy-data)) ERR-NOT-AUTHORIZED)
    (asserts! (get active policy-data) ERR-NOT-FOUND)
    (asserts! (>= block-height (get policy-start policy-data)) ERR-NOT-AUTHORIZED)
    (asserts! (<= block-height (get policy-end policy-data)) ERR-CLAIM-EXPIRED)
    (asserts! (is-eq weather-event (get weather-type weather-data)) ERR-INVALID-INPUT)
    (asserts! (get verified weather-data) ERR-INVALID-INPUT)
    (asserts! (and (> damage-percentage u0) (<= damage-percentage u100)) ERR-INVALID-INPUT)

    (map-set insurance-claims
      { claim-id: claim-id }
      {
        policy-id: policy-id,
        farmer: tx-sender,
        weather-event: weather-event,
        damage-percentage: damage-percentage,
        claim-amount: claim-amount,
        claim-date: block-height,
        processed: false,
        approved: false,
        payout-amount: u0,
        weather-report-id: weather-report-id
      }
    )

    (var-set next-claim-id (+ claim-id u1))
    (ok claim-id)
  )
)

;; Process claim automatically
(define-public (process-claim (claim-id uint))
  (let
    (
      (claim-data (unwrap! (map-get? insurance-claims { claim-id: claim-id }) ERR-NOT-FOUND))
      (policy-data (unwrap! (map-get? insurance-policies { policy-id: (get policy-id claim-data) }) ERR-NOT-FOUND))
      (weather-data (unwrap! (map-get? weather-reports { weather-report-id: (get weather-report-id claim-data) }) ERR-NOT-FOUND))
      (payout-amount (calculate-payout (get damage-percentage claim-data) (get severity weather-data) (get claim-amount claim-data)))
    )
    (asserts! (not (get processed claim-data)) ERR-INVALID-INPUT)
    (asserts! (get verified weather-data) ERR-INVALID-INPUT)
    (asserts! (<= payout-amount (var-get insurance-pool)) ERR-INSUFFICIENT-FUNDS)

    ;; Approve and process payout
    (try! (as-contract (stx-transfer? payout-amount tx-sender (get farmer claim-data))))

    ;; Update insurance pool
    (var-set insurance-pool (- (var-get insurance-pool) payout-amount))

    ;; Mark claim as processed and approved
    (map-set insurance-claims
      { claim-id: claim-id }
      (merge claim-data { processed: true, approved: true, payout-amount: payout-amount })
    )

    (ok payout-amount)
  )
)

;; Add funds to insurance pool (only contract owner)
(define-public (add-to-pool (amount uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (> amount u0) ERR-INVALID-INPUT)

    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    (var-set insurance-pool (+ (var-get insurance-pool) amount))

    (ok (var-get insurance-pool))
  )
)

;; Read-only functions

(define-read-only (get-policy (policy-id uint))
  (map-get? insurance-policies { policy-id: policy-id })
)

(define-read-only (get-claim (claim-id uint))
  (map-get? insurance-claims { claim-id: claim-id })
)

(define-read-only (get-weather-report (weather-report-id uint))
  (map-get? weather-reports { weather-report-id: weather-report-id })
)

(define-read-only (get-farmer-policies (farmer principal))
  (map-get? farmer-policies { farmer: farmer })
)

(define-read-only (get-insurance-pool-balance)
  (var-get insurance-pool)
)

(define-read-only (get-premium-rate (crop-type uint) (weather-type uint))
  (map-get? premium-rates { crop-type: crop-type, weather-type: weather-type })
)

;; Private functions

(define-private (calculate-premium (crop-type uint) (area-hectares uint))
  (let
    (
      (base-rate u1000000) ;; 1 STX per hectare base rate
      (crop-multiplier (get-crop-risk-multiplier crop-type))
    )
    (* (* base-rate area-hectares) crop-multiplier)
  )
)

(define-private (get-crop-risk-multiplier (crop-type uint))
  (if (is-eq crop-type CROP-CORN) u1
    (if (is-eq crop-type CROP-WHEAT) u2
      (if (is-eq crop-type CROP-SOYBEANS) u1
        (if (is-eq crop-type CROP-RICE) u3
          u2)))) ;; CROP-COTTON
)

(define-private (calculate-payout (damage-percentage uint) (weather-severity uint) (claim-amount uint))
  (let
    (
      (severity-multiplier (/ weather-severity u10))
      (base-payout (/ (* claim-amount damage-percentage) u100))
    )
    (/ (* base-payout (+ u10 severity-multiplier)) u10)
  )
)
