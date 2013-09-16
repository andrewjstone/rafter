-module(rafter_backend_ets_eqc).

-ifdef(EQC).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_statem.hrl").
-include_lib("eunit/include/eunit.hrl").

-behaviour(eqc_statem).

%% eqc_statem exports
-export([command/1, initial_state/0, next_state/3, postcondition/3,
         precondition/2, invariant/1]).

%% functions used in property callbacks
-export([put_data/5, del_data/4]).

-record(state, {
    init=false,
    backend_state :: term(),
    tables=sets:new() :: sets:set(atom()),
    data=[] :: [{{Table :: atom(), Key :: binary()}, Value :: term()}]}).

-define(QC_OUT(P),
    eqc:on_output(fun(Str, Args) ->
                io:format(user, Str, Args) end, P)).

eqc_test_() ->
    {spawn,
       [%% Run the quickcheck tests
        {timeout, 120,
         ?_assertEqual(true,
             eqc:quickcheck(
                 ?QC_OUT(eqc:numtests(50, prop_backend()))))}
       ]
    }.

prop_backend() ->
    ?FORALL(Cmds,
            more_commands(20, commands(?MODULE)),
            aggregate(command_names(Cmds),
                begin
                    {H, S, Res} = run_commands(?MODULE, Cmds),
                    eqc_statem:pretty_commands(?MODULE,
                                               Cmds,
                                               {H, S, Res},
                                               cleanup(S, Res))
                end)).

