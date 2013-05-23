-module(rafter_requester).

-include("rafter.hrl").

%% API
-export([send/2]).

-spec send(atom(), #request_vote{} | #append_entries{}) -> ok | term().
send(To, Msg) ->
    spawn(fun() ->
              case rafter_consensus_fsm:send_sync(To, Msg) of
                  {ok, Rpy} -> 
                      rafter_consensus_fsm:send(To, Rpy);
                  E ->
                      E
                  end
          end).
