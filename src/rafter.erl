-module(rafter).

-include("rafter.hrl").

%% API
-export([start_node/2, op/2, set_config/2]).

%% Test API
-export([start_cluster/0, start_test_node/1, test_peers/1]).

start_node(Me, StateMachineModule) ->
    rafter_sup:start_peer(Me, StateMachineModule).

%% @doc Run an operation on the backend state machine. 
%% Note: Peer is just the local node in production.
op(Peer, Command) ->
    Id = druuid:v4(),
    rafter_consensus_fsm:op(Peer, {Id, Command}).

set_config(Peer, NewServers) ->
    Id = druuid:v4(),
    rafter_consensus_fsm:set_config(Peer, {Id, NewServers}).

%% =============================================
%% Test Functions
%% =============================================

start_cluster() ->
    application:start(lager),
    application:start(rafter),
    start_cluster(rafter_sm_echo).

start_cluster(StateMachine) ->
    Peers = [peer1, peer2, peer3, peer4, peer5],
    [rafter_sup:start_peer(Me, StateMachine) || Me <- Peers].

start_test_node(Name) ->
    application:start(lager),
    application:start(rafter),
    Me = {Name, node()},
    start_node(Me, rafter_sm_echo).

test_peers(Me) ->
    [_Name, Domain] = string:tokens(atom_to_list(node()), "@"),
    Peers = [{list_to_atom(Name), list_to_atom(Name ++ "@" ++ Domain)} || 
        Name <- ["peer1", "peer2", "peer3", "peer4", "peer5"]],
    lists:delete(Me, Peers).
