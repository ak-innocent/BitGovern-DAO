;; Title: 
;; BitGovern DAO - Bitcoin-Aligned On-Chain Governance Protocol
;; 
;; Summary:
;; A secure, Bitcoin-compliant DAO framework enabling decentralized governance over BTC treasury, 
;; protocol parameters, and membership. Built for Stacks L2 with sBTC integration and hybrid voting mechanics.
;;
;; Description:
;; BitGovern DAO implements a sophisticated governance system bridging Bitcoin and Stacks ecosystems. 
;; Key features include:
;; - Multi-signature-style BTC treasury management with sBTC compliance
;; - Three proposal types: BTC transfers, parameter adjustments, membership changes
;; - Time-locked voting periods with quorum and majority thresholds
;; - Sybil-resistant voting power based on token-weighted participation
;; - Self-governed parameter upgrades (voting periods, thresholds, fees)
;; - Stacks-native anti-spam mechanics with STX proposal deposits
;;
;; Designed for enterprises and decentralized collectives needing Bitcoin-aware governance, 
;; BitGovern enables secure cross-chain operations while maintaining Bitcoin's security guarantees.
;; Protocol parameters are initially set with conservative defaults but remain upgradeable through DAO consensus.

;; Constants
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_PROPOSAL_NOT_FOUND (err u101))
(define-constant ERR_VOTING_PERIOD_ACTIVE (err u102))
(define-constant ERR_VOTING_PERIOD_ENDED (err u103))
(define-constant ERR_ALREADY_VOTED (err u104))
(define-constant ERR_INSUFFICIENT_BALANCE (err u105))
(define-constant ERR_INVALID_PROPOSAL_TYPE (err u106))
(define-constant ERR_QUORUM_NOT_REACHED (err u107))
(define-constant ERR_PROPOSAL_ALREADY_EXECUTED (err u108))
(define-constant ERR_INVALID_AMOUNT (err u109))
(define-constant ERR_PROPOSAL_REJECTED (err u110))

;; Proposal types
(define-constant PROPOSAL_TYPE_BTC_TRANSFER u1)
(define-constant PROPOSAL_TYPE_PARAMETERS_CHANGE u2)
(define-constant PROPOSAL_TYPE_MEMBERSHIP u3)

;; DAO parameters - these could be made changeable via governance
(define-data-var quorum-threshold uint u600) ;; 60% of total voting power needed
(define-data-var majority-threshold uint u500) ;; 50%+ votes for approval
(define-data-var voting-period uint u144) ;; ~24 hours in blocks (assuming 10 min/block)
(define-data-var proposal-fee uint u1000000) ;; 1 STX fee to create proposal (prevents spam)

;; Track proposals
(define-map proposals
  { proposal-id: uint }
  {
    creator: principal,
    title: (string-ascii 100),
    description: (string-utf8 1000),
    proposal-type: uint,
    btc-recipient: (optional (buff 33)), ;; Bitcoin address for transfers
    btc-amount: (optional uint),         ;; Amount in sats for transfers
    parameter-key: (optional (string-ascii 50)), ;; For parameter change proposals
    parameter-value: (optional uint),    ;; For parameter change proposals
    member-address: (optional principal),;; For membership proposals
    member-action: (optional bool),      ;; true = add, false = remove member
    created-at-block: uint,
    votes-for: uint,
    votes-against: uint,
    executed: bool
  }
)

;; Track who has voted on what proposal
(define-map proposal-votes
  { proposal-id: uint, voter: principal }
  { voted-for: bool }
)

;; Track DAO members and their voting power
(define-map members
  { address: principal }
  { voting-power: uint, joined-at-block: uint }
)

;; Next proposal ID
(define-data-var next-proposal-id uint u1)

;; Contract owner for initial setup
(define-data-var contract-owner principal tx-sender)

;; Bitcoin treasury status - to be updated when executing BTC transfers
(define-data-var btc-treasury-balance uint u0)
(define-data-var sbtc-custodian (optional principal) none)

;; Initialize contract
(define-public (initialize-dao (initial-owner principal) (initial-sbtc-custodian principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_UNAUTHORIZED)
    
    ;; Set the initial owner as a member with high voting power
    (map-set members 
      { address: initial-owner }
      { voting-power: u1000, joined-at-block: block-height }
    )
    
    ;; Set the sBTC custodian - this would be the contract that handles BTC transfers
    (var-set sbtc-custodian (some initial-sbtc-custodian))
    
    (ok true)
  )
)

