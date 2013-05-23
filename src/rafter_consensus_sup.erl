-module(rafter_consensus_sup).

-behaviour(supervisor).

%% API
-export([start_link/2]).

%% Supervisor callbacks
-export([init/1]).

start_link(Me, Peers) ->
    SupName = list_to_atom(atom_to_list(Me) ++ "_sup"),
    supervisor:start_link({local, SupName}, ?MODULE, [Me, Peers]).

init([Me, Peers]) ->
    ConsensusFsm = { rafter_consensus_fsm,
                    {rafter_consensus_fsm, start_link, [Me, Peers]},
                    permanent, 5000, worker, [rafter_consensus_fsm]},

    LogName = list_to_atom(atom_to_list(Me) ++ "_log"),
    LogServer = { rafter_log,
                 {rafter_log, start_link, [LogName]},
                 permanent, 5000, worker, [rafter_log]},

    {ok, { {one_for_all, 5, 10}, [LogServer, ConsensusFsm]} }.
