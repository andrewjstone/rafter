
-module(rafter_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    ConsensusFsm = { rafter_consensus_fsm,
                {rafter_consensus_fsm, start_link, []},
                permanent, 5000, worker, [rafter_consensus_fsm]},
    LogServer = { rafter_log,
                {rafter_log, start_link, []},
                permanent, 5000, worker, [rafter_log]},
    {ok, { {one_for_one, 5, 10}, [ConsensusFsm, LogServer]} }.

