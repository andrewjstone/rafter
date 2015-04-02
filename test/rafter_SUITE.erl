-module(rafter_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("rafter/include/rafter_opts.hrl").
-include_lib("rafter/include/rafter.hrl").

-export([all/0, suite/0, init_per_suite/1, end_per_suite/1]).
-export([t_overwrite_bug/1]).

suite() ->
    [{timetrap,{seconds,30}}].

all() ->
    [
     t_overwrite_bug
    ].

init_per_suite(Config) ->
    {ok, Dir} = file:get_cwd(),
    filelib:ensure_dir(filename:join([Dir, "logs", "file"])),
    Config.

end_per_suite(_Config) ->
    ok.

t_overwrite_bug(_Config) ->
    Peer = 'dev1@127.0.0.1dev2@127.0.0.1dev4@127.0.0.1',
    Opts = #rafter_opts{state_machine=rafter_backend_ets,
                        logdir="./logs"},
    {ok, _Pid} = rafter_log:start_link(Peer, Opts),

    #config{state=blank} = rafter_log:get_config(Peer),
    {ok, not_found}      = rafter_log:get_last_entry(Peer),
    0                    = rafter_log:get_last_index(Peer),

    Config = #config{state=stable,
                     oldservers=[{'dev1@127.0.0.1dev2@127.0.0.1dev4@127.0.0.1',
                                  'dev1@127.0.0.1'},
                                 {'dev1@127.0.0.1dev2@127.0.0.1dev4@127.0.0.1',
                                  'dev2@127.0.0.1'},
                                 {'dev1@127.0.0.1dev2@127.0.0.1dev4@127.0.0.1',
                                  'dev4@127.0.0.1'}]},

    Entry0 = #rafter_entry{type=config,term=1,index=undefined,cmd=Config},
    {ok, 1} = rafter_log:append(Peer, [Entry0]),

    Entry1 = Entry0#rafter_entry{index=1},
    {ok, Entry1} = rafter_log:get_entry(Peer, 1),

    % same index, different term
    Entry2 = Entry1#rafter_entry{term=2},
    {ok, 1} = rafter_log:check_and_append(Peer, [Entry2], 1),
    Config = rafter_log:get_config(Peer),
    {ok, Entry2} = rafter_log:get_entry(Peer, 1),

    ok.
