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