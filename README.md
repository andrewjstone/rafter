# starting a node from the repl

    application:start(rafter),
    Me = peer1,
    Peers = [peer2, peer3, peer4, peer5],
    rafter_sup:start_peer(Me, Peers).

# compiling code

    ./rebar compile

# running tests

    ./rebar eunit
