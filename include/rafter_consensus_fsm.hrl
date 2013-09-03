-record(client_req, {
    id   :: binary(),
    timer :: timer:tref(),
    from :: term(),
    index :: non_neg_integer(),
    term :: non_neg_integer()}).

-record(state, {
    leader :: term(),
    term = 0 :: non_neg_integer(),
    voted_for :: term(),
    commit_index = 0 :: non_neg_integer(),
    init_config :: undefined | list() | complete,

    %% The last time a timer was created
    timer_start :: non_neg_integer(),

    %% The duration of the timer
    timer_duration :: non_neg_integer(),

    %% leader state
    followers = dict:new() :: dict(),

    %% Responses from RPCs to other servers
    responses = dict:new() :: dict(),

    %% Outstanding Client Requests
    client_reqs = [] :: [#client_req{}],

    %% All servers making up the ensemble
    me :: string(),

    config :: term(),
    
    %% We allow pluggable state machine modules.
    state_machine :: atom()}).