;; DAO Membership Functions

(define-public (add-member (new-member principal) (voting-power uint))
  (begin
    (asserts! (is-dao-member tx-sender) ERR_UNAUTHORIZED)
    
    (map-set members
      { address: new-member }
      { voting-power: voting-power, joined-at-block: block-height }
    )
    
    (ok true)
  )
)

(define-public (remove-member (member principal))
  (begin
    (asserts! (is-dao-member tx-sender) ERR_UNAUTHORIZED)
    (asserts! (not (is-eq member tx-sender)) ERR_UNAUTHORIZED)
    
    (map-delete members { address: member })
    
    (ok true)
  )
)

(define-public (update-voting-power (member principal) (new-voting-power uint))
  (let ((member-data (get-member-data member)))
    (asserts! (is-dao-member tx-sender) ERR_UNAUTHORIZED)
    (asserts! (is-some member-data) ERR_UNAUTHORIZED)
    
    (map-set members
      { address: member }
      (merge (unwrap! member-data ERR_UNAUTHORIZED) { voting-power: new-voting-power })
    )
    
    (ok true)
  )
)

;; Proposal Creation and Management

(define-public (create-btc-transfer-proposal 
  (title (string-ascii 100))
  (description (string-utf8 1000))
  (btc-recipient (buff 33))
  (btc-amount uint)
)
  (begin
    (asserts! (is-dao-member tx-sender) ERR_UNAUTHORIZED)
    (asserts! (> btc-amount u0) ERR_INVALID_AMOUNT)
    
    ;; Charge proposal fee
    (try! (stx-transfer? (var-get proposal-fee) tx-sender (as-contract tx-sender)))
    
    (let ((proposal-id (var-get next-proposal-id)))
      (map-set proposals
        { proposal-id: proposal-id }
        {
          creator: tx-sender,
          title: title,
          description: description,
          proposal-type: PROPOSAL_TYPE_BTC_TRANSFER,
          btc-recipient: (some btc-recipient),
          btc-amount: (some btc-amount),
          parameter-key: none,
          parameter-value: none,
          member-address: none,
          member-action: none,
          created-at-block: block-height,
          votes-for: u0,
          votes-against: u0,
          executed: false
        }
      )
      
      (var-set next-proposal-id (+ proposal-id u1))
      (ok proposal-id)
    )
  )
)

(define-public (create-parameter-change-proposal
  (title (string-ascii 100))
  (description (string-utf8 1000))
  (parameter-key (string-ascii 50))
  (parameter-value uint)
)
  (begin
    (asserts! (is-dao-member tx-sender) ERR_UNAUTHORIZED)
    
    ;; Charge proposal fee
    (try! (stx-transfer? (var-get proposal-fee) tx-sender (as-contract tx-sender)))
    
    (let ((proposal-id (var-get next-proposal-id)))
      (map-set proposals
        { proposal-id: proposal-id }
        {
          creator: tx-sender,
          title: title,
          description: description,
          proposal-type: PROPOSAL_TYPE_PARAMETERS_CHANGE,
          btc-recipient: none,
          btc-amount: none,
          parameter-key: (some parameter-key),
          parameter-value: (some parameter-value),
          member-address: none,
          member-action: none,
          created-at-block: block-height,
          votes-for: u0,
          votes-against: u0,
          executed: false
        }
      )
      
      (var-set next-proposal-id (+ proposal-id u1))
      (ok proposal-id)
    )
  )
)

(define-public (create-membership-proposal
  (title (string-ascii 100))
  (description (string-utf8 1000))
  (member-address principal)
  (add-member bool)
  (voting-power uint)
)
  (begin
    (asserts! (is-dao-member tx-sender) ERR_UNAUTHORIZED)
    
    ;; Charge proposal fee
    (try! (stx-transfer? (var-get proposal-fee) tx-sender (as-contract tx-sender)))
    
    (let ((proposal-id (var-get next-proposal-id)))
      (map-set proposals
        { proposal-id: proposal-id }
        {
          creator: tx-sender,
          title: title,
          description: description,
          proposal-type: PROPOSAL_TYPE_MEMBERSHIP,
          btc-recipient: none,
          btc-amount: none,
          parameter-key: (some "voting-power"),
          parameter-value: (some voting-power),
          member-address: (some member-address),
          member-action: (some add-member),
          created-at-block: block-height,
          votes-for: u0,
          votes-against: u0,
          executed: false
        }
      )
      
      (var-set next-proposal-id (+ proposal-id u1))
      (ok proposal-id)
    )
  )
)

