-module(rafter_leader_election_eqc).

-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").

-include("rafter.hrl").

-compile(export_all).

%%-include_lib("eqc/include/eqc_statem.hrl").
%%-behaviour(eqc_statem).
%%-record(state, {peers = [] :: proplist()}).

%% ====================================================================
%% Tests
%% ====================================================================

eqc_test_() ->
    {spawn,
     [
      {setup,
       fun setup/0,
       fun cleanup/1,
       [%% Run the quickcheck tests
        {timeout, 30,
         ?_assertEqual(true, 
             eqc:quickcheck(
                 eqc:conjunction([{prop_leader_elected, 
                                   eqc:numtests(100, prop_leader_elected())}])))}
       ]
      }
     ]
    }.

setup() ->
    ok.

cleanup(_) ->
    ok.

%% ====================================================================
%% EQC Properties
%% ====================================================================

prop_leader_elected() ->
    application:start(rafter),
    rafter_sup:start_cluster(),
    %% leader election should occur in less than 1 second with the defaults. 
    %% This is a liveness constraint I'd like to maintain if possible.
    timer:sleep(1000),
    Status = get_status_from_peers(), 
    Rv = assert_exactly_one_leader(Status),
    application:stop(rafter),
    Rv.

assert_exactly_one_leader(Status) ->
    Leaders = lists:filter(fun(PeerStatus) ->
                              {status, _, _, [_, _, _, _, List]} = PeerStatus,
                              {data, Proplist} = lists:nth(2, List),
                              leader =:= proplists:get_value("StateName", Proplist)
                           end, Status),
    1 =:= length(Leaders).
                    

get_status_from_peers() ->
    [sys:get_status(Peer) || Peer <- [peer1, peer2, peer3, peer4, peer5]].

-endif.
