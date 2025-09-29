;; ConsentRegistry.clar
;; Sophisticated Consent Management Smart Contract for CareChain
;; Manages verifiable consents in a family-caregiver consortium blockchain.
;; Supports granular permissions, time-bound consents, consent delegation, history tracking,
;; batch operations, and integration with audit trails. Designed for privacy and compliance.

;; Constants
(define-constant ERR-NOT-PATIENT u1)
(define-constant ERR-NOT-AUTHORIZED u2)
(define-constant ERR-CONSENT-EXISTS u3)
(define-constant ERR-NO-CONSENT u4)
(define-constant ERR-EXPIRED u5)
(define-constant ERR-INVALID-ACTION u6)
(define-constant ERR-INVALID-EXPIRY u7)
(define-constant ERR-NOT-DELEGATE u8)
(define-constant ERR-BATCH-LIMIT-EXCEEDED u9)
(define-constant ERR-INVALID-ROLE u10)
(define-constant ERR-CONTRACT-PAUSED u11)
(define-constant MAX-BATCH-SIZE u10)
(define-constant MAX-ACTION-LEN u20)
(define-constant MAX-DETAILS-LEN u512)

;; Data Variables
(define-data-var contract-paused bool false)
(define-data-var admin principal tx-sender)
(define-data-var consent-counter uint u0)

;; Data Maps
(define-map consents
  { patient: principal, grantee: principal, action: (string-ascii 20) }
  { expiry: uint, active: bool, details: (string-utf8 512), granted-at: uint }
)

(define-map consent-history
  { consent-id: uint }
  { patient: principal, grantee: principal, action: (string-ascii 20), status: (string-ascii 20), timestamp: uint, details: (string-utf8 512) }
)

(define-map delegates
  { patient: principal, delegate: principal }
  { permissions: (list 5 (string-ascii 20)), expiry: uint, active: bool }
)

(define-map user-roles
  principal
  { role: (string-ascii 20), verified: bool }
)

;; Traits (for integration with other contracts, e.g., AuditTrail)
(define-trait audit-trait
  (
    (log-action (principal (string-ascii 50) (string-utf8 1024)) (response bool uint))
  )
)

;; Private Functions
(define-private (is-patient (user principal))
  (is-eq (default-to "None" (get role (map-get? user-roles user))) "Patient")
)

(define-private (is-delegate-for (patient principal) (delegate principal) (action (string-ascii 20)))
  (match (map-get? delegates {patient: patient, delegate: delegate})
    some-delegation
      (and (get active some-delegation)
           (> (get expiry some-delegation) block-height)
           (is-some (index-of? (get permissions some-delegation) action)))
    false
  )
)

(define-private (log-consent-action (actor principal) (action-type (string-ascii 50)) (details (string-utf8 1024)))
  ;; Assume external audit contract call; mockable in tests
  (ok true)
)

;; Public Functions
(define-public (pause-contract)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR-NOT-AUTHORIZED))
    (var-set contract-paused true)
    (ok true)
  )
)

(define-public (unpause-contract)
  (begin
    (asserts! (is-eq tx-sender (var-get admin)) (err ERR-NOT-AUTHORIZED))
    (var-set contract-paused false)
    (ok true)
  )
)

(define-public (register-user (role (string-ascii 20)))
  (begin
    (asserts! (or (is-eq role "Patient") (is-eq role "FamilyMember") (is-eq role "Caregiver")) (err ERR-INVALID-ROLE))
    (map-set user-roles tx-sender {role: role, verified: true})
    (ok true)
  )
)

(define-public (grant-consent (grantee principal) (action (string-ascii 20)) (expiry uint) (details (string-utf8 512)))
  (begin
    (asserts! (not (var-get contract-paused)) (err ERR-CONTRACT-PAUSED))
    (asserts! (is-patient tx-sender) (err ERR-NOT-PATIENT))
    (asserts! (> expiry block-height) (err ERR-INVALID-EXPIRY))
    (asserts! (<= (len action) MAX-ACTION-LEN) (err ERR-INVALID-ACTION))
    (asserts! (<= (len details) MAX-DETAILS-LEN) (err ERR-INVALID-ACTION))
    (asserts! (is-none (map-get? consents {patient: tx-sender, grantee: grantee, action: action})) (err ERR-CONSENT-EXISTS))
    (map-set consents
      {patient: tx-sender, grantee: grantee, action: action}
      {expiry: expiry, active: true, details: details, granted-at: block-height}
    )
    (let ((id (var-get consent-counter)))
      (map-set consent-history
        {consent-id: id}
        {patient: tx-sender, grantee: grantee, action: action, status: "Granted", timestamp: block-height, details: details}
      )
      (var-set consent-counter (+ id u1))
      (try! (log-consent-action tx-sender "grant-consent" details))
      (ok id)
    )
  )
)

