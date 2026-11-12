PORTFOLIO 5 - DISTRIBUTED AND CLOUD DATABASE EXERCISE
=====================================================

Case study: CareBridge Clinics. Four branches share one database.
Requirements that make distribution necessary:

  1. AVAILABILITY: a server failure must not stop consultations or
     lose prescriptions/payments.
  2. READ SCALING: management reports must not slow down the front
     desk.
  3. GROWTH: appointment history grows by ~350k rows/year now and
     more as branches are added.

Everything below was BUILT AND EXECUTED, not only described: five real
PostgreSQL 16 servers on one host (different ports stand in for
different machines).

See the topology image: topology.png


FILES
-----

setup_cluster.sh
    What it does: Configures the primary for replication, creates a
                  replicator role and slots, clones REPLICA1 and
                  REPLICA2 with pg_basebackup -R, initialises two
                  SHARD servers
    Evidence:     output/setup_cluster_output.txt

01_sharding.sql
    What it does: Coordinator database carebridge_dist with a
                  hash-partitioned appointment table whose partitions
                  are FOREIGN TABLES ON TWO OTHER SERVERS
    Evidence:     output/sharding_setup_output.txt

02_sharding_queries.sql
    What it does: Row distribution, single-shard routing,
                  scatter-gather, aggregate pushdown, INSERT routing
    Evidence:     output/sharding_queries_output.txt

replication_demo.py
    What it does: Replication lag, stale reads vs read-your-writes,
                  commit latency per durability level, sync-standby
                  outage, crash + failover
    Evidence:     output/replication_demo_output.txt

Run order: setup_cluster.sh -> load and query shards ->
replication_demo.py (the last section deliberately crashes the
primary).


========================================================================

PART A - REPLICATION (AVAILABILITY AND READ SCALING)
----------------------------------------------------

SETUP. Physical streaming replication ships the primary's write-ahead
log (WAL) to standbys that replay it. pg_stat_replication on the
primary shows both standbys "streaming". Standbys are read-only
(pg_is_in_recovery() = true); an INSERT on replica2 fails with
25006 cannot execute INSERT in a read-only transaction.

Measurements (from output/replication_demo_output.txt):

  - Time until a committed row is visible on async replica1 /
    replica2 (50 commits):
        median 0.38 ms / 0.55 ms

  - Peak replay lag during a 200,000-row bulk insert:
        approx. 15 MB of WAL, back to 0 bytes after catch-up

  - Read from ASYNC replica2 immediately after writing on primary:
        200 / 200 STALE READS

  - Read from replica1 with synchronous_commit = remote_apply:
        0 / 200 STALE READS (read-your-writes guaranteed)


COMMIT LATENCY BY DURABILITY LEVEL (replica1 = synchronous standby):

  synchronous_commit = off
      Waits for:          nothing (WAL flushed later)
      Median commit:      0.066 ms
      Data-loss window:   last few ms of commits, even with no
                          failover

  synchronous_commit = local
      Waits for:          primary's own disk flush
      Median commit:      0.714 ms
      Data-loss window:   async standby may miss recent commits

  synchronous_commit = remote_write
      Waits for:          standby received WAL (OS buffer)
      Median commit:      0.704 ms
      Data-loss window:   only if primary AND standby OS crash
                          together

  synchronous_commit = on
      Waits for:          standby FLUSHED WAL to disk
      Median commit:      0.867 ms
      Data-loss window:   NONE (RPO = 0)

  synchronous_commit = remote_apply
      Waits for:          standby REPLAYED WAL (visible to queries)
      Median commit:      1.004 ms
      Data-loss window:   none, PLUS read-your-writes on the standby

On one machine the network round trip is ~0, so the gaps are small.
Across availability zones each level adds a round trip, which is why
the setting can be chosen PER TRANSACTION: payments and dispensing use
"on", audit-log inserts could use "local".


CONSISTENCY VS AVAILABILITY (CAP / PACELC IN PRACTICE)

