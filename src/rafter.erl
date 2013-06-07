-module(rafter).

-include("rafter.hrl").

%% API
-export([start_node/3, op/2]).

%% Test API
-export([start_cluster/0, start_node/2, start_test_node/1]).

start_node(Me, Peers, StateMachineModule) ->
    rafter_sup:start_peer(Me, Peers, StateMachineModule).

%% @doc Run an operation on the backend statemachine. 
%%      Allow skipping persistent logging and replication when that state machine
%%      only requires the operation to run on the leader. This is useful when
%%      the backend statemachine is non-deterministic(i.e. it may return an error).
%%      An example of non-determinism is writing to a database or file system.
%%      because disks and networks can fail.
%%
%% Note: Peer is just the local node in production. The request will 
%% automatically be routed to the leader.
op(Peer, Command) ->
    rafter_consensus_fsm:op(Peer, Command).

%% =============================================
%% Test Functions
%% =============================================

start_node(Me, Peers) ->
    start_node(Me, Peers, rafter_sm_echo).

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

test_peers(Me) ->
    [_Name, Domain] = string:tokens(atom_to_list(node()), "@"),
    Peers = [{list_to_atom(Name), list_to_atom(Name ++ "@" ++ Domain)} || 
        Name <- ["peer1", "peer2", "peer3", "peer4", "peer5"]],
    lists:delete(Me, Peers).
