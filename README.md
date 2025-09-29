# CareChain: Consortium Blockchain for Family-Caregiver Updates with Verifiable Consents

## Overview

CareChain is a Web3 project built on the Stacks blockchain using Clarity smart contracts. It provides a secure, permissioned consortium-style network for families and caregivers to share real-time updates on patient care (e.g., elderly relatives, children with chronic conditions, or post-surgery recovery). The core innovation is verifiable consents: patients (or their legal guardians) explicitly grant, revoke, and audit access to updates, ensuring privacy and compliance with regulations like HIPAA or GDPR analogs. 

This project leverages Stacks' Bitcoin-secured finality for tamper-proof records, while simulating a consortium through governance mechanisms where participating healthcare providers, family networks, or organizations vote on membership and upgrades. Updates are encrypted off-chain (e.g., via IPFS) but hashed on-chain for integrity, with consents verified via zero-knowledge proofs for privacy-preserving access checks.

## Problem Solved

In real-world family caregiving:
- **Privacy and Consent Issues**: Sharing health updates via apps or emails risks unauthorized access, data breaches, or forgotten consents.
- **Miscommunication and Fragmentation**: Families and caregivers often use disjointed tools (e.g., WhatsApp, email), leading to outdated info or missed critical updates.
- **Auditability and Trust**: No easy way to verify who accessed what, when, or prove consent in disputes (e.g., legal or insurance claims).
- **Regulatory Compliance**: Healthcare data sharing requires verifiable consents to avoid fines or liabilities.

CareChain solves these by:
- Decentralizing consent management to prevent single points of failure.
- Enabling secure, role-based updates with immutable audit logs.
- Reducing administrative burden through automated verifications.
- Incentivizing participation via optional staking for consortium members.

Target users: Families managing chronic care, home healthcare agencies, and small clinics in consortiums.

## Architecture

- **Blockchain Layer**: Stacks (public but with consortium governance via DAO-like voting).
- **Smart Contracts**: 6 core Clarity contracts (detailed below) handling users, consents, updates, access, notifications, and audits.
- **Off-Chain Components**: 
  - Frontend: React dApp for user interactions (register, grant consent, post/view updates).
  - Storage: IPFS for encrypted update content; on-chain stores hashes and metadata.
  - Oracles: For real-time notifications (e.g., integrated with Stacks events).
  - ZK-Proofs: Using Clarity's built-in crypto primitives for verifiable consent checks without revealing details.
- **Consortium Model**: Initial members (e.g., healthcare providers) stake STX tokens to join; they vote on upgrades or new members via the Governance contract (not included here but extensible).
- **Flow Example**:
  1. Patient registers and grants consent to family/caregivers.
  2. Caregiver posts an update (e.g., "Medication administered at 10 AM").
  3. Family views it after on-chain consent verification.
  4. All actions logged for audits.

## Smart Contracts

All contracts are written in Clarity (Lisp-like syntax). Below are descriptions, key functions, and sample code snippets. Full implementations would include error handling, traits, and tests. Deploy via Stacks CLI.

### 1. UserRegistry.clar
Handles user registration with roles (Patient, FamilyMember, Caregiver). Stores user profiles and verifies identities via STX addresses.

Key Functions:
- `register-user (role: string, profile-data: string)`: Registers a user with a role.
- `get-user-role (user: principal)`: Retrieves role for access checks.

Sample Code:
```
(define-map users principal {role: (string-ascii 20), profile: (string-utf8 256)})

(define-public (register-user (role (string-ascii 20)) (profile (string-utf8 256)))
  (map-insert users tx-sender {role: role, profile: profile})
  (ok true)
)

(define-read-only (get-user-role (user principal))
  (match (map-get? users user)
    some-user (get role some-user)
    none none
  )
)
```

### 2. ConsentRegistry.clar
Manages verifiable consents. Patients grant/revoke permissions for specific actions (e.g., view updates, post updates). Consents are time-bound and verifiable via hashes.

Key Functions:
- `grant-consent (grantee: principal, action: string, expiry: uint)`: Grants consent.
- `revoke-consent (grantee: principal, action: string)`: Revokes consent.
- `verify-consent (patient: principal, grantee: principal, action: string)`: Checks if consent is active.

