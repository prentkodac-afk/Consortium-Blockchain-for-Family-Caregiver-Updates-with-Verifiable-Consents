;; UpdateManagement.clar
;; Core contract for managing care updates in CareChain.
;; Handles posting, editing, deleting, listing, and categorizing updates with permission checks.
;; Integrates with ConsentRegistry for verifiable consents.
;; Uses latest Clarity syntax (e.g., let, match, unwrap! for robustness).

;; Error codes
(define-constant ERR_UNAUTHORIZED u100)
(define-constant ERR_INVALID_PATIENT u101)
(define-constant ERR_UPDATE_NOT_FOUND u102)
(define-constant ERR_INVALID_METADATA u103)
(define-constant ERR_INVALID_CATEGORY u104)
(define-constant ERR_INVALID_ATTACHMENT u105)
(define-constant ERR_UPDATE_EXPIRED u106)
(define-constant ERR_TOO_MANY_UPDATES u107)

;; Data Maps
(define-map updates 
    { id: uint } 
    { 
        patient: principal, 
        sender: principal, 
        content-hash: (buff 32),  ;; IPFS or similar hash for off-chain content
        metadata: (string-utf8 512), 
        category: (string-ascii 50), 
        attachments: (list 5 (buff 32)),  ;; Hashes of attachment files
        timestamp: uint, 
        edited-at: (optional uint), 
        is-active: bool 
    } 
)

(define-map patient-updates 
    { patient: principal } 
    (list 100 uint)  ;; List of update IDs for a patient (limited to prevent gas issues)
)

(define-data-var update-counter uint u0)
(define-data-var max-updates-per-patient uint u100)

;; Traits (for integration with ConsentRegistry and UserRegistry)
;; Assume external contracts: ConsentRegistry.verify-consent and UserRegistry.get-user-role

;; Public Functions

(define-public (post-update 
    (patient principal) 
    (content-hash (buff 32)) 
    (metadata (string-utf8 512)) 
    (category (string-ascii 50)) 
    (attachments (list 5 (buff 32)))
)
    (begin
        ;; Verify sender has permission (patient or consented caregiver/family)
        (asserts! 
            (or 
                (is-eq tx-sender patient) 
                ;; Call to external ConsentRegistry (mock in tests)
                (contract-call? .ConsentRegistry verify-consent patient tx-sender "post-update")
            ) 
            ERR_UNAUTHORIZED
        )
        ;; Validate inputs
        (asserts! (is-eq (len metadata) (<= (len metadata) 512)) ERR_INVALID_METADATA)
        (asserts! (is-eq (len category) (<= (len category) 50)) ERR_INVALID_CATEGORY)
        (asserts! (is-eq (len attachments) (<= (len attachments) 5)) ERR_INVALID_ATTACHMENT)

        (let 
            (
                (id (var-get update-counter))
                (current-patient-updates (default-to (list) (map-get? patient-updates {patient: patient})))
                (new-list (if (> (len current-patient-updates) (var-get max-updates-per-patient))
                    (as-max-len? (slice? current-patient-updates u1 (len current-patient-updates)) (list 99 uint))  ;; Rotate oldest out
                    current-patient-updates
                ))
            )
            ;; Insert new update
            (map-insert updates 
                {id: id} 
                { 
                    patient: patient, 
                    sender: tx-sender, 
                    content-hash: content-hash, 
                    metadata: metadata, 
                    category: category, 
                    attachments: attachments, 
                    timestamp: block-height, 
                    edited-at: none, 
                    is-active: true 
                } 
            )
            ;; Update patient list
            (map-set patient-updates 
                {patient: patient} 
                (as-max-len? (append new-list id) (list 100 uint))
            )
            (var-set update-counter (+ u1 id))
            (ok id)
        )
    )
)

(define-public (edit-update 
    (id uint) 
    (new-content-hash (buff 32)) 
    (new-metadata (string-utf8 512)) 
    (new-category (string-ascii 50)) 
    (new-attachments (list 5 (buff 32)))
)
    (let 
        (
            (existing (unwrap! (map-get? updates {id: id}) ERR_UPDATE_NOT_FOUND))
            (patient (get patient existing))
        )
        ;; Verify permission (sender must be original sender, patient, or consented)
        (asserts! 
            (or 
                (is-eq tx-sender (get sender existing))
                (is-eq tx-sender patient)
                (contract-call? .ConsentRegistry verify-consent patient tx-sender "edit-update")
            ) 
            ERR_UNAUTHORIZED
        )
        ;; Validate inputs
        (asserts! (<= (len new-metadata) 512) ERR_INVALID_METADATA)
        (asserts! (<= (len new-category) 50) ERR_INVALID_CATEGORY)
        (asserts! (<= (len new-attachments) 5) ERR_INVALID_ATTACHMENT)

        (map-set updates 
            {id: id} 
            (merge existing 
                { 
                    content-hash: new-content-hash, 
                    metadata: new-metadata, 
                    category: new-category, 
                    attachments: new-attachments, 
                    edited-at: (some block-height), 
                    is-active: true 
                }
            )
        )
        (ok true)
    )
)

