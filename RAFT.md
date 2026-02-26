# Raft Consensus
Replicated And Fault-Tolerant

This document explains Raft using simple ASCII diagrams to visualize what happens in the cluster.

------------------------------------------------------------------------

# 1️⃣ Cluster Startup

All nodes start as Followers.

    +----+    +----+    +----+
    | N1 |    | N2 |    | N3 |
    | F  |    | F  |    | F  |
    +----+    +----+    +----+

One node times out first (randomized election timeout).

    N2 timeout → becomes Candidate (Term 1)

Requests votes:

    N2 → N1 : RequestVote
    N2 → N3 : RequestVote

If majority votes yes:

    +----+    +----+    +----+
    | N1 |    | N2 |    | N3 |
    | F  |    | L  |    | F  |
    +----+    +----+    +----+

✅ Exactly one leader\
✅ Term 1 established

------------------------------------------------------------------------

# 2️⃣ Normal Write Flow

Client sends write to Leader.

    Client
       |
       v
    +----+
    | N2 |  (Leader)
    +----+

Leader appends to its log:

    Leader Log:
    [ (1,A) ]

Leader replicates:

              AppendEntries
    N2 --------------------> N1
    N2 --------------------> N3

Logs after replication:

    N2: [ (1,A) ]
    N1: [ (1,A) ]
    N3: [ (1,A) ]

Once majority acknowledges:

    Entry COMMITTED

Only now is it applied to the state machine.

------------------------------------------------------------------------

# 3️⃣ Leader Crash

Before crash:

    +----+    +----+    +----+
    | N1 |    | N2 |    | N3 |
    | F  |    | L  |    | F  |
    +----+    +----+    +----+

Leader crashes:

    N2 ❌

Followers stop receiving heartbeats:

    (heartbeat timeout)

New election (Term 2):

    N1 → Candidate (Term 2)

Wins majority:

    +----+    +----+    +----+
    | N1 |    | N2 |    | N3 |
    | L  |    | X  |    | F  |
    +----+    +----+    +----+

✅ Automatic failover\
✅ Term increased prevents stale leader

------------------------------------------------------------------------

# 4️⃣ Split Brain (Network Partition)

5-node cluster:

    N1  N2  N3  N4  N5

Partition occurs:

    Majority Side (3 nodes)     Minority Side (2 nodes)

    +----+  +----+  +----+      +----+  +----+
    | N1 |  | N2 |  | N3 |      | N4 |  | N5 |
    +----+  +----+  +----+      +----+  +----+

Majority side:

-   Can elect leader
-   Can commit writes

Minority side:

-   Cannot reach quorum (needs 3)
-   Cannot elect valid leader
-   Cannot commit writes

🚫 No split-brain writes possible

------------------------------------------------------------------------

# 5️⃣ Log Divergence Example

Suppose old leader wrote entry C but crashed before majority
replication.

Before crash:

    N2 (Leader): [A, B, C]
    N1:           [A, B]
    N3:           [A, B]

C not on majority → NOT committed.

New leader elected from majority (Term 2):

    N1 becomes Leader
    Log: [A, B]

Entry C disappears.

✅ Only majority-replicated entries survive

------------------------------------------------------------------------

# 6️⃣ Partition with Conflicting Writes

During partition:

Majority side commits D:

    Majority:
    [A, B, D]

Minority side (illegitimate leader) writes X:

    Minority:
    [A, B, X]

When partition heals:

Leader compares logs:

    Majority Leader: [A, B, D]
    Follower:        [A, B, X]
                              ^ conflict

Resolution:

    Delete X
    Append D

Final state:

    [A, B, D]

✅ Logs converge automatically

------------------------------------------------------------------------

# 7️⃣ Why Majority Works (Overlap Property)

5 nodes → majority = 3

Any two majorities overlap by at least one node.

Example:

    Majority 1: N1 N2 N3
    Majority 2: N3 N4 N5
                      ^ overlap

That overlapping node ensures:

-   Committed entries cannot disappear
-   New leader always has prior committed entries

This mathematical overlap is Raft's core safety guarantee.

------------------------------------------------------------------------

# 8️⃣ Term Rule (Prevents Stale Leaders)

If a node receives a message with higher term:

    if incoming_term > current_term:
        step down to Follower

This guarantees:

-   No two leaders in same term
-   Old leaders cannot continue after partition

------------------------------------------------------------------------

# Mental Model

Raft turns a cluster into:

              +-------------------------+
    Client →  |   Distributed Log       |
              |  (Replicated + Ordered) |
              +-------------------------+

If the log is consistent, the system is consistent.

Everything flows through that log.

------------------------------------------------------------------------

# Summary

Raft solves:

-   Leader election
-   Split brain prevention
-   Log consistency
-   Safe failover
-   Conflict resolution

By combining:

-   Terms
-   Majority quorum
-   Leader-only writes
-   Deterministic log reconciliation

Result:

A fault-tolerant, strongly consistent distributed state machine.
