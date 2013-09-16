-module(rafter_log).

-behaviour(gen_server).

-include_lib("kernel/include/file.hrl").

-include("rafter.hrl").
-include("rafter_opts.hrl").

%% API
-export([start_link/2, stop/1, append/2, check_and_append/3, binary_to_entry/1,
        entry_to_binary/1,get_last_entry/1, get_entry/2, get_term/2,
        get_last_index/1, get_last_term/1, get_config/1, set_metadata/3,
        get_metadata/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3, format_status/2]).

%%=============================================================================
%% Logfile Structure
%%=============================================================================
%% @doc A log is made up of a file header and entries. The header contains file
%%      metadata and is written once at file creation. Each entry is a binary
%%      of arbitrary size containing header information and is followed by a trailer.
%%      The formats of the file header and entries are described below.
%%
%%         File Header Format
%%         -----------------------
%%         <<Version:8>>
%%
%%         Entry Format
%%         ----------------
%%         <<Sha1:20/binary, Type:8, Term:64, Index: 64, DataSize:32, Data/binary>>
%%
%%         Sha1 - hash of the rest of the entry,
%%         Type - ?CONFIG | ?OP
%%         Term - The term of the entry
%%         Index - The log index of the entry
%%         DataSize - The size of Data in bytes
%%         Data - Data encoded with term_to_binary/1
%%
%%     After each log entry a trailer is written. The trailer is used for
%%     detecting incomplete/corrupted writes, pointing to the latest config and
%%     traversing the log file backwards.
%%
%%         Trailer Format
%%         ----------------
%%         <<Crc:32, ConfigStart:64, EntryStart:64, ?MAGIC:64>>
%%
%%         Crc - checksum, computed with erlang:crc32/1, of the rest of the trailer
%%         ConfigStart - file location of last seen config,
%%         EntryStart - file location of the start of this entry
%%         ?MAGIC - magic number marking the end of the trailer.
%%                  A fully consistent log should always have
%%                  the following magic number as the last 8 bytes:
%%                  <<"\xFE\xED\xFE\xED\xFE\xED\xFE\xED">>
%%

-record(state, {
    logfile :: file:io_device(),
    version :: non_neg_integer(),
    meta_filename :: string(),
    write_location = 0 :: non_neg_integer(),
    config :: #config{},
    config_loc :: non_neg_integer(),
    meta :: #meta{},
    last_entry :: #rafter_entry{},
    index = 0 :: non_neg_integer(),
    term = 0 :: non_neg_integer()}).

-define(MAGIC, <<"\xFE\xED\xFE\xED\xFE\xED\xFE\xED">>).
-define(MAGIC_SIZE, 8).
-define(HEADER_SIZE, 41).
-define(TRAILER_SIZE, 28).
-define(FILE_HEADER_SIZE, 1).
-define(READ_BLOCK_SIZE, 1048576). %% 1MB
-define(LATEST_VERSION, 1).

%% Entry Types
-define(NOOP, 0).
-define(CONFIG, 1).
-define(OP, 2).
-define(ALL, [?CONFIG, ?OP]).

