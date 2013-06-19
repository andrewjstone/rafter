-module(rafter_consensus_sup).

-behaviour(supervisor).

%% API
-export([start_link/3]).

%% Supervisor callbacks
-export([init/1]).

-spec start_link(atom() | {atom(), atom()}, [atom()] | [{atom(), atom()}], atom()) -> ok.
start_link(Me, Peers, StateMachine) when is_atom(Me) ->
    SupName = name(Me, "sup"),
    start_link(Me, SupName, Me, Peers, StateMachine);
start_link(Me, Peers, StateMachine) ->
    {Name, _Node} = Me,
    SupName = name(Name, "sup"),
    start_link(Name, SupName, Me, Peers, StateMachine).

init([NameAtom, Me, Peers, StateMachine]) ->
    LogName = name(NameAtom, "log"),
    LogServer = { rafter_log,
                 {rafter_log, start_link, [LogName]},
                 permanent, 5000, worker, [rafter_log]},

    ConfigName = name(NameAtom, "conf"),
    ConfigServer = { rafter_config,
                     {rafter_Config, start_link, [ConfigName]},
                     permanent, 5000, worker, [rafter_config]},

    ConsensusFsm = { rafter_consensus_fsm,
                    {rafter_consensus_fsm, start_link, [NameAtom, Me, Peers, StateMachine]},
                    permanent, 5000, worker, [rafter_consensus_fsm]},

    {ok, {{one_for_all, 5, 10}, [LogServer, ConfigServer, ConsensusFsm]}}.

%% ===================================================================
%% Private Functions 
%% ===================================================================
name(Name, Extension) ->
    list_to_atom(atom_to_list(Name) ++ "_" ++ Extension).

start_link(NameAtom, SupName, Me, Peers, StateMachine) ->
    supervisor:start_link({local, SupName}, ?MODULE, [NameAtom, Me, Peers, StateMachine]).
