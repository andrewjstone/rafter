-module(rafter_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_peer/2, stop_peer/1]).

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
-spec start_peer(atom() | {atom(), atom()}, atom()) -> ok.
start_peer(Me, StateMachineModule) when is_atom(Me) ->
    SupName = consensus_sup(Me),
    start_child(SupName, Me, StateMachineModule);
start_peer(Me, StateMachineModule) ->
    {Name, _Node} = Me,
    SupName = consensus_sup(Name),
    start_child(SupName, Me, StateMachineModule).

-spec stop_peer(atom() | tuple()) -> ok.
stop_peer(Peer) when is_atom(Peer) ->
    ChildId = consensus_sup(Peer),
    stop_child(ChildId);
stop_peer(Peer) ->
    {Name, _Node} = Peer,
    SupName = consensus_sup(Name),
    stop_child(SupName).

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

start_child(SupName, Me, StateMachineModule) ->
    ConsensusSup= {SupName,
        {rafter_consensus_sup, start_link, [Me, StateMachineModule]},
        permanent, 5000, supervisor, [rafter_consensus_sup]},
    supervisor:start_child(?MODULE, ConsensusSup).

stop_child(ChildId) ->
    supervisor:terminate_child(?MODULE, ChildId),
    %% A big meh to OTP supervisor child handling. Just delete so start works
    %% again.
    supervisor:delete_child(?MODULE, ChildId).
