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
            term :: non_neg_integer(),
            success :: boolean()}).

-record(rafter_entry, {
        term :: non_neg_integer(),
        command :: binary()}).
