;; AccessVerifier.clar
;; Core access control contract for CareChain consortium blockchain.
;; Enforces verifiable consents for viewing and interacting with care updates.
;; Integrates with ConsentRegistry and UpdateManagement contracts.
;; Supports role-based access, hierarchical permissions (e.g., primary caregiver overrides), 
;; time-bound verifications, and audit logging.
;; Uses latest Clarity features: as-max-len!, unwrap!, and improved error handling.

(impl-trait .access-verifier-trait.access-verifier-trait)  ;; Assume a trait for integration

;; Error codes
(define-constant ERR-UNAUTHORIZED u100)
(define-constant ERR-INVALID-PATIENT u101)
(define-constant ERR-EXPIRED-CONSENT u102)
(define-constant ERR-INVALID-ACTION u103)
(define-constant ERR-ACCESS-DENIED u104)
(define-constant ERR-ROLE-MISMATCH u105)
(define-constant ERR-HIERARCHY-VIOLATION u106)
(define-constant ERR-AUDIT-FAILED u107)

;; Data structures
;; Access logs for auditing
(define-map access-logs 
    { log-id: uint }
    {
        accessor: principal,
        patient: principal,
        action: (string-ascii 20),
        resource-id: uint,  ;; e.g., update ID
        timestamp: uint,
        ipfs-hash: (buff 32),  ;; Optional IPFS hash of full log details
        verified: bool
    }
)

;; Hierarchical roles: Defines permission levels (0: Patient, 1: Primary Caregiver, 2: Family, 3: Secondary Caregiver)
(define-data-var hierarchy-levels (list 4 uint)
    (list u0 u1 u2 u3)
)

(define-data-var log-counter uint u0)

;; Private helper: Get user's role level from UserRegistry (mocked integration)
(define-private (get-role-level (user principal))
    (let (
        (role (contract-call? .UserRegistry get-user-role user))  ;; Integration with UserRegistry
    )
        (match role
            patient-role (if (is-eq patient-role "Patient") u0 
                (if (is-eq patient-role "PrimaryCaregiver") u1 
                    (if (is-eq patient-role "FamilyMember") u2 
                        (if (is-eq patient-role "SecondaryCaregiver") u3 u99)  ;; u99 = unknown
                    )
                )
            )
            u99  ;; Default unknown
        )
    )
)

;; Private helper: Verify consent via ConsentRegistry
(define-private (base-consent-check (patient principal) (accessor principal) (action (string-ascii 20)))
    (let (
        (consent-check (contract-call? .ConsentRegistry verify-consent patient accessor action))
    )
        (match consent-check
            success (if success (ok true) (err ERR-EXPIRED-CONSENT))
            (err ERR-INVALID-ACTION)
        )
    )
)

