%% Transport Independent MESSAGES
-record(request_vote, {
            msg_id :: binary(), %% for message uniqueness
            term :: non_neg_integer(),
            from :: term(),
            last_log_index :: non_neg_integer(),
            last_log_term :: non_neg_integer()}).

-record(vote, {
            msg_id :: binary(), %% Same Id a request_vote
            from :: term(),
            term :: non_neg_integer(),
            success :: boolean()}).

-record(append_entries, {
            msg_id :: binary(), %% for message uniqueness
            term :: non_neg_integer(),
            from :: term(),
            prev_log_index :: non_neg_integer(),
            prev_log_term :: non_neg_integer(),
            entries :: term(),
            commitIndex :: non_neg_integer()}).

-record(append_entries_rpy, {
            msg_id :: binary(), %% Same Id as append_entries
            from :: term(),
            term :: non_neg_integer(),
            success :: boolean()}).

