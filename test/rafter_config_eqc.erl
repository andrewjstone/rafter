-module(rafter_config_eqc).

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
                 eqc:conjunction([{prop_quorum_min, 
                                   eqc:numtests(1000, prop_quorum_min())}])))}
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

prop_quorum_min() ->
    ?FORALL({Config, Responses}, {config(), responses()},
        begin
            _Min = rafter_config:quorum_min(Config, dict:from_list(Responses)),
            true
        end).


%% ====================================================================
%% EQC Generators
%% ====================================================================

responses() ->
    list(response()).

response() ->
    {server(), rafter_gen:non_neg_integer()}.

server() ->
    oneof([a,b,c,d,e,f,g,h,i,j,k,l,m,n,o]).

servers() ->
    ?SUCHTHAT(Servers, oneof([three_servers(), five_servers(), seven_servers()]),
       begin
            Uniques = sets:to_list(sets:from_list(Servers)),
            length(Uniques) =:= length(Servers)
       end).

three_servers() ->
    vector(3, server()).

five_servers() ->
    vector(5, server()).

seven_servers() ->
    vector(7, server()).

config() ->
    oneof([stable_config(), blank_config(), 
           staging_config(), transitional_config()]).

stable_config() ->
    #config{state=stable, 
            oldservers=servers(),
            newservers=[]}.

blank_config() ->
    #config{state=blank, 
            oldservers=[],
            newservers=[]}.

staging_config() ->
    #config{state=staging,
            oldservers=servers(),
            newservers=servers()}.

transitional_config() ->
    #config{state=transitional,
            oldservers=servers(),
            newservers=servers()}.

-endif.
