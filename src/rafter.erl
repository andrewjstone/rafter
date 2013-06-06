-module(rafter).

-include("rafter.hrl").

%% API
-export([append/2, start_node/2]).

%% Test API
-export([start_cluster/0, start_test_node/1]).

%% @doc Only use this during testing
start_cluster() ->
    application:start(lager),
    application:start(rafter),
    rafter_sup:start_cluster().

start_test_node(Name) ->
    application:start(lager),
    application:start(rafter),
    Me = {Name, node()},
    Peers = test_peers(Me),
    start_node(Me, Peers).

start_node(Me, Peers) ->
    rafter_sup:start_peer(Me, Peers).

append(_LocalPeer, _Command) ->
    ok.

test_peers(Me) ->
    [_Name, Domain] = string:tokens(atom_to_list(node()), "@"),
    Peers = [{list_to_atom(Name), list_to_atom(Name ++ "@" ++ Domain)} || 
        Name <- ["peer1", "peer2", "peer3", "peer4", "peer5"]],
    lists:delete(Me, Peers).
