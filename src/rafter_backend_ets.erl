-module(rafter_backend_ets).

-behaviour(rafter_backend).

%% rafter_backend callbacks
-export([init/1, stop/1, read/2, write/2]).

-record(state, {peer :: atom() | {atom(), atom()}}).

init(Peer) ->
    State = #state{peer=Peer},
    NewState = stop(State),
    _Tid1 = ets:new(rafter_backend_ets, [set, named_table, public]),
    _Tid2 = ets:new(rafter_backend_ets_tables, [set, named_table, public]),
    NewState.

stop(State) ->
    catch ets:delete(rafter_backend_ets),
    catch ets:delete(rafter_backend_ets_tables),
    State.

read({get, Table, Key}, State) ->
    Val = try
              case ets:lookup(Table, Key) of
                  [{Key, Value}] ->
                      {ok, Value};
                  [] ->
                      {ok, not_found}
              end
          catch _:E ->
              {error, E}
          end,
     {Val, State};
read(list_tables, State) ->
    {{ok, [Table || {Table} <- ets:tab2list(rafter_backend_ets_tables)]},
        State};
read({list_keys, Table}, State) ->
    Val = try
              list_keys(Table)
          catch _:E ->
              {error, E}
          end,
    {Val, State};
read(_, State) ->
    {{error, ets_read_badarg}, State}.

write({new, Name}, State) ->
    Val = try
              _Tid = ets:new((Name), [ordered_set, named_table, public]),
              ets:insert(rafter_backend_ets_tables, {Name}),
              {ok, Name}
          catch _:E ->
              {error, E}
          end,
    {Val, State};
write({put, Table, Key, Value}, State) ->
    Val = try
              ets:insert(Table, {Key, Value}),
              {ok, Value}
          catch _:E ->
              {error, E}
          end,
    {Val, State};
write({delete, Table}, State) ->
    Val =
        try
            ets:delete(Table),
            ets:delete(rafter_backend_ets_tables, Table),
            {ok, true}
        catch _:E ->
            {error, E}
        end,
    {Val, State};
write({delete, Table, Key}, State) ->
    Val = try
              {ok, ets:delete(Table, Key)}
          catch _:E ->
              {error, E}
          end,
    {Val, State};
write(_, State) ->
    {{error, ets_write_badarg}, State}.

list_keys(Table) ->
    list_keys(ets:first(Table), Table, []).

list_keys('$end_of_table', _Table, Keys) ->
    {ok, Keys};
list_keys(Key, Table, Keys) ->
    list_keys(ets:next(Table, Key), Table, [Key | Keys]).