%%====================================================================
%% API
%%====================================================================
entry_to_binary(#rafter_entry{type=noop, term=Term, index=Index, cmd=noop}) ->
    entry_to_binary(?NOOP, Term, Index, noop);
entry_to_binary(#rafter_entry{type=config, term=Term, index=Index, cmd=Data}) ->
    entry_to_binary(?CONFIG, Term, Index, Data);
entry_to_binary(#rafter_entry{type=op, term=Term, index=Index, cmd=Data}) ->
    entry_to_binary(?OP, Term, Index, Data).

entry_to_binary(Type, Term, Index, Data) ->
    BinData = term_to_binary(Data),
    B0 = <<Type:8, Term:64, Index:64, (byte_size(BinData)):32, BinData/binary>>,
    Sha1 = crypto:hash(sha, B0),
    <<Sha1/binary, B0/binary>>.

binary_to_entry(<<Sha1:20/binary, Type:8, Term:64, Index:64, Size:32, Data/binary>>) ->
    %% We want to crash on badmatch here if if our log is corrupt
    %% TODO: Allow an operator to repair the log by truncating at that point
    %% or repair each entry 1 by 1 by consulting a good log.
    Sha1 = crypto:hash(sha, <<Type:8, Term:64, Index:64, Size:32, Data/binary>>),
    binary_to_entry(Type, Term, Index, Data).

binary_to_entry(?NOOP, Term, Index, _Data) ->
    #rafter_entry{type=noop, term=Term, index=Index, cmd=noop};
binary_to_entry(?CONFIG, Term, Index, Data) ->
    #rafter_entry{type=config, term=Term, index=Index, cmd=binary_to_term(Data)};
binary_to_entry(?OP, Term, Index, Data) ->
    #rafter_entry{type=op, term=Term, index=Index, cmd=binary_to_term(Data)}.

start_link(Peer, Opts) ->
    gen_server:start_link({local, logname(Peer)}, ?MODULE, [Peer, Opts], []).

stop(Peer) ->
    gen_server:cast(logname(Peer), stop).

%% @doc check_and_append/3 gets called in the follower state only and will only
%% truncate the log if entries don't match. It never truncates and re-writes
%% committed entries as this violates the safety of the RAFT protocol.
check_and_append(Peer, Entries, Index) ->
    gen_server:call(logname(Peer), {check_and_append, Entries, Index}).

%% @doc append/2 gets called in the leader state only, and assumes a
%% truncated log.
append(Peer, Entries) ->
    gen_server:call(logname(Peer), {append, Entries}).

get_config(Peer) ->
    gen_server:call(logname(Peer), get_config).

get_last_index(Peer) ->
    gen_server:call(logname(Peer), get_last_index).

get_last_entry(Peer) ->
    gen_server:call(logname(Peer), get_last_entry).

get_last_term(Peer) ->
    case get_last_entry(Peer) of
        {ok, #rafter_entry{term=Term}} ->
            Term;
        {ok, not_found} ->
            0
    end.

get_metadata(Peer) ->
    gen_server:call(logname(Peer), get_metadata).

set_metadata(Peer, VotedFor, Term) ->
    gen_server:call(logname(Peer), {set_metadata, VotedFor, Term}).

get_entry(Peer, Index) ->
    gen_server:call(logname(Peer), {get_entry, Index}).

get_term(Peer, Index) ->
    case get_entry(Peer, Index) of
        {ok, #rafter_entry{term=Term}} ->
            Term;
        {ok, not_found} ->
            0
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Name, #rafter_opts{logdir = Logdir}]) ->
    LogName = Logdir++"/rafter_"++atom_to_list(Name)++".log",
    MetaName = Logdir++"/rafter_"++atom_to_list(Name)++".meta",
    {ok, LogFile} = file:open(LogName, [append, read, binary, raw]),
    {ok, #file_info{size=Size}} = file:read_file_info(LogName),
    {ok, Meta} = read_metadata(MetaName, Size),
    {ConfigLoc, Config, Term, Index, WriteLocation, Version} = init_file(LogFile, Size),
    LastEntry = find_last_entry(LogFile, WriteLocation),
    {ok, #state{logfile=LogFile,
                version=Version,
                meta_filename=MetaName,
                write_location=WriteLocation,
                term=Term,
                index=Index,
                meta=Meta,
                config=Config,
                config_loc = ConfigLoc,
                last_entry=LastEntry}}.

format_status(_, [_, State]) ->
    Data = lager:pr(State, ?MODULE),
    [{data, [{"StateData", Data}]}].

handle_call({check_and_append, Entries, Index}, _From, #state{logfile=File}=S) ->
    Loc = get_pos(File, Index),
    #state{index=NewIndex}=NewState = maybe_append(Index, Loc, Entries, S),
    {reply, {ok, NewIndex}, NewState};

handle_call({append, Entries}, _From, #state{logfile=File}=State) ->
    NewState = write_entries(File, Entries, State),
    Index = NewState#state.index,
    {reply, {ok, Index}, NewState};

handle_call(get_config, _From, #state{config=Config}=State) ->
    {reply, Config, State};

handle_call(get_last_entry, _From, #state{last_entry=undefined}=State) ->
    {reply, {ok, not_found}, State};
handle_call(get_last_entry, _From, #state{last_entry=LastEntry}=State) ->
    {reply, {ok, LastEntry}, State};

handle_call(get_last_index, _From, #state{index=Index}=State) ->
    {reply, Index, State};

handle_call(get_metadata, _, #state{meta=Meta}=State) ->
    {reply, Meta, State};

handle_call({set_metadata, VotedFor, Term}, _, #state{meta_filename=Name}=S) ->
    Meta = #meta{voted_for=VotedFor, term=Term},
    ok = write_metadata(Name, Meta),
    {reply, ok, S#state{meta=Meta}};

%% This always starts searching from the head of the log. Todo: Be smarter.
handle_call({get_entry, Index}, _From, #state{logfile=File}=State) ->
    Res = find_entry(File, ?FILE_HEADER_SIZE, Index),
    {reply, {ok, Res}, State}.

handle_cast(stop, #state{logfile=File}=State) ->
    ok = file:close(File),
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%====================================================================
%% Internal Functions
%%====================================================================

maybe_append(_, _, [], State) ->
    State;
maybe_append(Index, eof, [Entry | Entries], State) ->
    NewState = write_entry(Entry, State),
    maybe_append(Index+1, eof, Entries, NewState);
maybe_append(Index, Loc, [#rafter_entry{term=Term}=Entry | Entries],
             State=#state{logfile=File}) ->
    case read_entry(File, Loc) of
        {entry, Data, NewLocation} ->
            case binary_to_entry(Data) of
                #rafter_entry{index=Index, term=Term} ->
                    maybe_append(Index+1, NewLocation, Entries, State);
                #rafter_entry{index=Index, term=_} ->
                    truncate(File, Loc),
                    State1 = State#state{write_location=Loc},
                    State2 = write_entry(Entry, State1),
                    maybe_append(Index + 1, eof, Entries, State2)
            end;
        eof ->
            truncate(File, Loc),
            State1 = State#state{write_location=Loc},
            State2 = write_entry(Entry, State1),
            maybe_append(Index+1, eof, Entries, State2)
    end.

logname({Name, _Node}) ->
    list_to_atom(atom_to_list(Name) ++ "_log");
logname(Me) ->
    list_to_atom(atom_to_list(Me) ++ "_log").

init_file(File, 0) ->
    {ok, Loc} = write_file_header(File),
    {0, #config{}, 0, 0, Loc, ?LATEST_VERSION};
init_file(File, Size) ->
    case repair_file(File, Size) of
        {ok, ConfigLoc, Term, Index, WriteLoc} ->
            {ok, Version} = read_file_header(File),
            {ok, Config} = read_config(File, ConfigLoc),
            {ConfigLoc, Config, Term, Index, WriteLoc, Version};
        empty_file ->
            {ok, Loc} = write_file_header(File),
            {0, #config{}, 0, 0, Loc, ?LATEST_VERSION}
    end.

read_file_header(File) ->
    {ok, <<Version:8>>} = file:pread(File, 0, ?FILE_HEADER_SIZE),
    {ok, Version}.

write_file_header(File) ->
    ok = file:write(File, <<?LATEST_VERSION:8>>),
    {ok, ?FILE_HEADER_SIZE}.

make_trailer(EntryStart, ConfigStart) ->
    T = <<ConfigStart:64, EntryStart:64, ?MAGIC/binary >>,
    Crc = erlang:crc32(T),
    <<Crc:32, T/binary>>.

write_entries(File, Entries, State) ->
    NewState = lists:foldl(fun write_entry/2, State, Entries),
    ok = file:sync(File),
    NewState.

write_entry(#rafter_entry{type=Type, cmd=Cmd}=Entry, S=#state{write_location=Loc,
                                                              config=Config,
                                                              config_loc=ConfigLoc,
                                                              index=Index,
                                                              logfile=File}) ->
    NewIndex = Index + 1,
    NewEntry = Entry#rafter_entry{index=NewIndex},
    BinEntry = entry_to_binary(NewEntry),
    {NewConfigLoc, NewConfig, Trailer} =
    case Type of
        config ->
            {Loc, Cmd, make_trailer(Loc, Loc)};
        _ ->
            {ConfigLoc, Config, make_trailer(Loc, ConfigLoc)}
    end,
    ok = file:write(File, <<BinEntry/binary, Trailer/binary>>),
    NewLoc = Loc + byte_size(BinEntry) + ?TRAILER_SIZE,
    S#state{index=NewIndex,
            config=NewConfig,
            write_location=NewLoc,
            config_loc=NewConfigLoc,
            last_entry=NewEntry}.

read_config(File, Loc) ->
    {entry, Data, _} = read_entry(File, Loc),
    #rafter_entry{type=config, cmd=Config} = binary_to_entry(Data),
    {ok, Config}.

%% TODO: Write to a tmp file then rename so the write is always atomic and the
%% metadata file cannot become partially written.
write_metadata(Filename, Meta) ->
    ok = file:write_file(Filename, term_to_binary(Meta)).

read_metadata(Filename, FileSize) ->
    case file:read_file(Filename) of
        {ok, Bin} ->
            {ok, binary_to_term(Bin)};
        {error, enoent} when FileSize =< ?FILE_HEADER_SIZE ->
            {ok, #meta{}};
        {error, Reason} ->
            io:format("Failed to open metadata file: ~p. Reason = ~p~n",
                [Filename, Reason]),
            {ok, #meta{}}
    end.

truncate(File, Pos) ->
    file:position(File, Pos),
    file:truncate(File).

maybe_truncate(File, TruncateAt, FileSize) ->
    case TruncateAt < FileSize of
        true ->
            ok = truncate(File, TruncateAt);
        false ->
            ok
    end.

repair_file(File, Size) ->
    case scan_for_trailer(File, Size) of
        {ok, ConfigStart, EntryStart, TruncateAt} ->
            maybe_truncate(File, TruncateAt, Size),
            {entry, Data, _} = read_entry(File, EntryStart),
            #rafter_entry{term=Term, index=Index} = binary_to_entry(Data),
            {ok, ConfigStart, Term, Index, TruncateAt};
        not_found ->
            io:format("NOT FOUND: Size = ~p~n", [Size]),
            truncate(File, 0),
            empty_file
    end.

scan_for_trailer(File, Loc) ->
    case find_magic_number(File, Loc) of
        {ok, MagicLoc} ->
            case file:pread(File, MagicLoc - (?TRAILER_SIZE-?MAGIC_SIZE), ?TRAILER_SIZE) of
                {ok, <<Crc:32, ConfigStart:64, EntryStart:64, _/binary >>} ->
                    case erlang:crc32(<<ConfigStart:64, EntryStart:64, ?MAGIC/binary >>) of
                        Crc ->
                            {ok, ConfigStart, EntryStart, MagicLoc + 8};
                        _ ->
                            scan_for_trailer(File, MagicLoc)
                    end;
                eof ->
                    not_found
            end;
        not_found ->
            not_found
    end.

read_block(File, Loc) ->
    case Loc < ?READ_BLOCK_SIZE of
        true ->
            {ok, Buffer} = file:pread(File, 0, Loc),
            {Buffer, 0};
        false ->
            Start = Loc - ?READ_BLOCK_SIZE,
            {ok, Buffer} = file:pread(File, Start, ?READ_BLOCK_SIZE),
            {Buffer, Start}
    end.

%% @doc Continuously read blocks from the file and search backwards until the
%% magic number is found or we reach the beginning of the file.
find_magic_number(File, Loc) ->
    {Block, Start} = read_block(File, Loc),
    case find_last_magic_number_in_block(Block) of
        {ok, Offset} ->
            io:format("Magic Number found at ~p~n", [Start+Offset]),
            {ok, Start+Offset};
        not_found ->
            case Start of
                0 ->
                    not_found;
                _ ->
                    %% Ensure we search the overlapping 8 bytes between blocks
                    find_magic_number(File, Start+8)
            end
    end.

-spec find_last_magic_number_in_block(binary()) ->
    {ok, non_neg_integer()} | not_found.
find_last_magic_number_in_block(Block) ->
    case string:rstr(binary_to_list(Block), binary_to_list(?MAGIC)) of
        0 ->
            not_found;
        Index ->
            %% We want the 0 based binary offset, not the 1 based list offset.
            {ok, Index - 1}
    end.

get_pos(File, Index) ->
    get_pos(File, ?FILE_HEADER_SIZE, Index).

get_pos(File, Loc, Index) ->
    case file:pread(File, Loc, ?HEADER_SIZE) of
        {ok, <<_Sha1:20/binary, _Type:8, _Term:64, Index:64, _DataSize:32>>} ->
            Loc;
        {ok, <<_:37/binary, DataSize:32>>} ->
            get_pos(File, Loc + ?HEADER_SIZE + DataSize + ?TRAILER_SIZE, Index);
        eof ->
            eof
    end.

%% @doc Find an entry at the given index in a file. Search forward from Loc.
find_entry(File, Loc, Index) ->
    case file:pread(File, Loc, ?HEADER_SIZE) of
        {ok, <<_Sha1:20/binary, _Type:8, _Term:64, Index:64, _DataSize:32>>=Header} ->
            case read_data(File, Loc + ?HEADER_SIZE, Header) of
                {entry, Entry, _} ->
                    binary_to_entry(Entry);
                eof ->
                    %% This should only occur if the entry is currently being written.
                    not_found
            end;
        {ok, <<_:37/binary, DataSize:32>>} ->
            find_entry(File, Loc + ?HEADER_SIZE + DataSize + ?TRAILER_SIZE, Index);
        eof ->
            not_found
    end.

find_last_entry(_File, WriteLocation) when WriteLocation =< ?FILE_HEADER_SIZE ->
    undefined;
find_last_entry(File, WriteLocation) ->
    {ok, <<_:32, _:64, EntryStart:64, _/binary>>} =
        file:pread(File, WriteLocation - ?TRAILER_SIZE, ?TRAILER_SIZE),
    {entry, Entry, _} = read_entry(File, EntryStart),
    binary_to_entry(Entry).

%% @doc This function reads the next entry from the log at the given location
%% and returns {entry, Entry, NewLocation}. If the end of file has been reached,
%% return eof to the client. Errors are fail-fast.
-spec read_entry(file:io_device(), non_neg_integer()) ->
    {entry, binary(), non_neg_integer()} | {skip, non_neg_integer()} | eof.
read_entry(File, Location) ->
    case file:pread(File, Location, ?HEADER_SIZE) of
        {ok, <<_Sha1:20/binary, _Type:8, _Term:64, _Index:64, _DataSize:32>>=Header} ->
            read_data(File, Location + ?HEADER_SIZE, Header);
        eof ->
            eof
    end.

-spec read_data(file:io_device(), non_neg_integer(), binary()) ->
    {entry, binary(), non_neg_integer()} | eof.
read_data(File, Location, <<Sha1:20/binary, Type:8, Term:64, Index:64, Size:32>>=H) ->
    case file:pread(File, Location, Size) of
        {ok, Data} ->
            %% Fail-fast Integrity check. TODO: Offer user repair options?
            Sha1 = crypto:hash(sha, <<Type:8, Term:64, Index:64, Size:32, Data/binary>>),
            NewLocation = Location + Size + ?TRAILER_SIZE,
            {entry, <<H/binary, Data/binary>>, NewLocation};
        eof ->
            eof
    end.
