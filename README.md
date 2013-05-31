Rafter is an erlang implementation of the [raft consensus protocol](https://ramcloud.stanford.edu/wiki/download/attachments/11370504/raft.pdf) .


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

### License

Apache 2.0
http://www.apache.org/licenses/LICENSE-2.0.html