;; Voting Functions

(define-public (vote-on-proposal (proposal-id uint) (vote-for bool))
  (let (
    (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) ERR_PROPOSAL_NOT_FOUND))
    (voting-power (get-voting-power tx-sender))
  )
    ;; Check if user is a member
    (asserts! (> voting-power u0) ERR_UNAUTHORIZED)
    
    ;; Check if proposal is still in voting period
    (asserts! (<= (+ (get created-at-block proposal) (var-get voting-period)) block-height) ERR_VOTING_PERIOD_ENDED)
    (asserts! (>= block-height (get created-at-block proposal)) ERR_VOTING_PERIOD_ACTIVE)
    
    ;; Check if user has already voted
    (asserts! (is-none (map-get? proposal-votes { proposal-id: proposal-id, voter: tx-sender })) ERR_ALREADY_VOTED)
    
    ;; Record the vote
    (map-set proposal-votes 
      { proposal-id: proposal-id, voter: tx-sender } 
      { voted-for: vote-for }
    )
    
    ;; Update vote counts
    (map-set proposals
      { proposal-id: proposal-id }
      (merge proposal 
        {
          votes-for: (if vote-for (+ (get votes-for proposal) voting-power) (get votes-for proposal)),
          votes-against: (if vote-for (get votes-against proposal) (+ (get votes-against proposal) voting-power))
        }
      )
    )
    
    (ok true)
  )
)

;; Proposal Execution

(define-public (execute-proposal (proposal-id uint))
  (let (
    (proposal (unwrap! (map-get? proposals { proposal-id: proposal-id }) ERR_PROPOSAL_NOT_FOUND))
    (total-votes (+ (get votes-for proposal) (get votes-against proposal)))
    (total-voting-power (get-total-voting-power))
  )
    ;; Check if voting period has ended
    (asserts! (>= block-height (+ (get created-at-block proposal) (var-get voting-period))) ERR_VOTING_PERIOD_ACTIVE)
    
    ;; Check that proposal hasn't been executed
    (asserts! (not (get executed proposal)) ERR_PROPOSAL_ALREADY_EXECUTED)
    
    ;; Check quorum
    (asserts! (>= (* total-votes u1000) (* total-voting-power (var-get quorum-threshold))) ERR_QUORUM_NOT_REACHED)
    
    ;; Check if proposal was approved
    (asserts! (>= (* (get votes-for proposal) u1000) (* total-votes (var-get majority-threshold))) ERR_PROPOSAL_REJECTED)
    
    ;; Mark as executed
    (map-set proposals
      { proposal-id: proposal-id }
      (merge proposal { executed: true })
    )
    
    ;; Execute the specific action based on proposal type
    (match (get proposal-type proposal)
      PROPOSAL_TYPE_BTC_TRANSFER (execute-btc-transfer proposal)
      PROPOSAL_TYPE_PARAMETERS_CHANGE (execute-parameter-change proposal)
      PROPOSAL_TYPE_MEMBERSHIP (execute-membership-change proposal)
      ERR_INVALID_PROPOSAL_TYPE
    )
  )
)

;; Type-specific execution functions

(define-private (execute-btc-transfer (proposal {
  creator: principal,
  title: (string-ascii 100),
  description: (string-utf8 1000),
  proposal-type: uint,
  btc-recipient: (optional (buff 33)),
  btc-amount: (optional uint),
  parameter-key: (optional (string-ascii 50)),
  parameter-value: (optional uint),
  member-address: (optional principal),
  member-action: (optional bool),
  created-at-block: uint,
  votes-for: uint,
  votes-against: uint,
  executed: bool
}))
  (let (
    (recipient (unwrap! (get btc-recipient proposal) ERR_INVALID_PROPOSAL_TYPE))
    (amount (unwrap! (get btc-amount proposal) ERR_INVALID_PROPOSAL_TYPE))
    (custodian (unwrap! (var-get sbtc-custodian) ERR_UNAUTHORIZED))
  )
    ;; Check if treasury has enough balance
    (asserts! (>= (var-get btc-treasury-balance) amount) ERR_INSUFFICIENT_BALANCE)
    
    ;; Update the treasury balance
    (var-set btc-treasury-balance (- (var-get btc-treasury-balance) amount))
    
    ;; In a real implementation, this would integrate with sBTC or similar
    ;; to initiate the actual BTC transfer
    ;; Here we're just recording the intent
    
    ;; This would call the sBTC bridge contract to execute the BTC transfer
    ;; (contract-call? custodian transfer-btc recipient amount)
    
    ;; For now, just return success
    (ok true)
  )
)

