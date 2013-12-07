-module(rafter_consensus_sup).

-behaviour(supervisor).

%% API
-export([start_link/2]).

%% Supervisor callbacks
-export([init/1]).

start_link(Me, Opts) when is_atom(Me) ->
    SupName = name(Me, "sup"),
    start_link(Me, SupName, Me, Opts);
start_link(Me, Opts) ->
    {Name, _Node} = Me,
    SupName = name(Name, "sup"),
    start_link(Name, SupName, Me, Opts).

init([NameAtom, Me, Opts]) ->
    LogServer = { rafter_log,
                 {rafter_log, start_link, [NameAtom, Opts]},
                 permanent, 5000, worker, [rafter_log]},

    ConsensusFsm = { rafter_consensus_fsm,
                    {rafter_consensus_fsm, start_link, [NameAtom, Me, Opts]},
                    permanent, 5000, worker, [rafter_consensus_fsm]},

    {ok, {{one_for_all, 5, 10}, [LogServer, ConsensusFsm]}}.

%% ===================================================================
%% Private Functions
%% ===================================================================
name(Name, Extension) ->
    list_to_atom(atom_to_list(Name) ++ "_" ++ Extension).

start_link(NameAtom, SupName, Me, Opts) ->
    supervisor:start_link({local, SupName}, ?MODULE, [NameAtom, Me, Opts]).
