-module(rafter).

-include("rafter.hrl").

%% API
-export([append/2, start_node/2]).

%% Test API
-export([start_cluster/0, start_test_node/0]).

%% @doc Only use this during testing
start_cluster() ->
    application:start(lager),
    application:start(rafter),
    rafter_sup:start_cluster().

start_test_node() ->
    application:start(lager),
    application:start(rafter),
    Me = {peer1, node()},
    Peers = test_peers(Me),
    start_node(Me, Peers).

start_node(Me, Peers) ->
    rafter_sup:start_peer(Me, Peers).

append(_LocalPeer, _Command) ->
    ok.

test_peers(Me) ->
    Peers = [{Name, node()} || Name <- [peer1, peer2, peer3, peer4, peer5]],
    lists:delete(Me, Peers).
