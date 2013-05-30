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
            commitIndex :: non_neg_integer()}).

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
            success :: boolean()}).

-record(rafter_entry, {
        version=0 :: non_neg_integer(),
        term :: non_neg_integer(),
        cmd :: binary()}).
