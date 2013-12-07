-module(rafter_backend).

-callback init(Args :: term()) -> State :: term().
-callback read(Operation :: term(), State :: term()) ->
    {Value :: term(), State :: term()}.
-callback write(Operation :: term(), State :: term()) ->
    {Value :: term(), State :: term()}.
