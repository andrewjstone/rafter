-record(state, {
    leader :: term(),
    term = 0 :: non_neg_integer(),
    voted_for :: term(),
    last_log_term :: non_neg_integer(),
    last_log_index :: non_neg_integer(),

    %% The last time a timer was created
    timer_start :: non_neg_integer(),

    %% The duration of the timer
    timer_duration :: non_neg_integer(),

    %% leader state
    followers = dict:new() :: dict(),

    %% Responses from RPCs to other servers
    responses = dict:new() :: dict(),

    %% All servers making up the ensemble
    me :: string(),
    peers :: list(string()),

    %% Different Transports can be plugged in (erlang messaging, tcp, udp, etc...)
    %% To get this thing implemented quickly, erlang messaging is hardcoded for now
    transport = erlang :: erlang}).


