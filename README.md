# UNDER CONSTRUCTION

***Note that Rafter is in the process of being built and some of the things described below may not yet be implemented.***

### Introduction
Rafter is more than just an erlang implementation of the [raft consensus protocol](https://ramcloud.stanford.edu/wiki/download/attachments/11370504/raft.pdf). It aims to take the pain away from building Consistent(2F+1 CP) distributed systems, as well as act as a library for leader election and routing. A main goal is to keep a very small user api that automatically handles the problems of the everyday Erlang distributed systems developer. It is hopefully your ***libPaxos.dll*** for erlang.

Rafter is meant to be used as a library application on an already created distibuted erlang cluster of 3 or 5 nodes. rafter peers are uniquely identified by ```{Name, Node}``` tuples which get passed in as static configuration. 

### Use cases
Rafter has two primary use cases that can be provided by the raft consensus protocol:
  
 1. Distributed Consensus with a replicated log 
 2. Leader election and operation serialization at the leader only.

TLDR; If your statemachine is deterministic use a replicated log. If your statemachine is non-deterministic use leader-only mode.

#### Distributed consensus with a replicated log
For use cases such as implementing distributed databases, a replicated log can be used internally to provide strong consistency. Operations are serialized and written to log files in the same order on each node. Once the operation is committed by a node it is applied to the state machine backend. In the case of a distributed database, the operation would probably be to create or update an item in the database. The leader will not return success to the client until the operation is safely replicated. It is clear that applying these types of deterministic operations in the same order will produce the same output each time, and hence if one machine crashes, others can still be accessed without any data loss. These serialized operations can continue as long as a majority of the nodes can communicate. If the majority of nodes cannot agree then the system rejects requests for both reads and writes. In mathematical terms, a cluster of 2f+1 nodes can handle f failures. The most common cluster sizes are 3 nodes, which can handle 1 failure and still work, and 5 which can handle two failures.

It is important to note, that because operations are logged ***before*** they are executed by the state machine, they cannot be allowed to fail arbitrarily, or exhibit other non-deterministic behavior when executed by the state machine. If this were allowed, there would be no way to guarantee that each replica had the same state after the state machine transformation, nor could you tell which replica had the ***correct*** data! In other words, state machine operations should be pure functions and the state machine must be deterministic. Each replay of the in-order operations on each node must result in the exact same output state or else you cannot use the safety properties given to you by replicated logs. Note lastly, that operations that base their output state on the current time of day are inherently non-deterministic in distributed systems and should not be allowed in the state machines.

An additional benefit of having a deterministic state machine is that it allows snapshotting of the current state to disk and truncating the already applied operations in the log after the state machine output is successfully snapshotted. This is known as ***compaction*** and provides output durability for the state machine itself which allows faster restarts on failed nodes, since the entire log no longer needs to be replayed. You can read more about compaction [here](https://ramcloud.stanford.edu/wiki/download/attachments/12386595/compaction.pdf?version=1&modificationDate=1367123151531).

Rafter will allow you to use the replicated log functionality and provide 2f+1 consistency guarantees iff the state machine module tells rafter explicitly that it is deterministic by returning ```true``` from ```Mod:is_deterministic()```. While this is certainly not foolproof, it at least forces one to read the documentation to know to set the flag. It is hoped that distributed systems engineers implementing systems based on log replication understand what they are doing. Forcing an explicit guarantee from the state machine author that the state machine is deterministic is the equivalent of signing on the dotted line saying that you take responsibility for the consistency and safety of your data.

#### Leader-only state machines
In many instances, an application needs to perform a non-deterministic operation such as writing to an external data store or moving a robotic arm. In many of these cases the operations being performed must be run in order and exactly once. Additionally, some applications need to ensure that only one user can acquire a resource because that resource is globally unique(i.e. Amazon S3 buckets).

In many systems this type of behavior is achieved by having a single process that gets sent requests and issues commands one at a time. However, this presents a single point of failure which is a non-starter for a system that must be consistent and as available as possible given the laws of our universe where partitions are possible and the speed of light exists. In order to get around this you need to have a group of peers that elect a leader to perform the operations. If that leader fails, another one will be elected and it will continue to process requests in order. The system must also ensure that only one leader is making requests at a time and any new leader knows the last request made, so that it doesn't apply the same operation twice. Since we only have to keep track of the ***last operation*** we don't have to keep a full log of every operation. Repeating them doesn't help anyway since they are non-deterministic and have side effects.

If your statemachine has non-deterministic operations it should return ```false``` from ```Mod:is_deterministic()```. In this case each operation will be run through the state machine exactly once on the ***leader only***. A majority of nodes still needs to be up to record the last operation run so that it is not processed twice. Note that the leader may die after the peers record the last operation, but before the state machine processed the command. In this case the client will get a timeout error, which implies he's not sure whether the command succeeded or failed. This command will ***NOT*** be re-issued and a newly elected leader will continue with the next client request.

### starting a cluster of 5 nodes on a single vm for testing. Start all dependencies.
The peers are all simple erlang processes. The consensus fsm's are named peer1..peer5.
The corresponding log gen_servers are named peer1_log..peer5_log. Other processes are named in a similar fashion.

    rafter:start_cluster().
    
### Show the current state of the consensus fsm

    %% peer1 is the name of a peer consensus fsm
    sys:get_status(peer1).  

### Show the current state of the log for a peer
    
    sys:get_status(peer1_log).

### Append a command to the log. This will be wrapped in a client library soon.

   ```erlang
   %% Each client message should be unique
   MsgId = 1,
   Command = do_something,
   rafter_consensus_fsm:append(peer3, {MsgId, Command}).
   ```

### compiling code

    ./rebar compile

### running tests

    ./rebar eunit skip_deps=true

### TODO

 * Handle non-deterministic state machines
 * Handle deterministic state machines
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
