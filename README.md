Rafter is an erlang implementation of the [raft consensus protocol](https://ramcloud.stanford.edu/wiki/download/attachments/11370504/raft.pdf) .


### starting a node from the repl

    application:start(rafter),
    Me = peer1,
    Peers = [peer2, peer3, peer4, peer5],
    rafter_sup:start_peer(Me, Peers).

### starting a cluster of 5 nodes on a single vm for testing
The peers are all simple erlang processes. The consensus fsm's are named peer1..peer5.
The corresponding log gen_servers are named peer1_log..peer5_log. Other processes are named in a similar fashion.
    
    rafter_sup:start_cluster().

### Show the current state of the consensus fsm

    %% peer1 is the name of a peer consensus fsm
    sys:get_status(peer1).  

### Show the current state of the log for a peer
    
    sys:get_status(peer1_log).

### compiling code

    ./rebar compile

### running tests

    ./rebar eunit skip_deps=true