With synchronous_standby_names = 'FIRST 1 (replica1)', replica1 was
stopped:

    COMMIT still waiting after 3 s -> pg_stat_activity: [('IPC', 'SyncRep', 'active')]
    WARNING: canceling wait for synchronous replication due to user request
    DETAIL:  The transaction has already committed locally, but might not have been replicated to the standby.

  - CONSISTENCY OVER AVAILABILITY: the primary REFUSES TO CONFIRM
    commits it cannot replicate. The clinic's writes stall when the
    only sync standby is down.

  - Cancelling the wait does NOT roll back: the row is already
    committed locally. Applications must treat a cancelled sync
    commit as "outcome unknown", never as "failed".

  - FIX: quorum replication ANY 1 (replica1, replica2). The next
    commit succeeded in 5.2 ms because replica2 acknowledged it. Two
    standbys tolerate one standby failure without stalling writes,
    and RPO stays 0.

  - PACELC: EVEN WITHOUT A PARTITION, stronger consistency costs
    latency (see the commit latency figures above).


FAILOVER

    committed row id 403913 (synchronous) - then simulate a crash with pg_ctl stop -m immediate
    primary unreachable: connection refused
    replica1 (:5433) is now primary; accepted a write 0.22 s after the crash  (RTO, excluding failure detection)
    last synchronous commit (id 403913) present on new primary: True  -> RPO = 0 transactions lost
    WAL timeline on new primary: 2 (was 1; promotion starts a new timeline ...)
    new primary's pg_stat_replication: [('replica2', 'streaming')]
    replica2 sees the post-failover write: True

  - RPO = 0 because the last commit was synchronous.

  - RTO 0.22 s here is promotion time only. Real RTO is dominated by
    FAILURE DETECTION AND CLIENT REDIRECTION, which tools like Patroni
    (with etcd) or a managed service handle; promotion was manual
    here.

  - The old primary must NOT be restarted as-is: it would form a
    second writable primary (SPLIT BRAIN) on a diverged timeline. It
    has to be rebuilt with pg_rewind or a fresh pg_basebackup.


========================================================================

PART B - SHARDING (HORIZONTAL SCALE)
------------------------------------

DESIGN. appointment is PARTITION BY HASH (patient_id) on the
coordinator, and each partition is a postgres_fdw FOREIGN TABLE STORED
ON A DIFFERENT SERVER. This is the same architecture Citus automates
(coordinator plus workers, distribution column).

CHOOSING THE SHARD KEY: patient_id

  - The most frequent query, patient history, filters on it, so it
    hits exactly ONE shard.

  - All of a patient's visits are CO-LOCATED, so per-patient joins
    and aggregates never cross servers.

  - Hashing spreads load evenly: 500,566 vs 499,434 rows
    (50.06% / 49.94%).

  - Rejected alternatives: branch_id gives only 4 values and a hot
    spot at the busiest branch. scheduled_at sends all CURRENT writes
    to one shard (a hot spot on the newest range).


Query results (plan evidence from output/sharding_queries_output.txt):

  1. Patient history WHERE patient_id = 4321
       Plan:     ONE Foreign Scan on appointment_s0, remote SQL
                 contains WHERE patient_id = 4321 ORDER BY ...
       Meaning:  PARTITION PRUNING: only shard_a is contacted

  2. Visits per branch in 2025 (no shard key)
       Plan:     Append over BOTH foreign scans, 350,400 ROWS shipped
                 to the coordinator, then HashAggregate
       Meaning:  SCATTER-GATHER. Filters are pushed down, rows still
                 travel

  3. Same with enable_partitionwise_aggregate = on
       Plan:     Partial aggregation per shard, but STILL ON THE
                 COORDINATOR
       Meaning:  PostgreSQL 16's postgres_fdw can't push PARTIAL
                 aggregates (grouping column is not the shard key)

  4. Visits per PATIENT in 2025
       Plan:     Relations: Aggregate on (appointment_s0), remote SQL
                 ... GROUP BY 1
       Meaning:  FULL AGGREGATE PUSHDOWN: each shard groups its own
                 rows because the GROUP BY includes the shard key

  5. INSERT ... patient_id = 4321
       Plan:     row lands in appointment_s0
       Meaning:  TUPLE ROUTING by hash


