-record(client_req, {
    id   :: binary(),
    timer :: timer:tref(),
    from :: term(),
    index :: non_neg_integer(),
    term :: non_neg_integer(),

    %% only used during read_only commands
    cmd :: term()}).

-record(state, {
    leader :: term(),
    term = 0 :: non_neg_integer(),
    voted_for :: term(),
    commit_index = 0 :: non_neg_integer(),
    init_config :: undefined | list() | complete | no_client,

    %% Used for Election and Heartbeat timeouts
    timer :: reference(),

    %% leader state: contains nextIndex for each peer
    followers = dict:new() :: dict(),

    %% Dict keyed by peer id.
    %% contains true as val when candidate
    %% contains match_indexes as val when leader
    responses = dict:new() :: dict(),

    %% Logical clock to allow read linearizability
    %% Reset to 0 on leader election.
    send_clock = 0 :: non_neg_integer(),

    %% Keep track of the highest send_clock received from each peer
    %% Reset on leader election
    send_clock_responses = dict:new() :: dict(),

    %% Outstanding Client Write Requests
    client_reqs = [] :: [#client_req{}],

    %% Outstanding Client Read Requests
    %% Keyed on send_clock, Val = [#client_req{}]
    read_reqs = orddict:new() :: orddict:orddict(),

    %% All servers making up the ensemble
    me :: string(),

    config :: term(),

    %% We allow pluggable backend state machine modules.
    state_machine :: atom(),
    backend_state :: term()}).
