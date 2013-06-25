-module(rafter_consensus_sup).

-behaviour(supervisor).

%% API
-export([start_link/2]).

%% Supervisor callbacks
-export([init/1]).

-spec start_link(atom() | {atom(), atom()}, atom()) -> ok.
start_link(Me, StateMachine) when is_atom(Me) ->
    SupName = name(Me, "sup"),
    start_link(Me, SupName, Me, StateMachine);
start_link(Me, StateMachine) ->
    {Name, _Node} = Me,
    SupName = name(Name, "sup"),
    start_link(Name, SupName, Me, StateMachine).

init([NameAtom, Me, StateMachine]) ->
    LogName = name(NameAtom, "log"),
    LogServer = { rafter_log,
                 {rafter_log, start_link, [LogName]},
                 permanent, 5000, worker, [rafter_log]},

    ConsensusFsm = { rafter_consensus_fsm,
                    {rafter_consensus_fsm, start_link, [NameAtom, Me, StateMachine]},
                    permanent, 5000, worker, [rafter_consensus_fsm]},

    {ok, {{one_for_all, 5, 10}, [LogServer, ConsensusFsm]}}.

%% ===================================================================
%% Private Functions 
%% ===================================================================
name(Name, Extension) ->
    list_to_atom(atom_to_list(Name) ++ "_" ++ Extension).

start_link(NameAtom, SupName, Me, StateMachine) ->
    supervisor:start_link({local, SupName}, ?MODULE, [NameAtom, Me, StateMachine]).
