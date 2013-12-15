### Introduction
Rafter is more than just an erlang implementation of the [raft consensus
protocol](https://ramcloud.stanford.edu/wiki/download/attachments/11370504/raft.pdf).
It aims to take the pain away from building Consistent(2F+1 CP) distributed
systems, as well as act as a library for leader election and routing. A main
goal is to keep a very small user api that automatically handles the problems of
the everyday Erlang distributed systems developer. It is hopefully your
***libPaxos.dll*** for erlang.

Rafter is meant to be used as a library application on an already created erlang
cluster of 3, 5, or 7 nodes. rafter peers are uniquely identified by atoms in a
local setup and ```{Name, Node}``` tuples when using distributed erlang.
Configuration is dynamic and reconfiguration can be achieved without taking the
system down.

#### Distributed consensus with a replicated log 
For use cases such as implementing distributed databases, a replicated log can
be used internally to provide strong consistency. Operations are serialized and
written to log files in the same order on each node. Once the operation is
committed by a node it is applied to the state machine backend. In the case of a
distributed database, the operation would probably be to create or update an
item in the database. The leader will not return success to the client until the
operation is safely replicated. It is clear that applying these types of
deterministic operations in the same order will produce the same output each
time, and hence if one machine crashes, others can still be accessed without any
data loss. These serialized operations can continue as long as a majority of the
nodes can communicate. If the majority of nodes cannot agree then the system
rejects requests for both reads and writes. In mathematical terms, a cluster of
2f+1 nodes can handle f failures. The most common cluster sizes are 3 nodes,
which can handle 1 failure and still work, and 5 which can handle two failures.

It is important to note, that because operations are logged ***before*** they
are executed by the state machine, they cannot be allowed to fail arbitrarily
(without bringing down the peer),
or exhibit other non-deterministic behavior when executed by the state machine.
If this were allowed, there would be no way to guarantee that each replica had
the same state after the state machine transformation, nor could you tell which
replica had the ***correct*** data! In other words, state machine operations
should be pure functions and the state machine must be deterministic. Each
replay of the in-order operations on each node must result in the exact same
output state or else you cannot use the safety properties given to you by
replicated logs. Note lastly, that operations that base their output state on
the current time of day are inherently non-deterministic in distributed systems
and should not be allowed in the state machines.

An additional benefit of having a deterministic state machine is that it allows
snapshotting of the current state to disk and truncating the already applied
operations in the log after the state machine output is successfully
snapshotted. This is known as ***compaction*** and provides output durability
for the state machine itself which allows faster restarts on failed nodes, since
the entire log no longer needs to be replayed. You can read more about compaction
[here](https://ramcloud.stanford.edu/wiki/download/attachments/12386595/compaction.pdf?version=1&modificationDate=1367123151531).

## Development Environment Quick Start
Rafter is currently under development and not quite ready for production use.
However, it is easy to get started playing with rafter on your local machine.
The following will describe the easiest way to get a development cluster of 3
nodes running. Note that you must have a version of *Erlang >= R16B01* in order
for rafter to work.

Since consensus is really only important across nodes, previous
descriptions of running on a single node have been removed. Furthermore, there
are implementation details in the ets backend that only allow it to run one
instance of rafter on a VM at a time. That will be changed in future releases.

### Clone and Build
    git clone git@github.com:andrewjstone/rafter.git
    cd rafter
    make deps
    make
    mkdir data  ## this directory will store the rafter log and metadata for your 3 nodes

### Launch 3 nodes
Open three new terminals on your machine. In each of the following terminals run
the following:

    cd rafter
    bin/start-node peerX
    
The above starts up an erlang VM with appropriate cookie and code path, and
starts a rafter peer utilizing the ``rafter_ets_backend``. The node name, in
this case PeerX (X=1|2|3), should be unique for each node. 

These three nodes can now be operated on by the rafter client API. They all have
empty logs at this point and no configuration. Note that all operations on
rafter should be performed via the client API in
[rafter.erl](https://github.com/andrewjstone/rafter/blob/master/src/rafter.erl).

### Set the initial configuration of the cluster.
Rafter clusters support reconfiguration while the system is running. However,
they start out blank and the first entry in any log must be a configuration
entry which you set at initial cluster start time. Note that the operation will
fail with a timeout if a majority of nodes are not reachable. However, once
those peers become reachable, the command will be replicated and the cluster
will be configured. 

Go to the first erlang shell, where peer1 is running. We're just arbitrarily
choosing a node to be the first leader here. Ensure it is running with
``sys:get_state(peer1).``

You should see something similar to the following, which is the state of
`rafter_consensus_fsm`.

```
(peer1@127.0.0.1)1> rr(rafter_consensus_fsm).
[append_entries,append_entries_rpy,client_req,config,meta,
 rafter_entry,rafter_opts,request_vote,state,vote]
(peer1@127.0.0.1)2> sys:get_state(peer1).
{follower,#state{leader = undefined,term = 0,
    voted_for = undefined,commit_index = 0,
    init_config = undefined,timer =#Ref<0.0.0.284>,
    followers = {dict,0,16,16,8,80,48,
                    {[],[],[],[],[],[],[],[],[],[],[],...},
                    {{[],[],[],[],[],[],[],[],[],...}}},
    responses = {dict,0,16,16,8,80,48,
                    {[],[],[],[],[],[],[],[],[],[],...},
                    {{[],[],[],[],[],[],[],[],...}}},
    send_clock = 0,
    send_clock_responses = {dict,0,16,16,8,80,48,
                                {[],[],[],[],[],[],[],[],...},
                                {{[],[],[],[],[],[],...}}},
    client_reqs = [],read_reqs = [],
    me = {peer1,'peer1@127.0.0.1'},
    config = #config{state = blank, oldservers = [],
                     newservers = []},
    state_machine = rafter_backend_ets,
    backend_state = {state,{peer1,'peer1@127.0.0.1'}}}}
```

Set the config for the cluster. Note that because we are talking to a
process, `peer1`, registered locally on the node `peer1@127.0.0.1`, we
don't need to use the fully qualified name when talking to it via the shell on
peer1.

```erlang
    Peers = [{peer1, 'peer1@127.0.0.1'}, 
             {peer2, 'peer2@127.0.0.1'}, 
             {peer3, 'peer3@127.0.0.1'}],
    rafter:set_config(peer1, Peers).
```

### Write Operations
Write operations are written to the log before being fed to the backend state
machine. In general multiple statemachine backends can implement the same
backend protocol. Operations are opaque to rafter and depend on what is provided
by the backend state machine. The following operations are available when the
ets backend is in use. It is anticipated that this API will grow to include
multi-key and potentially global transactions.

```erlang
   %% Create a new ets table 
   rafter:op(peer1, {new, sometable}).

   %% Store an erlang term in that table
   rafter:op(peer1, {put, sometable, somekey, someval}).

   %% Delete a term from the table
   rafter:op(peer1, {delete, sometable, somekey}).

   %% Delete a table
   rafter:op(peer1, {delete, sometable}).
```

### Read Operations
Read Operations don't need to be written to the persistent log, however they
still need to get a quorum from the peers and still need to read from the rafter
backend. The ets backend provides the following read operations.

```erlang
  %% Read an erlang term
  rafter:read_op(peer1, {get, Table, Key}).

  %% list tables
  rafter:read_op(peer1, list_tables).

  %% list keys
  rafter:read_op(peer1, {list_keys, Table}).
```

### Show the current state of the log for a peer
    
    rr(rafter_log),
    sys:get_state(peer1_log).

### running tests
Tests require [erlang quickcheck](http://quviq-licencer.com/trial.html) currently. Unfortunately this is not free and the trial version may or may not be a supported version.

    make test

### TODO
 * Automatically forward requests to the leader instead of returning a
  redirect
 * Add transactions to ets backend
 * Add multi-key and multi-table query support to ets backend
 * Compaction
   * start with snapshotting assuming data is ```small``` as described in
    section 2 [here](https://ramcloud.stanford.edu/wiki/download/attachments/12386595/compaction.pdf?version=1&modificationDate=1367123151531)
 * Client interface
   * Client Sequence number for idempotent counters? 
   * Redis like text-based interface ?
   * HTTP ?
 * parallel eqc tests
 * Anti-Entropy 
   * Write AAE info into snapshot file during snapshotting

### License

Apache 2.0
http://www.apache.org/licenses/LICENSE-2.0.html