(define-public (delete-update (id uint))
    (let 
        (
            (existing (unwrap! (map-get? updates {id: id}) ERR_UPDATE_NOT_FOUND))
            (patient (get patient existing))
        )
        ;; Only patient or consented admin can delete
        (asserts! 
            (or 
                (is-eq tx-sender patient)
                (contract-call? .ConsentRegistry verify-consent patient tx-sender "delete-update")
            ) 
            ERR_UNAUTHORIZED
        )
        (map-set updates 
            {id: id} 
            (merge existing {is-active: false})
        )
        (ok true)
    )
)

(define-public (set-update-expiry (id uint) (expiry-block uint))
    (let 
        (
            (existing (unwrap! (map-get? updates {id: id}) ERR_UPDATE_NOT_FOUND))
            (patient (get patient existing))
        )
        (asserts! 
            (is-eq tx-sender patient) 
            ERR_UNAUTHORIZED
        )
        (asserts! (> expiry-block block-height) ERR_UPDATE_EXPIRED)
        (map-set updates 
            {id: id} 
            (merge existing {expiry: (some expiry-block)})  ;; Add expiry field if needed
        )
        (ok true)
    )
)

;; Read-Only Functions

(define-read-only (get-update (id uint))
    (map-get? updates {id: id})
)

(define-read-only (get-updates-for-patient (patient principal))
    (map-get? patient-updates {patient: patient})
)

(define-read-only (get-updates-by-category (patient principal) (category (string-ascii 50)))
    (let 
        (
            (all-ids (unwrap! (map-get? patient-updates {patient: patient}) (list)))
        )
        (filter 
            read-only 
            (lambda (update-id uint)
                (match (map-get? updates {id: update-id})
                    some-update (and (is-eq (get category some-update) category) (get is-active some-update))
                    false
                )
            )
            all-ids
        )
    )
)

(define-read-only (get-update-count (patient principal))
    (len (unwrap! (map-get? patient-updates {patient: patient}) (list)))
)

(define-read-only (is-update-active (id uint))
    (match (map-get? updates {id: id})
        some-update (get is-active some-update)
        false
    )
)

(define-read-only (verify-sender-permission (id uint) (action (string-ascii 20)))
    (let 
        (
            (update (unwrap! (map-get? updates {id: id}) false))
            (patient (get patient update))
        )
        (or 
            (is-eq tx-sender patient)
            (is-eq tx-sender (get sender update))
            (contract-call? .ConsentRegistry verify-consent patient tx-sender action)
        )
    )
)

;; Admin/Governance Functions (for consortium)

(define-public (set-max-updates-per-patient (new-max uint))
    (begin
        ;; Assume only consortium admin (mock role check)
        (asserts! 
            (contract-call? .UserRegistry get-user-role tx-sender "Admin") 
            ERR_UNAUTHORIZED
        )
        (var-set max-updates-per-patient new-max)
        (ok true)
    )
)

(define-public (prune-expired-updates (patient principal))
    (let 
        (
            (ids (unwrap! (map-get? patient-updates {patient: patient}) (list)))
        )
        (map 
            (lambda (id uint)
                (match (map-get? updates {id: id})
                    some-update (if (> block-height (unwrap! (get expiry some-update) u0))
                        (map-set updates {id: id} (merge some-update {is-active: false}))
                        none
                    )
                    none
                )
            )
            ids
        )
        (ok (len (filter is-active ids)))  ;; Simplified; actual filter needed
    )
)

;; Additional utility for batch operations

(define-public (batch-post-updates 
    (patient principal) 
    (updates-list (list 10 
        { 
            content-hash: (buff 32), 
            metadata: (string-utf8 512), 
            category: (string-ascii 50), 
            attachments: (list 5 (buff 32)) 
        }
    ))
)
    (fold 
        (lambda (update-item (result {success: uint, failed: uint}))
            (match (post-update patient 
                (get content-hash update-item) 
                (get metadata update-item) 
                (get category update-item) 
                (get attachments update-item)
            )
                success (merge result {success: (+ (get success result) u1)})
                error (merge result {failed: (+ (get failed result) u1)})
            )
        )
        updates-list 
        {success: u0, failed: u0}
    )
)