Sample Code:
```
(define-map consents {patient: principal, grantee: principal, action: (string-ascii 20)} {expiry: uint, active: bool})

(define-public (grant-consent (grantee principal) (action (string-ascii 20)) (expiry uint))
  (asserts! (is-eq (get-user-role tx-sender) "Patient") (err u1))
  (map-set consents {patient: tx-sender, grantee: grantee, action: action} {expiry: expiry, active: true})
  (ok true)
)

(define-public (revoke-consent (grantee principal) (action (string-ascii 20)))
  (asserts! (is-eq (get-user-role tx-sender) "Patient") (err u1))
  (map-set consents {patient: tx-sender, grantee: grantee, action: action} {expiry: u0, active: false})
  (ok true)
)

(define-read-only (verify-consent (patient principal) (grantee principal) (action (string-ascii 20)))
  (match (map-get? consents {patient: patient, grantee: grantee, action: action})
    some-consent (and (get active some-consent) (> (get expiry some-consent) block-height))
    false
  )
)
```

### 3. UpdateManagement.clar
Stores and retrieves care updates. Updates are posted by authorized users and linked to patients via hashes for off-chain content.

Key Functions:
- `post-update (patient: principal, content-hash: (buff 32), metadata: string)`: Posts an update.
- `get-updates (patient: principal)`: Lists update IDs for a patient.

Sample Code:
```
(define-map updates uint {patient: principal, sender: principal, content-hash: (buff 32), metadata: (string-utf8 512), timestamp: uint})
(define-data-var update-counter uint u0)

(define-public (post-update (patient principal) (content-hash (buff 32)) (metadata (string-utf8 512)))
  (asserts! (or (is-eq tx-sender patient) (verify-consent patient tx-sender "post-update")) (err u2))
  (let ((id (var-get update-counter)))
    (map-insert updates id {patient: patient, sender: tx-sender, content-hash: content-hash, metadata: metadata, timestamp: block-height})
    (var-set update-counter (+ id u1))
    (ok id)
  )
)

(define-read-only (get-update (id uint))
  (map-get? updates id)
)
```

### 4. AccessVerifier.clar
Enforces access control using consents. Integrates with UpdateManagement for viewing.

Key Functions:
- `check-access (patient: principal, action: string)`: Verifies caller's access.
- `view-update (update-id: uint)`: Returns update if access granted.

Sample Code:
```
(use-trait consent-trait .ConsentRegistry.verify-consent)

(define-public (check-access (patient principal) (action (string-ascii 20)))
  (asserts! (or (is-eq tx-sender patient) (verify-consent patient tx-sender action)) (err u3))
  (ok true)
)

(define-public (view-update (update-id uint))
  (match (get-update update-id)
    some-update 
      (begin
        (try! (check-access (get patient some-update) "view-update"))
        (ok some-update)
      )
    (err u4)
  )
)
```

### 5. NotificationHub.clar
Handles event emissions and on-chain notifications for new updates or consent changes.

Key Functions:
- `subscribe-to-patient (patient: principal)`: Subscribes for notifications.
- `notify-update (update-id: uint, patient: principal)`: Triggers notifications (emits events).

Sample Code:
```
(define-map subscriptions principal (list 100 principal))

(define-public (subscribe-to-patient (patient principal))
  (map-set subscriptions tx-sender (cons patient (default-to (list) (map-get? subscriptions tx-sender))))
  (ok true)
)

(define-public (notify-update (update-id uint) (patient principal))
  ;; In real impl, emit Stacks events; here simulate with logs
  (print {event: "new-update", update-id: update-id, patient: patient})
  (ok true)
)
```

### 6. AuditTrail.clar
Logs all actions (e.g., consents, updates) for verifiability and compliance audits.

Key Functions:
- `log-action (action-type: string, details: string)`: Logs an action.
- `get-logs-for-user (user: principal)`: Retrieves logs.

Sample Code:
```
(define-map audit-logs uint {actor: principal, action-type: (string-ascii 50), details: (string-utf8 1024), timestamp: uint})
(define-data-var log-counter uint u0)

(define-public (log-action (action-type (string-ascii 50)) (details (string-utf8 1024)))
  (let ((id (var-get log-counter)))
    (map-insert audit-logs id {actor: tx-sender, action-type: action-type, details: details, timestamp: block-height})
    (var-set log-counter (+ id u1))
    (ok id)
  )
)

(define-read-only (get-log (id uint))
  (map-get? audit-logs id)
)
```

## Installation and Deployment

1. **Prerequisites**: Install Stacks CLI (`stacks-cli`), Node.js for frontend.
2. **Clone Repo**: `git clone <repo-url>`
3. **Deploy Contracts**: Use `clarinet deploy` for local testing, then `stacks deploy` for testnet/mainnet.
4. **Frontend Setup**: `cd frontend; npm install; npm start`
5. **Testing**: Use Clarinet for unit tests (e.g., consent verification flows).
6. **Consortium Setup**: Deploy on Stacks testnet; stake STX to join as a member.

## License

MIT License. Contributions welcome for expansions like ZK integrations or mobile apps.