cleanup(#state{backend_state=BS}=State, Res) ->
    rafter_backend_ets:stop(BS),
    [ets:delete(Table) || Table <- sets:to_list(State#state.tables)],
    Res =:= ok.

%% ====================================================================
%% eqc_statem callbacks
%% ====================================================================
initial_state() ->
    #state{}.

command(#state{init=false}) ->
    {call, rafter_backend_ets, init, [peer1]};

command(#state{backend_state=BS}) ->
    frequency([
        {10, {call, rafter_backend_ets, write, [{new, table_gen()}, BS]}},
        {3, {call, rafter_backend_ets, write, [{delete, table_gen()}, BS]}},
        {100, {call, rafter_backend_ets, write,
                [{delete, table_gen(), key_gen()}, BS]}},
        {200, {call, rafter_backend_ets, read,
                [{get, table_gen(), key_gen()}, BS]}},
        {200, {call, rafter_backend_ets, write,
                [{put, table_gen(), key_gen(), value_gen()}, BS]}},
        {20, {call, rafter_backend_ets, read, [list_tables, BS]}},
        {20, {call, rafter_backend_ets, read,
                [{list_keys, table_gen()}, BS]}}]).

precondition(#state{}, _) ->
    true.

next_state(#state{init=false}=S, Result,
    {call, rafter_backend_ets, init, [peer1]}) ->
        S#state{init=true, backend_state=Result};

next_state(#state{tables=Tables}=S, _Result,
    {call, rafter_backend_ets, write, [{new, Table}, _]}) ->
        S#state{tables={call, sets, add_element, [Table, Tables]}};

next_state(#state{data=Data, tables=Tables}=S, _Result,
    {call, rafter_backend_ets, write, [{put, Table, Key, Value}, _]}) ->
        S#state{data={call, ?MODULE, put_data, [Table, Key, Value, Data, Tables]}};

next_state(#state{tables=Tables}=S, _,
    {call, rafter_backend_ets, write, [{delete, Table}, _]}) ->
        S#state{tables={call, sets, del_element, [Table, Tables]}};

next_state(#state{data=Data, tables=Tables}=S, _,
    {call, rafter_backend_ets, write, [{delete, Table, Key}, _]}) ->
        S#state{data={call, ?MODULE, del_data, [Table, Key, Data, Tables]}};

%% Read operations don't modify state
next_state(State, _, {call, rafter_backend_ets, read, _}) ->
    State.

postcondition(#state{init=false}, {call, rafter_backend_ets, init, _}, _) ->
    true;
postcondition(#state{},
    {call, rafter_backend_ets, write, [{new, Table}, _]},
    {{ok, Table}, _}) ->
        true;
postcondition(#state{tables=Tables},
    {call, rafter_backend_ets, write, [{new, Table}, _]},
    {{error, badarg}, _}) ->
        sets:is_element(Table, Tables);

postcondition(#state{data=Data, tables=Tables},
    {call, rafter_backend_ets, read, [{get, Table, Key}, _]}, {{ok, not_found}, _}) ->
        sets:is_element(Table, Tables) andalso
        lists:keyfind({Table, Key}, 1, Data)  =:= false;
postcondition(#state{data=Data, tables=Tables},
    {call, rafter_backend_ets, read, [{get, Table, Key}, _]}, {{ok, Result}, _}) ->
        sets:is_element(Table, Tables) andalso
        lists:keyfind({Table, Key}, 1, Data)  =:= Result;
postcondition(#state{data=Data, tables=Tables},
    {call, rafter_backend_ets, read, [{get, Table, Key}, _]}, {{error, _}, _}) ->
        not sets:is_element(Table, Tables) andalso
        lists:keyfind({Table, Key}, 1, Data)  =:= false;

postcondition(#state{tables=Tables},
    {call, rafter_backend_ets, read, [list_tables, _]}, {{ok, Keys}, _}) ->
        length(Keys) =:= sets:size(Tables) andalso
        lists:all(fun(Table) ->
                      sets:is_element(Table, Tables)
                  end, Keys);

postcondition(#state{tables=Tables, data=Data},
    {call, rafter_backend_ets, read, [{list_keys, Table}, _]}, {{ok, Keys}, _}) ->
        sets:is_element(Table, Tables) andalso
        lists:all(fun(Key) ->
                      lists:keyfind({Table, Key}, 1, Data) =/= false
                  end, Keys);
postcondition(#state{tables=Tables},
    {call, rafter_backend_ets, read, [{list_keys, Table}, _]}, {{error, badarg}, _}) ->
        not sets:is_element(Table, Tables);

postcondition(#state{tables=Tables},
    {call, rafter_backend_ets, write, [{put, Table, _Key, Value}, _]},
    {{ok, Value}, _}) ->
        sets:is_element(Table, Tables);
postcondition(#state{tables=Tables},
    {call, rafter_backend_ets, write, [{put, Table, _Key, _Value}, _]},
    {{error, badarg}, _}) ->
        not sets:is_element(Table, Tables);

postcondition(#state{tables=Tables},
    {call, rafter_backend_ets, write, [{delete, Table}], _}, {{ok, Table}, _}) ->
        sets:is_element(Table, Tables);
postcondition(#state{tables=Tables},
    {call, rafter_backend_ets, write, [{delete, Table}, _]}, {{error, badarg}, _}) ->
        not sets:is_element(Table, Tables);

postcondition(#state{tables=Tables},
    {call, rafter_backend_ets, write, [{delete, Table, _Key}, _]}, {{ok, true}, _}) ->
        sets:is_element(Table, Tables);

postcondition(#state{tables=Tables},
    {call, rafter_backend_ets, write, [{delete, Table, _Key}, _]}, {{error, badarg}, _}) ->
        not sets:is_element(Table, Tables).

invariant(#state{init=false}) ->
    true;
invariant(State) ->
    tables_are_listed_in_ets_tables_table(State) andalso
    tables_exist(State) andalso
    data_is_correct(State).

%% ====================================================================
%% Invariants
%% ====================================================================
tables_are_listed_in_ets_tables_table(#state{tables=Tables}) ->
    ListedTables = sets:from_list([T || {T} <- ets:tab2list(rafter_backend_ets_tables)]),
    UnionSize = sets:size(sets:union(Tables, ListedTables)),
    UnionSize =:= sets:size(ListedTables) andalso UnionSize =:= sets:size(Tables).

tables_exist(#state{tables=Tables}) ->
    EtsTables = sets:from_list(ets:all()),
    sets:is_subset(Tables, EtsTables).

data_is_correct(#state{data=Data}) ->
    lists:all(fun({{Table, Key}, Value}) ->
                [{Key, Value}] =:= ets:lookup(Table, Key)
              end, Data).

%% ====================================================================
%% Internal Functions
%% ====================================================================
put_data(Table, Key, Value, Data, Tables) ->
    case sets:is_element(Table, Tables) of
        true ->
            lists:keystore({Table, Key}, 1, Data, {{Table, Key}, Value});
        false ->
            Data
    end.

del_data(Table, Key, Data, Tables) ->
    case sets:is_element(Table, Tables) of
        true ->
            lists:keydelete({Table, Key}, 1, Data);
        false ->
            Data
    end.

%% ====================================================================
%% EQC Generators
%% ====================================================================

table_gen() ->
    oneof([list_to_atom("table_"++integer_to_list(L)) || L <- lists:seq(0, 100)]).

key_gen() ->
    binary().

value_gen() ->
    int().

-endif.
