**[00:00] Me:** Let's lock the caching layer. I propose Redis for the pub-sub support.

**[00:12] Them:** Agreed on Redis. Open question: do we need cluster mode from day one?

**[00:26] Me:** I'll draft the eviction-policy doc by Thursday.

**[00:38] Them:** Please benchmark failover latency before we commit to a cluster.

**[00:52] Me:** Fair. I'll borrow the load harness from the search team for that.

**[01:06] Them:** While we're here: the session store. Does it move to Redis too, or stay in Postgres?

**[01:22] Me:** Stay in Postgres for now. One migration at a time.

**[01:36] Them:** Okay. TTLs: product wants recaps cached for a week, search results for an hour.

**[01:50] Me:** That maps to two keyspaces with separate eviction. I'll put it in the doc.

**[02:04] Them:** Ship it. Let's reconvene once the failover numbers are in.