;; Private helper: Check hierarchical override (higher level can access lower's resources)
(define-private (check-hierarchy (accessor-level uint) (patient-level uint))
    (>= accessor-level patient-level)
)

;; Private helper: Log access attempt
(define-private (log-access (patient principal) (accessor principal) (action (string-ascii 20)) (resource-id uint) (ipfs-hash (optional (buff 32))))
    (let (
        (counter (+ (var-get log-counter) u1))
        (new-log {
            accessor: accessor,
            patient: patient,
            action: action,
            resource-id: resource-id,
            timestamp: block-height,
            ipfs-hash: (unwrap-panic (to-consensus-buff? (unwrap! ipfs-hash (buff-from-string-ascii "")))),
            verified: false
        })
    )
        (map-insert access-logs {log-id: counter} new-log)
        (var-set log-counter counter)
        (ok counter)
    )
)

;; Private helper: Update log verification status
(define-private (verify-log (log-id uint) (verified bool))
    (match (map-get? access-logs {log-id: log-id})
        some-log 
            (begin
                (map-set access-logs 
                    {log-id: log-id} 
                    (merge some-log {verified: verified})
                )
                (ok true)
            )
        (err ERR-AUDIT-FAILED)
    )
)

;; Public: Core access check function. Verifies consent, role, and hierarchy.
(define-public (check-access (patient principal) (accessor principal) (action (string-ascii 20)))
    (begin
        ;; Validate patient exists (integration check)
        (asserts! (contract-call? .UserRegistry user-exists patient) (err ERR-INVALID-PATIENT))
        
        ;; Base consent verification
        (try! (base-consent-check patient accessor action))
        
        ;; Role-based checks
        (let (
            (accessor-level (get-role-level accessor))
            (patient-level (get-role-level patient))
        )
            (asserts! (not-eq accessor-level u99) (err ERR-ROLE-MISMATCH))  ;; Unknown role
            
            ;; Hierarchy check for non-patient access
            (if (is-eq accessor patient)
                (ok true)  ;; Patient always has access
                (if (check-hierarchy accessor-level patient-level)
                    (ok true)
                    (err ERR-HIERARCHY-VIOLATION)
                )
            )
        )
        
        ;; Log the access (without IPFS for simple check)
        (try! (log-access patient accessor action u0 none))
        
        ;; Verify the log
        (try! (verify-log (var-get log-counter) true))
        
        (ok true)
    )
)

;; Public: View update with access enforcement. Integrates with UpdateManagement.
(define-public (view-update (update-id uint))
    (let (
        (update (contract-call? .UpdateManagement get-update update-id))
        (accessor tx-sender)
    )
        (match update
            some-update
                (let (
                    (patient (get patient some-update))
                )
                    ;; Enforce access
                    (try! (check-access patient accessor "view-update"))
                    
                    ;; Optional: Check if update is public or private
                    (if (get visibility (unwrap! (contract-call? .UpdateManagement get-update-metadata update-id) (err u0)))
                        (ok (merge some-update {accessed-by: accessor}))  ;; Augment with access info
                        (begin
                            ;; Private: Additional ZK-like verification (simplified hash check)
                            (asserts! (contract-call? .ConsentRegistry zk-verify-access patient accessor update-id) (err ERR-ACCESS-DENIED))
                            (ok some-update)
                        )
                    )
                )
            none (err ERR-INVALID-PATIENT)  ;; Or update not found
        )
    )
)

;; Public: Batch access check for multiple actions/resources (e.g., dashboard load)
(define-public (batch-check-access (patient principal) (actions (list 10 {action: (string-ascii 20), resource-id: uint})))
    (fold
        (lambda (acc-item result)
            (match result
                ok-result 
                    (let (
                        (current-action (get action acc-item))
                        (current-id (get resource-id acc-item))
                    )
                        (match (check-access patient tx-sender current-action)
                            success (fold result (lambda (next) (cons next ok-result)) actions)
                            failure (err ERR-ACCESS-DENIED)
                        )
                    )
                failure failure
            )
        )
        actions
        (ok true)
    )
)

;; Public: Revoke all access for a grantee (emergency function, patient-only)
(define-public (emergency-revoke-all (grantee principal))
    (begin
        (asserts! (is-eq (get-role-level tx-sender) u0) (err ERR-UNAUTHORIZED))  ;; Only patient
        ;; Call ConsentRegistry to revoke all
        (try! (contract-call? .ConsentRegistry revoke-all-for-grantee tx-sender grantee))
        ;; Log emergency action
        (try! (log-access tx-sender tx-sender "emergency-revoke" u0 none))
        (ok true)
    )
)

;; Public: Get access history for a patient (paginated)
(define-read-only (get-access-history (patient principal) (start-id uint) (limit uint))
    (let (
        (end-id (+ start-id limit))
        (logs (map 
            (lambda (id) 
                (match (map-get? access-logs {log-id: id})
                    some-log 
                        (if (is-eq (get patient some-log) patient)
                            (some some-log)
                            none
                        )
                    none
                )
            ) 
            (contract-call? .AuditTrail get-log-range start-id end-id)  ;; Assume AuditTrail integration
        ))
    )
        (ok (filter is-some logs))
    )
)

;; Public: Admin function to update hierarchy levels (consortium governance)
(define-public (update-hierarchy (new-levels (list 4 uint)))
    (begin
        (asserts! (is-contract-caller .Governance) (err ERR-UNAUTHORIZED))  ;; Consortium admin
        (var-set hierarchy-levels new-levels)
        (ok true)
    )
)

;; Read-only: Get current hierarchy levels
(define-read-only (get-hierarchy-levels)
    (var-get hierarchy-levels)
)

;; Read-only: Get specific log
(define-read-only (get-access-log (log-id uint))
    (map-get? access-logs {log-id: log-id})
)

;; Trait compliance (assume .access-verifier-trait)
(define-public (is-access-verifier) (ok true))