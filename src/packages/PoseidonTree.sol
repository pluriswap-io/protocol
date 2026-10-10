// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Poseidon} from "./libraries/Poseidon.sol";

/// @dev The root window: how many past roots a tree keeps acceptable, and the bounds on that choice.
///      File-level so owners can pass `DEFAULT_ROOT_HISTORY` at construction.
///
///      Why it is not 64. The accounts tree is SHARED: every activation and every `claim` of every
///      subject inserts a leaf, so the window is denominated in OTHER people's deals, not in your
///      own. A two-sided private deal is about four inserts, so 64 roots is ~16 deals of tolerance
///      between the moment a prover builds a proof and the moment it lands — under a minute of
///      protocol traffic. A proof that misses its window is a failed activation, not a retry.
///
///      Why a long window is not a weaker one. Replay is stopped by the nullifiers (`nullRep`,
///      `nullBond`), never by root recency: an old root only ever proves membership of a leaf that
///      really was there, and the leaf's version can still only be spent once. The window is a
///      liveness parameter, not a security one — which is why the cost of widening it had to be
///      removed from the lookup (see `_knownRoot`) rather than paid.
uint256 constant MIN_ROOT_HISTORY = 64;
uint256 constant MAX_ROOT_HISTORY = 65_536;
uint256 constant DEFAULT_ROOT_HISTORY = 4096;

