-module(rafter_consensus_sup).

-behaviour(supervisor).

%% API
-export([start_link/3]).

%% Supervisor callbacks
-export([init/1]).

-spec start_link(atom() | {atom(), atom()}, [atom()] | [{atom(), atom()}], atom()) -> ok.
start_link(Me, Peers, StateMachine) when is_atom(Me) ->
    SupName = sup_name(Me),
    start_link(Me, SupName, Me, Peers, StateMachine);
start_link(Me, Peers, StateMachine) ->
    {Name, _Node} = Me,
    SupName = sup_name(Name),
    start_link(Name, SupName, Me, Peers, StateMachine).

init([NameAtom, Me, Peers, StateMachine]) ->
    ConsensusFsm = { rafter_consensus_fsm,
                    {rafter_consensus_fsm, start_link, [NameAtom, Me, Peers, StateMachine]},
                    permanent, 5000, worker, [rafter_consensus_fsm]},

    LogName = list_to_atom(atom_to_list(NameAtom) ++ "_log"),
    LogServer = { rafter_log,
                 {rafter_log, start_link, [LogName]},
                 permanent, 5000, worker, [rafter_log]},

    {ok, { {one_for_all, 5, 10}, [LogServer, ConsensusFsm]} }.

%% ===================================================================
%% Private Functions 
%% ===================================================================
sup_name(Name) ->
    list_to_atom(atom_to_list(Name) ++ "_sup").

start_link(NameAtom, SupName, Me, Peers, StateMachine) ->
    supervisor:start_link({local, SupName}, ?MODULE, [NameAtom, Me, Peers, StateMachine]).
