Rafter is an erlang implementation of the [raft consensus protocol](https://ramcloud.stanford.edu/wiki/download/attachments/11370504/raft.pdf) .


### starting a node from the repl

    application:start(rafter),
    Me = peer1,
    Peers = [peer2, peer3, peer4, peer5],
    rafter_sup:start_peer(Me, Peers).

### Show the current state of the consensus fsm

    %% peer1 is the name of the consensus fsm
    sys:get_status(peer1).  

### Show the current state of the log for a peer
    
    sys:get_status(peer1_log).

### compiling code

    ./rebar compile

### running tests

    ./rebar eunit