/// @title PoseidonTree
/// @notice Incremental binary Merkle tree over the BN254 scalar field, Poseidon-hashed and
///         circomlib-compatible (PROTOCOLO.md §E.3.15.3).
/// @dev Hashing runs through the pinned poseidon-solidity singleton (`Poseidon`, PROTOCOLO.md §E.5.1),
///      called by address and never linked: our own build of that library is 29,315 B, past EIP-170.
///      One contract is one tree: the accounts tree (depth 32, owner `PrivateReputation`) and the
///      notes tree (depth 20, owner `PrivateBondVault` in F3). The owner is passed explicitly and
///      predicted at deploy, because the tree must be wired into the passports of the bundle before
///      its owning module exists. `insert` and `spend` are owner-only, so nothing outside the module
///      can move roots or burn nullifiers. Roots live in a `rootHistory`-slot ring buffer; proofs
///      may reference any root still in the ring (`isKnownRoot`). The empty-tree root is seeded into
///      the ring at deploy, so it is "known" too. A zero leaf is rejected: a real leaf must never
///      alias the zero element. Leaf, root and nullifier values are BN254 field elements passed as
///      bytes32 and hashed as uint256 internally.
contract PoseidonTree {
    uint256 public constant MAX_DEPTH = 32;

    uint8 public immutable depth;
    /// @dev How many past roots stay acceptable. Per tree, because traffic is per tree.
    uint256 public immutable rootHistory;
    address public immutable owner;

    uint256[] private zeros;
    uint256[] private filledSubtrees;
    /// @dev FIFO order, for eviction only — membership is answered by `_knownRoot`, never by a scan.
    bytes32[] private rootRing;
    /// @dev The window as a set. This is what makes a big window affordable: `isKnownRoot` sits on
    ///      the hot path of every activation, claim, withdraw and register-verify, and scanning an
    ///      N-slot ring cost N cold SLOADs — 140k gas measured at N = 64, linear from there.
    mapping(bytes32 root => bool inWindow) private _knownRoot;
    uint256 private rootCursor;

    uint256 public nextIndex;
    uint256 private currentRoot;

    mapping(bytes32 => bool) public isSpent;

    event LeafInserted(uint256 indexed index, bytes32 leaf, uint256 root);
    event NullifierSpent(bytes32 indexed nullifier);

    error BadDepth();
    error BadRootHistory();
    error ZeroOwner();
    error TreeFull();
    error ZeroLeaf();
    error NotOwner();
    error NullifierUsed();
    error EmptyBatch();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(uint8 depth_, uint256 rootHistory_, address owner_) {
        if (depth_ == 0 || depth_ > MAX_DEPTH) revert BadDepth();
        if (rootHistory_ < MIN_ROOT_HISTORY || rootHistory_ > MAX_ROOT_HISTORY) revert BadRootHistory();
        if (owner_ == address(0)) revert ZeroOwner();
        depth = depth_;
        rootHistory = rootHistory_;
        owner = owner_;

        zeros.push(0);
        for (uint8 level = 1; level <= depth_; level++) {
            zeros.push(_hashPair(zeros[level - 1], zeros[level - 1]));
        }
        for (uint8 level = 0; level < depth_; level++) {
            filledSubtrees.push(zeros[level]);
        }
        currentRoot = zeros[depth_];
        _remember(bytes32(currentRoot));
    }

    /// @notice Appends several leaves at once and returns the first index and the resulting root.
    ///         Produces exactly the tree `insert` called in sequence would, for a fraction of the
    ///         hashing: the leaves land at adjacent indices, so everything above the bottom of their
    ///         common subtree is hashed once instead of once per leaf.
    ///
    /// @dev Why it is worth the extra code: a private activation inserts several leaves into the same
    ///      tree in one transaction (an account leaf per side, a change note per side), and each
    ///      `insert` walked its whole path alone. Measured at depth 32, four separate inserts are 128
    ///      hashes; the same four leaves batched are 37.
    ///
    ///      The algorithm is the sequential one, read level by level instead of leaf by leaf. At each
    ///      level the batch occupies a contiguous run of node indices `[lo, hi]`. A parent's children
    ///      come from that run when they are inside it; the left neighbour of `lo` (when `lo` is odd)
    ///      is the subtree already in the tree, which is exactly what `filledSubtrees[level]` held
    ///      BEFORE this batch — hence the read before the write — and anything past `hi` is empty, so
    ///      `zeros[level]`. `filledSubtrees[level]` ends up holding the node at the largest EVEN index
    ///      of the run, which is what the last sequential insert to pass through an even cursor would
    ///      have left there.
    ///
    ///      Only the FINAL root is remembered. The intermediate roots a sequential run would have
    ///      published never existed, so no proof can reference one; the window simply holds fewer,
    ///      further-apart roots, which makes it last longer.
    function insertMany(bytes32[] calldata leaves) external onlyOwner returns (uint256 firstIndex, bytes32 newRoot) {
        uint256 k = leaves.length;
        if (k == 0) revert EmptyBatch();
        firstIndex = nextIndex;
        if (firstIndex + k > uint256(1) << depth) revert TreeFull();

        uint256[] memory cur = new uint256[](k);
        for (uint256 i = 0; i < k; i++) {
            if (leaves[i] == bytes32(0)) revert ZeroLeaf();
            cur[i] = uint256(leaves[i]);
        }

        uint256 lo = firstIndex;
        uint256 hi = firstIndex + k - 1;
        for (uint8 level = 0; level < depth; level++) {
            uint256 neighbour = filledSubtrees[level]; // read BEFORE the write: the tree as it was
            if (hi % 2 == 0) {
                filledSubtrees[level] = cur[hi - lo];
            } else if (hi - 1 >= lo) {
                filledSubtrees[level] = cur[hi - 1 - lo];
            }

            uint256 plo = lo >> 1;
            uint256 phi = hi >> 1;
            uint256[] memory parents = new uint256[](phi - plo + 1);
            for (uint256 p = 0; p < parents.length; p++) {
                uint256 j = (plo + p) << 1; // the left child's index at this level
                uint256 left = j >= lo ? cur[j - lo] : neighbour;
                uint256 right = j + 1 <= hi ? cur[j + 1 - lo] : zeros[level];
                parents[p] = _hashPair(left, right);
            }
            cur = parents;
            lo = plo;
            hi = phi;
        }

        nextIndex = firstIndex + k;
        currentRoot = cur[0];
        newRoot = bytes32(currentRoot);
        _remember(newRoot);

        // One event per leaf, as a single insert emits: the indexer rebuilds from (index, leaf). The
        // root each one carries is the batch's — a root that contains that leaf, which is the only
        // thing the field ever promised.
        for (uint256 i = 0; i < k; i++) {
            emit LeafInserted(firstIndex + i, leaves[i], currentRoot);
        }
        return (firstIndex, newRoot);
    }

    /// @notice Appends `leaf` and returns its index and the new root. Cost: `depth` Poseidon hashes.
    function insert(bytes32 leaf) external onlyOwner returns (uint256 index, bytes32 newRoot) {
        uint256 node = uint256(leaf);
        if (node == 0) revert ZeroLeaf();
        if (nextIndex >= uint256(1) << depth) revert TreeFull();

        uint256 cursor = nextIndex;
        for (uint8 level = 0; level < depth; level++) {
            if (cursor & 1 == 0) {
                filledSubtrees[level] = node;
                node = _hashPair(node, zeros[level]);
            } else {
                node = _hashPair(filledSubtrees[level], node);
            }
            cursor >>= 1;
        }

        index = nextIndex;
        nextIndex = index + 1;
        currentRoot = node;
        _remember(bytes32(node));

        emit LeafInserted(index, leaf, node);
        return (index, bytes32(node));
    }

    /// @notice Root of the empty tree until the first insert; root after the last insert afterwards.
    function root() external view returns (bytes32) {
        return bytes32(currentRoot);
    }

    /// @notice True while `root_` is one of the last `rootHistory` roots (empty-tree root included).
    /// @dev O(1): one SLOAD, whatever the window. The ring only decides what leaves the window.
    function isKnownRoot(bytes32 root_) external view returns (bool) {
        return root_ != 0 && _knownRoot[root_];
    }

    /// @notice Burns `nullifier` for this tree; burning the same value twice reverts.
    function spend(bytes32 nullifier) external onlyOwner {
        if (isSpent[nullifier]) revert NullifierUsed();
        isSpent[nullifier] = true;
        emit NullifierSpent(nullifier);
    }

    /// @dev Adds a root to the window and drops the one it displaces. While the ring is still
    ///      filling, nothing is displaced. The `evicted != root_` guard is for the case a root
    ///      repeats inside one window: dropping it then would un-know a root that is still live.
    ///      Roots cannot actually repeat (every insert grows the tree), so this only makes the
    ///      set and the ring impossible to disagree, rather than relying on that argument.
    function _remember(bytes32 root_) private {
        if (rootRing.length < rootHistory) {
            rootRing.push(root_);
        } else {
            bytes32 evicted = rootRing[rootCursor];
            if (evicted != root_) delete _knownRoot[evicted];
            rootRing[rootCursor] = root_;
        }
        unchecked {
            rootCursor = rootCursor + 1 == rootHistory ? 0 : rootCursor + 1;
        }
        _knownRoot[root_] = true;
    }

    /// @dev The pinned poseidon-solidity singleton, called by address (PROTOCOLO.md §E.5.1) — never a
    ///      library linked into this tree, whose build is past EIP-170. On a chain where the
    ///      singleton was never deployed this reverts, and since the constructor seeds `zeros` with
    ///      it, a tree can never exist without a hasher.
    function _hashPair(uint256 left, uint256 right) private view returns (uint256) {
        return Poseidon.t3(left, right);
    }
}
