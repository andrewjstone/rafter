-module(rafter_log).

-behaviour(gen_server).

-include("rafter.hrl").

%% API
-export([start/0, stop/0, start_link/1, append/1, append/2, 
        get_last_entry/0, get_last_entry/1, get_entry/1, get_entry/2,
        get_term/1, get_term/2, get_last_index/0, get_last_index/1, 
        get_last_term/0, get_last_term/1, truncate/1, truncate/2,
        get_voted_for/1, set_voted_for/2, get_current_term/1, set_current_term/2,
        name/1, get_config/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3, format_status/2]).

%% TODO: Make this a persistent log (bitcask?)
-record(state, {
    config :: #config{},
    entries = [] :: [#rafter_entry{}],
    current_term = 0 :: non_neg_integer(),
    voted_for :: term()}).

%%====================================================================
%% API
%%====================================================================
name(Name ++ "_" ++ _) ->
    name(Name);
name(Name) ->
    Name ++ "_log".

start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    gen_server:cast(?MODULE, stop).

start_link(Name) ->
    gen_server:start_link({local, Name}, ?MODULE, [], []).

append(Entries) ->
    gen_server:call(?MODULE, {append, Entries}).

append(Name, Entries) ->
    gen_server:call(Name, {append, Entries}).

get_config(Name) ->
    gen_server:call(Name, get_config).

set_config(Name, NewConfig) ->
    gen_server:call(Name, {set_config, NewConfig}).

get_last_index() ->
    gen_server:call(?MODULE, get_last_index).

get_last_index(Name) ->
    gen_server:call(Name, get_last_index).

get_last_entry() ->
    gen_server:call(?MODULE, get_last_entry).

get_last_entry(Name) ->
    gen_server:call(Name, get_last_entry).

get_last_term() ->
    case get_last_entry() of
        {ok, #rafter_entry{term=Term}} ->
            Term;
        {ok, not_found} ->
            0
    end.

get_last_term(Name) ->
    case get_last_entry(Name) of
        {ok, #rafter_entry{term=Term}} ->
            Term;
        {ok, not_found} ->
            0
    end.

set_voted_for(Name, VotedFor) ->
    gen_server:call(Name, {set_voted_for, VotedFor}).

get_voted_for(Name) ->
    gen_server:call(Name, get_voted_for).

set_current_term(Name, CurrentTerm) ->
    gen_server:call(Name, {set_current_term, CurrentTerm}).

get_current_term(Name) ->
    gen_server:call(Name, get_current_term).

get_entry(Index) ->
    gen_server:call(?MODULE, {get_entry, Index}).

get_entry(Name, Index) ->
    gen_server:call(Name, {get_entry, Index}).

get_term(Index) ->
    case get_entry(Index) of
        {ok, #rafter_entry{term=Term}} ->
            Term;
        {ok, not_found} ->
            0
    end.

get_term(Name, Index) ->
    case get_entry(Name, Index) of
        {ok, #rafter_entry{term=Term}} ->
            Term;
        {ok, not_found} ->
            0
    end.

truncate(Index) ->
    gen_server:call(?MODULE, {truncate, Index}).

truncate(Name, Index) ->
    gen_server:call(Name, {truncate, Index}).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([]) ->
    {ok, #state{entries = [],
                config=#config{state=blank, 
                               oldservers=[], 
                               newservers=[]}}}.

format_status(_, [_, State]) ->
    Data = lager:pr(State, ?MODULE),
    [{data, [{"StateData", Data}]}].

handle_call({append, NewEntries}, _From, #state{entries=OldEntries}=State) ->
    Entries = NewEntries ++ OldEntries,
    Index = length(Entries),
    {reply, {ok, Index}, State#state{entries=Entries}};

handle_call(get_config, _From, #state{config=Config}=State) ->
    {reply, Config, State};

handle_call({set_config, NewConfig}, _From, State) ->
    NewState = State#state{config=NewConfig},
    {reply, ok, NewState};

handle_call(get_last_entry, _From, #state{entries=[]}=State) ->
    {reply, {ok, not_found}, State};
handle_call(get_last_entry, _From, #state{entries=[H | _T]}=State) ->
    {reply, {ok, H}, State};

handle_call(get_last_index, _From, #state{entries=Entries}=State) ->
    {reply, length(Entries), State};

handle_call({set_voted_for, VotedFor}, _From, State) ->
    {reply, ok, State#state{voted_for=VotedFor}};
handle_call(get_voted_for, _From, #state{voted_for=VotedFor}=State) ->
    {reply, {ok, VotedFor}, State};

handle_call({set_current_term, Term}, _From, State) ->
    {reply, ok, State#state{current_term=Term}};
handle_call(get_current_term, _From, #state{current_term=Term}=State) ->
    {reply, {ok, Term}, State};

handle_call({get_entry, Index}, _From, #state{entries=Entries}=State) ->
    Entry = try 
        lists:nth(Index, lists:reverse(Entries))
    catch _:_ ->
        not_found
    end, 
    {reply, {ok, Entry}, State};

handle_call({truncate, 0}, _From, #state{entries=[]}=State) ->
    {reply, ok, State};
handle_call({truncate, Index}, _From, #state{entries=Entries}=State) 
        when Index > length(Entries) ->
    {reply, {error, bad_index}, State};
handle_call({truncate, Index}, _From, #state{entries=Entries}=State) ->
    NewEntries = lists:reverse(lists:sublist(lists:reverse(Entries), Index)),
    NewState = State#state{entries=NewEntries},
    {reply, ok, NewState}.

handle_cast(stop, State) ->
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