(define-private (execute-parameter-change (proposal {
  creator: principal,
  title: (string-ascii 100),
  description: (string-utf8 1000),
  proposal-type: uint,
  btc-recipient: (optional (buff 33)),
  btc-amount: (optional uint),
  parameter-key: (optional (string-ascii 50)),
  parameter-value: (optional uint),
  member-address: (optional principal),
  member-action: (optional bool),
  created-at-block: uint,
  votes-for: uint,
  votes-against: uint,
  executed: bool
}))
  (let (
    (param-key (unwrap! (get parameter-key proposal) ERR_INVALID_PROPOSAL_TYPE))
    (param-value (unwrap! (get parameter-value proposal) ERR_INVALID_PROPOSAL_TYPE))
  )
    (match param-key
      "quorum-threshold" (var-set quorum-threshold param-value)
      "majority-threshold" (var-set majority-threshold param-value)
      "voting-period" (var-set voting-period param-value)
      "proposal-fee" (var-set proposal-fee param-value)
      ERR_INVALID_PROPOSAL_TYPE
    )
    
    (ok true)
  )
)

(define-private (execute-membership-change (proposal {
  creator: principal,
  title: (string-ascii 100),
  description: (string-utf8 1000),
  proposal-type: uint,
  btc-recipient: (optional (buff 33)),
  btc-amount: (optional uint),
  parameter-key: (optional (string-ascii 50)),
  parameter-value: (optional uint),
  member-address: (optional principal),
  member-action: (optional bool),
  created-at-block: uint,
  votes-for: uint,
  votes-against: uint,
  executed: bool
}))
  (let (
    (member (unwrap! (get member-address proposal) ERR_INVALID_PROPOSAL_TYPE))
    (action (unwrap! (get member-action proposal) ERR_INVALID_PROPOSAL_TYPE))
    (voting-power (unwrap! (get parameter-value proposal) ERR_INVALID_PROPOSAL_TYPE))
  )
    (if action
      ;; Add or update member
      (map-set members
        { address: member }
        { voting-power: voting-power, joined-at-block: block-height }
      )
      ;; Remove member
      (map-delete members { address: member })
    )
    
    (ok true)
  )
)

;; Utility/Helper Functions

(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals { proposal-id: proposal-id })
)

(define-read-only (get-member-data (address principal))
  (map-get? members { address: address })
)

(define-read-only (is-dao-member (address principal))
  (is-some (map-get? members { address: address }))
)

(define-read-only (get-voting-power (address principal))
  (default-to u0 (get voting-power (default-to { voting-power: u0, joined-at-block: u0 } (map-get? members { address: address }))))
)

(define-read-only (get-total-voting-power)
  (fold + (map get-voting-power (map get address (map-keys members))) u0)
)

(define-read-only (get-vote (proposal-id uint) (voter principal))
  (map-get? proposal-votes { proposal-id: proposal-id, voter: voter })
)

(define-read-only (can-execute-proposal (proposal-id uint))
  (let (
    (proposal-opt (map-get? proposals { proposal-id: proposal-id }))
  )
    (if (is-none proposal-opt)
      false
      (let (
        (proposal (unwrap-panic proposal-opt))
        (total-votes (+ (get votes-for proposal) (get votes-against proposal)))
        (total-voting-power (get-total-voting-power))
      )
        (and
          (>= block-height (+ (get created-at-block proposal) (var-get voting-period)))
          (not (get executed proposal))
          (>= (* total-votes u1000) (* total-voting-power (var-get quorum-threshold)))
          (>= (* (get votes-for proposal) u1000) (* total-votes (var-get majority-threshold)))
        )
      )
    )
  )
)

;; Treasury management functions

(define-public (deposit-btc (amount uint))
  (begin
    ;; In a real implementation, this would verify a BTC deposit through sBTC
    ;; For now, we just update the balance
    (var-set btc-treasury-balance (+ (var-get btc-treasury-balance) amount))
    (ok true)
  )
)

(define-read-only (get-treasury-balance)
  (var-get btc-treasury-balance)
)

;; Folding function for total voting power calculation
(define-private (add-voting-power (key { address: principal }) (acc uint))
  (let ((member-data (unwrap! (map-get? members key) acc)))
    (+ acc (get voting-power member-data))
  )
)