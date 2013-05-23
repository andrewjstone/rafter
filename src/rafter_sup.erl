-module(rafter_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_peer/2]).

%% Supervisor callbacks
-export([init/1]).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Start an individual peer. In production, this will only be called once 
%% on each machine with node/local name semantics. 
%% For testing, this allows us to start 5 nodes in one erlang VM and 
%% communicate with local names.
start_peer(Me, Peers) ->
    ConsensusSup= {rafter_consensus_sup,
                {rafter_consensus_sup, start_link, [Me, Peers]},
                permanent, 5000, supervisor, [rafter_consensus_sup]},
    supervisor:start_child(?MODULE, ConsensusSup).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, { {one_for_one, 5, 10}, []} }.

