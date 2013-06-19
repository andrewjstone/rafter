-module(rafter).

-include("rafter.hrl").

%% API
-export([start_node/3, op/2]).

%% Test API
-export([start_cluster/0, start_node/2, start_test_node/1]).

start_node(Me, Peers, StateMachineModule) ->
    rafter_sup:start_peer(Me, Peers, StateMachineModule).

%% @doc Run an operation on the backend state machine. 
%% Note: Peer is just the local node in production. The request will 
%% automatically be routed to the leader.
op(Peer, Command) ->
    rafter_consensus_fsm:op(Peer, Command).

set_config(Config) ->
    rafter_config:

%% =============================================
%% Test Functions
%% =============================================

start_node(Me, Peers) ->
    start_node(Me, Peers, rafter_sm_echo).

start_cluster() ->
    application:start(lager),
    application:start(rafter),
    start_cluster(rafter_sm_echo).

start_cluster(StateMachine) ->
    rafter_sup:start_cluster(StateMachine).

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