LIMITATIONS OF THIS DIY SHARDING (why production systems use Citus or
similar):

  - No distributed transaction guarantee across shards (postgres_fdw
    uses a separate remote transaction per server, not two-phase
    commit).

  - Unique constraints and foreign keys can't be enforced across
    shards.

  - Re-sharding (2 -> 4 servers) means moving data manually.

  - Each shard is itself a single point of failure unless it also
    gets replicas (Part A applies per shard).


========================================================================

PART C - CLOUD DEPLOYMENT DESIGN FOR CAREBRIDGE
-----------------------------------------------

HA for the primary
    Design:     Synchronous standby in a second availability zone,
                automatic failover
    Managed:    AMAZON RDS FOR POSTGRESQL MULTI-AZ: synchronous
                standby in another AZ, RPO 0, failover usually 1-2
                minutes (AWS); ~35 s or less for Multi-AZ DB CLUSTER
                (two readable standbys)

Reporting reads
    Design:     Async read replica (replica2 role)
    Managed:    RDS read replicas / Azure read replicas

Horizontal scale (later)
    Design:     Shard on patient_id
    Managed:    CITUS. On Azure the recommended route is now Elastic
                Clusters in Azure Database for PostgreSQL; Microsoft
                has stopped recommending Azure Cosmos DB for
                PostgreSQL for new projects

Document store / cache
    Design:     Portfolio 4 models
    Managed:    MongoDB Atlas; Amazon ElastiCache / Azure Cache for
                Redis

Backups
    Design:     WAL archiving + daily base backups -> point-in-time
                recovery
    Managed:    Built into RDS / Azure Flexible Server

Data protection
    Design:     Patient health data is SENSITIVE PERSONAL DATA under
                the Nigeria Data Protection Act 2023, and cross-border
                transfer needs an adequacy basis or another lawful
                ground. Region choice (e.g. in-country hosting vs a
                foreign cloud region) needs a legal/DPO decision.
                Encrypt at rest and in transit, least-privilege roles,
                audit logging
    Managed:    KMS-managed encryption, TLS-only connections, private
                subnets

(The legal point is context for the design, not legal advice.)


REFERENCES
----------

PostgreSQL 16 docs
  - High Availability, Load Balancing, and Replication
    https://www.postgresql.org/docs/16/high-availability.html
  - synchronous_commit
    https://www.postgresql.org/docs/16/runtime-config-wal.html#GUC-SYNCHRONOUS-COMMIT
  - postgres_fdw
    https://www.postgresql.org/docs/16/postgres-fdw.html
  - Table partitioning
    https://www.postgresql.org/docs/16/ddl-partitioning.html

AWS
  - Choose the right Amazon RDS deployment option
    https://aws.amazon.com/blogs/database/choose-the-right-amazon-rds-deployment-option-single-az-instance-multi-az-instance-or-multi-az-database-cluster
  - Multi-AZ DB instance deployments
    https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.MultiAZSingleStandby.html

Microsoft
  - Fundamental concepts for scaling (Citus)
    https://learn.microsoft.com/en-us/azure/cosmos-db/postgresql/quickstart-build-scalable-apps-concepts
  - What is Citus
    https://learn.microsoft.com/en-us/postgresql/citus/what-is-citus

Nigeria Data Protection Act 2023
  - Overview of key provisions
    https://www.mondaq.com/nigeria/privacy-protection/1346676/an-overview-of-the-nigeria-data-protection-act-2023
  - Cross-border transfer in healthcare
    https://www.mondaq.com/nigeria/data-protection/1485276/cross-border-data-transfer-in-the-healthcare-sector-legal-considerations-and-best-practices
