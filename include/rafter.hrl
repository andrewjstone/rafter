-type peer() :: atom() | {atom(), atom()}.

%% Transport Independent MESSAGES
-record(request_vote, {
            term :: non_neg_integer(),
            from :: atom(),
            last_log_index :: non_neg_integer(),
            last_log_term :: non_neg_integer()}).

-record(vote, {
            from :: atom(),
            term :: non_neg_integer(),
            success :: boolean()}).

-record(append_entries, {
            term :: non_neg_integer(),
            from :: atom(),
            prev_log_index :: non_neg_integer(),
            prev_log_term :: non_neg_integer(),
            entries :: term(),
            commit_index :: non_neg_integer(),

            %% This is used during read-only operations
            send_clock :: non_neg_integer()}).

-record(append_entries_rpy, {
            from :: atom(),
            term :: non_neg_integer(),

            %% This field isn't in the raft paper. However, for this implementation
            %% it prevents duplicate responses from causing recommits and helps
            %% maintain safety. In the raft reference implementation (logcabin)
            %% they cancel the in flight RPC's instead. That's difficult
            %% to do correctly(without races) in erlang with asynchronous
            %% messaging and mailboxes.
            index :: non_neg_integer(),

            %% This is used during read-only operations
            send_clock :: non_neg_integer(),

            success :: boolean()}).

-record(rafter_entry, {
        type :: noop | config | op,
        term :: non_neg_integer(),
        index :: non_neg_integer(),
        cmd :: term()}).

-record(meta, {
    voted_for :: peer(),
    term = 0 :: non_neg_integer()}).

-record(config, {
    state = blank ::
        %% The configuration specifies no servers. Servers that are new to the
        %% cluster and have empty logs start in this state.
        blank   |
        %% The configuration specifies a single list of servers: a quorum
        %% requires any majority of oldservers.
        stable  |
        %% The configuration specifies two lists of servers: a quorum requires
        %% any majority of oldservers, but the newservers also receive log entries.
        staging |
        %% The configuration specifies two lists of servers: a quorum requires
        %% any majority of oldservers and any majority of the newservers.
        transitional,

    oldservers = [] :: list(),
    newservers = [] :: list()
}).

