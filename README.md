# UNDER CONSTRUCTION

***Note that Rafter is in the process of being built and some of the things described below may be buggy or incomplete.***

### Introduction
Rafter is more than just an erlang implementation of the [raft consensus protocol](https://ramcloud.stanford.edu/wiki/download/attachments/11370504/raft.pdf). It aims to take the pain away from building Consistent(2F+1 CP) distributed systems, as well as act as a library for leader election and routing. A main goal is to keep a very small user api that automatically handles the problems of the everyday Erlang distributed systems developer. It is hopefully your ***libPaxos.dll*** for erlang.

Rafter is meant to be used as a library application on an already created erlang cluster of 3, 5, or 7 nodes. rafter peers are uniquely identified by atoms in a local setup and ```{Name, Node}``` tuples when using distributed erlang. Configuration is dynamic and reconfiguration can be achieved without taking the system down.

### Use cases
The primary use case for rafter is distributed consensus with a replicated log. This abstraction can be used in place of paxos and zab.

#### Distributed consensus with a replicated log
For use cases such as implementing distributed databases, a replicated log can be used internally to provide strong consistency. Operations are serialized and written to log files in the same order on each node. Once the operation is committed by a node it is applied to the state machine backend. In the case of a distributed database, the operation would probably be to create or update an item in the database. The leader will not return success to the client until the operation is safely replicated. It is clear that applying these types of deterministic operations in the same order will produce the same output each time, and hence if one machine crashes, others can still be accessed without any data loss. These serialized operations can continue as long as a majority of the nodes can communicate. If the majority of nodes cannot agree then the system rejects requests for both reads and writes. In mathematical terms, a cluster of 2f+1 nodes can handle f failures. The most common cluster sizes are 3 nodes, which can handle 1 failure and still work, and 5 which can handle two failures.

It is important to note, that because operations are logged ***before*** they are executed by the state machine, they cannot be allowed to fail arbitrarily, or exhibit other non-deterministic behavior when executed by the state machine. If this were allowed, there would be no way to guarantee that each replica had the same state after the state machine transformation, nor could you tell which replica had the ***correct*** data! In other words, state machine operations should be pure functions and the state machine must be deterministic. Each replay of the in-order operations on each node must result in the exact same output state or else you cannot use the safety properties given to you by replicated logs. Note lastly, that operations that base their output state on the current time of day are inherently non-deterministic in distributed systems and should not be allowed in the state machines.

An additional benefit of having a deterministic state machine is that it allows snapshotting of the current state to disk and truncating the already applied operations in the log after the state machine output is successfully snapshotted. This is known as ***compaction*** and provides output durability for the state machine itself which allows faster restarts on failed nodes, since the entire log no longer needs to be replayed. You can read more about compaction [here](https://ramcloud.stanford.edu/wiki/download/attachments/12386595/compaction.pdf?version=1&modificationDate=1367123151531).

## Client API
All operations on rafter should be performed via the client API in [rafter.erl](https://github.com/andrewjstone/rafter/blob/master/src/rafter.erl).

### starting a cluster of 5 nodes on a single vm for testing. Start all dependencies.
The peers are all simple erlang processes. The consensus fsm's are named peer1..peer5.
The corresponding log gen_servers are named peer1_log..peer5_log. Other processes are named in a similar fashion.

    rafter:start_cluster().

### Set the initial configuration of the cluster.
Rafter clusters support reconfiguration while the system is running. However, they start out blank and the first entry in any log must be a configuration entry which you set at initial cluster start time. Note that the operation will fail with a timeout if a majority of nodes are not reachable. However, once those peers become reachable, the command will be replicated and the cluster will be configured. 

Since we already started our peers with the command above, this should succeed. ```peer1``` is arbitrary during initial config. It will become the first leader.

```erlang
    %% Remote Config
    %% Nodes = [{peer1, node1@example.com}, {peer2, node2@example.com}, {peer3, node3@example.com}],

    %% Local Config
    Servers = [peer1, peer2, peer3, peer4, peer5],

    rafter:set_config(peer1, Servers).
```

### Run an operation against the backend state machine
Rafter allows customized backends that can run arbitrary code as long as that code is deterministic. The backend operations are replicated in the normal way and when the log entry is committed, the operations will be run against the configured state machine. The state machine configured with our local test cluster is 'rafter_sm_echo' and simply echo's back the arbitrary term given as 'Command'.
    
   ```erlang
   Command = do_something,
   rafter:op(peer1, Command).
   ```

### Backend state machine callback modules
Each rafter consensus group can utilize it's own state machine as long as the code is accessible in each erlang node's virtual machine. When a node is started the name of the backend module is passed in as shown below.

```erlang
    Me = peer1,
    StateMachine = safe_redis,
    rafter:start_node(Me, StateMachine).
```

Each state machine must only implement ```apply/1``` as shown [here](https://github.com/andrewjstone/rafter/blob/master/src/rafter_sm_echo.erl) . When snapshotting is implemented, other callbacks may be required.

### Show the current state of the consensus fsm

    %% peer1 is the name of a peer consensus fsm
    sys:get_status(peer1).  

### Show the current state of the log for a peer
    
    sys:get_status(peer1_log).

### compiling code

    make

### running tests

    make test

### TODO

 * Persistent log
    * write to file
    * compaction
      * start with snapshotting assuming data is ```small``` as described in section 2 [here](https://ramcloud.stanford.edu/wiki/download/attachments/12386595/compaction.pdf?version=1&modificationDate=1367123151531)
 * Client interface
   * Sequence number for idempotent requests for state machine backends
   * Redis like text-based interface?
   * HTTP ?
 * more statemachine tests with eqc
 * Anti-Entropy - 
   * Write AAE info into snapshot file during snapshotting

### License

Apache 2.0
http://www.apache.org/licenses/LICENSE-2.0.html
