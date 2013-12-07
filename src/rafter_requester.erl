-module(rafter_requester).

-include("rafter.hrl").

%% API
-export([send/2]).

-spec send(atom(), #request_vote{} | #append_entries{}) -> ok | term().
send(To, #request_vote{from=From}=Msg) ->
    send(To, From, Msg);
send(To, #append_entries{from=From}=Msg) ->
    send(To, From, Msg).

send(To, From, Msg) ->
    spawn(fun() ->
              case rafter_consensus_fsm:send_sync(To, Msg) of
                  Rpy when is_record(Rpy, vote) orelse
                           is_record(Rpy, append_entries_rpy) ->
                      rafter_consensus_fsm:send(From, Rpy);
                  E ->
                      lager:error("Error sending ~p to To ~p: ~p", [Msg, To, E])
              end
          end).
