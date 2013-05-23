-module(rafter_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_peer/2, start_cluster/0]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start an individual peer. In production, this will only be called once 
%% on each machine with node/local name semantics. 
%% For testing, this allows us to start 5 nodes in one erlang VM and 
%% communicate with local names.
start_peer(Me, Peers) ->
    SupName = list_to_atom(atom_to_list(Me) ++ "_consensus_sup"),
    ConsensusSup= {SupName,
                {rafter_consensus_sup, start_link, [Me, Peers]},
                permanent, 5000, supervisor, [rafter_consensus_sup]},
    supervisor:start_child(?MODULE, ConsensusSup).

%% @doc Start a local cluster of peers with names peer[1-5] 
start_cluster() ->
    Peers = [peer1, peer2, peer3, peer4, peer5],
    [start_peer(Me, lists:delete(Me, Peers)) || Me <- Peers].

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, { {one_for_one, 5, 10}, []} }.

