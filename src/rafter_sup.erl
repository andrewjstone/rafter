-module(rafter_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_peer/2, start_peer/1, start_cluster/0, stop_peer/1]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a peer for testing. This is really only meant to be used from the
%%      repl/tests for testing the peer1..peer5 cluster.
start_peer(Peer) ->
    Peers = lists:delete(Peer, [peer1, peer2, peer3, peer4, peer5]),
    start_peer(Peer, Peers).

%% @doc Start an individual peer. In production, this will only be called once 
%% on each machine with node/local name semantics. 
%% For testing, this allows us to start 5 nodes in one erlang VM and 
%% communicate with local names.
start_peer(Me, Peers) ->
    SupName = consensus_sup(Me),
    ConsensusSup= {SupName,
                {rafter_consensus_sup, start_link, [Me, Peers]},
                permanent, 5000, supervisor, [rafter_consensus_sup]},
    supervisor:start_child(?MODULE, ConsensusSup).

stop_peer(Peer) ->
    ChildId = consensus_sup(Peer),
    supervisor:terminate_child(?MODULE, ChildId),
    %% A big meh to OTP supervisor child handling. Just delete so start works
    %% again.
    supervisor:delete_child(?MODULE, ChildId).

%% @doc Start a local cluster of peers with names peer[1-5] 
start_cluster() ->
    Peers = [peer1, peer2, peer3, peer4, peer5],
    [start_peer(Me, lists:delete(Me, Peers)) || Me <- Peers].

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, { {one_for_one, 5, 10}, []} }.

%% ===================================================================
%% Private Functions 
%% ===================================================================
consensus_sup(Peer) ->
    list_to_atom(atom_to_list(Peer) ++ "_consensus_sup").