(define-public (revoke-consent (grantee principal) (action (string-ascii 20)))
  (begin
    (asserts! (not (var-get contract-paused)) (err ERR-CONTRACT-PAUSED))
    (asserts! (is-patient tx-sender) (err ERR-NOT-PATIENT))
    (match (map-get? consents {patient: tx-sender, grantee: grantee, action: action})
      some-consent
        (begin
          (map-set consents
            {patient: tx-sender, grantee: grantee, action: action}
            (merge some-consent {active: false, expiry: u0})
          )
          (let ((id (var-get consent-counter)))
            (map-set consent-history
              {consent-id: id}
              {patient: tx-sender, grantee: grantee, action: action, status: "Revoked", timestamp: block-height, details: (get details some-consent)}
            )
            (var-set consent-counter (+ id u1))
            (try! (log-consent-action tx-sender "revoke-consent" (get details some-consent)))
            (ok id)
          )
        )
      (err ERR-NO-CONSENT)
    )
  )
)

(define-public (delegate-consent (delegate principal) (permissions (list 5 (string-ascii 20))) (expiry uint))
  (begin
    (asserts! (not (var-get contract-paused)) (err ERR-CONTRACT-PAUSED))
    (asserts! (is-patient tx-sender) (err ERR-NOT-PATIENT))
    (asserts! (> expiry block-height) (err ERR-INVALID-EXPIRY))
    (map-set delegates
      {patient: tx-sender, delegate: delegate}
      {permissions: permissions, expiry: expiry, active: true}
    )
    (try! (log-consent-action tx-sender "delegate-consent" (fold concat permissions "")))
    (ok true)
  )
)

(define-public (grant-consent-as-delegate (patient principal) (grantee principal) (action (string-ascii 20)) (expiry uint) (details (string-utf8 512)))
  (begin
    (asserts! (not (var-get contract-paused)) (err ERR-CONTRACT-PAUSED))
    (asserts! (is-delegate-for patient tx-sender action) (err ERR-NOT-DELEGATE))
    (asserts! (> expiry block-height) (err ERR-INVALID-EXPIRY))
    (asserts! (<= (len action) MAX-ACTION-LEN) (err ERR-INVALID-ACTION))
    (asserts! (<= (len details) MAX-DETAILS-LEN) (err ERR-INVALID-ACTION))
    (asserts! (is-none (map-get? consents {patient: patient, grantee: grantee, action: action})) (err ERR-CONSENT-EXISTS))
    (map-set consents
      {patient: patient, grantee: grantee, action: action}
      {expiry: expiry, active: true, details: details, granted-at: block-height}
    )
    (let ((id (var-get consent-counter)))
      (map-set consent-history
        {consent-id: id}
        {patient: patient, grantee: grantee, action: action, status: "Granted (Delegate)", timestamp: block-height, details: details}
      )
      (var-set consent-counter (+ id u1))
      (try! (log-consent-action tx-sender "grant-consent-delegate" details))
      (ok id)
    )
  )
)

(define-public (batch-grant-consents (grantees (list 10 principal)) (action (string-ascii 20)) (expiry uint) (details (string-utf8 512)))
  (begin
    (asserts! (not (var-get contract-paused)) (err ERR-CONTRACT-PAUSED))
    (asserts! (is-patient tx-sender) (err ERR-NOT-PATIENT))
    (asserts! (<= (len grantees) MAX-BATCH-SIZE) (err ERR-BATCH-LIMIT-EXCEEDED))
    (asserts! (<= (len action) MAX-ACTION-LEN) (err ERR-INVALID-ACTION))
    (asserts! (<= (len details) MAX-DETAILS-LEN) (err ERR-INVALID-ACTION))
    (asserts! (> expiry block-height) (err ERR-INVALID-EXPIRY))
    (fold batch-grant-iter grantees (ok u0))
  )
)

(define-private (batch-grant-iter (grantee principal) (prev (response uint uint)))
  (match prev
    count
      (begin
        (try! (grant-consent grantee action expiry details))
        (ok (+ count u1))
      )
    err
      (err err)
  )
)

;; Read-Only Functions
(define-read-only (verify-consent (patient principal) (grantee principal) (action (string-ascii 20)))
  (match (map-get? consents {patient: patient, grantee: grantee, action: action})
    some-consent
      (ok (and (get active some-consent) (> (get expiry some-consent) block-height)))
    (ok false)
  )
)

(define-read-only (get-consent-details (patient principal) (grantee principal) (action (string-ascii 20)))
  (map-get? consents {patient: patient, grantee: grantee, action: action})
)

(define-read-only (get-consent-history (consent-id uint))
  (map-get? consent-history {consent-id: consent-id})
)

(define-read-only (get-delegate-details (patient principal) (delegate principal))
  (map-get? delegates {patient: patient, delegate: delegate})
)

(define-read-only (get-user-role (user principal))
  (get role (map-get? user-roles user))
)

(define-read-only (is-contract-paused)
  (var-get contract-paused)
)