%% Transport Independent MESSAGES
-record(request_vote, {
            msg_id :: binary(), %% for message uniqueness
            term :: non_neg_integer(),
            from :: term(),
            last_log_index :: non_neg_integer(),
            last_log_term :: non_neg_term()}).

-record(vote, {
            msg_id :: binary(), %% Same Id a request_vote
            from :: term(),
            term :: non_neg_integer(),
            success :: boolean()}).

-record(append_entries, {
            msg_id :: binary(), %% for message uniqueness
            term :: non_neg_integer(),
            from :: term(),
            last_log_index :: non_neg_integer(),
            last_log_term :: non_neg_term(),
            entries :: term(),
            commitIndex :: non_neg_integer()}).

-record(append_entries_rpy, {
            msg_id :: binary(), %% Same Id as append_entries
            from :: term(),
            term :: non_neg_integer(),
            success :: boolean()});

%% Log Details
-record(log_state, {
        current_term :: non_neg_integer(),
        voted_for :: term(),
        entries:: [term()]}).

-record(log_entry, {
            term :: non_neg_integer(),
            index :: non_neg_integer(),
            command :: binary()}).
