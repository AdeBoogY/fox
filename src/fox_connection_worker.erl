-module(fox_connection_worker).
-behavior(gen_server).

-export([start_link/1, get_num_channels/1, create_channel/1, subscribe/3, unsubscribe/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("otp_types.hrl").
-include("fox.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").


-record(state, {
          connection :: pid(),
          connection_ref :: reference(),
          params_network :: #amqp_params_network{},
          consumers :: map(),
          reconnect_attempt = 0 :: non_neg_integer(),
          monitor_subscribe_ets :: ets:tid()
         }).


%%% module API

-spec start_link(term()) -> gs_start_link_reply().
start_link(Params) ->
    gen_server:start_link(?MODULE, Params, []).


-spec get_num_channels(pid()) -> {ok, integer()} | {error, no_connection}.
get_num_channels(Pid) ->
    case gen_server:call(Pid, get_connection) of
        undefined -> {error, no_connection};
        Connection -> [{num_channels, Num}] = amqp_connection:info(Connection, [num_channels]),
                      {ok, Num}
    end.


-spec create_channel(pid()) -> {ok, pid()} | {error, term()}.
create_channel(Pid) ->
    gen_server:call(Pid, create_channel).


-spec subscribe(pid(), module(), list()) -> {ok, pid()} | {error, term()}.
subscribe(Pid, ConsumerModule, ConsumerArgs) ->
    gen_server:call(Pid, {subscribe, ConsumerModule, ConsumerArgs}).


-spec unsubscribe(pid(), pid()) -> ok | {error, term()}.
unsubscribe(Pid, ChannelPid) ->
    gen_server:call(Pid, {unsubscribe, ChannelPid}).


-spec stop(pid()) -> ok.
stop(Pid) ->
    gen_server:call(Pid, stop).


%%% gen_server API

-spec init(gs_args()) -> gs_init_reply().
init(Params) ->
    herd_rand:init_crypto(),
    T = ets:new(monitor_subscribe_ets, []),
    self() ! connect,
    {ok, #state{params_network = Params, consumers = maps:new(), monitor_subscribe_ets = T}}.


-spec handle_call(gs_request(), gs_from(), gs_reply()) -> gs_call_reply().
handle_call(get_connection, _From, #state{connection = Connection} = State) ->
    {reply, Connection, State};

handle_call(create_channel, _From, #state{connection = Connection} = State) ->
    Reply = case Connection of
                undefined -> {error, no_connection};
                Pid -> amqp_connection:open_channel(Pid)
            end,
    {reply, Reply, State};

handle_call({subscribe, ConsumerModule, ConsumerArgs}, _From,
            #state{connection = Connection, consumers = Consumers, monitor_subscribe_ets = TID} = State) ->
    case Connection of
        undefined -> {reply, {error, no_connection}, State};
        _Pid -> {Reply, Consumers2} = subscribe_consumer(ConsumerModule, ConsumerArgs, Connection, Consumers, TID),
                {reply, Reply, State#state{consumers = Consumers2}}
    end;

handle_call({unsubscribe, ChannelPid}, _From, #state{consumers = Consumers, monitor_subscribe_ets = TID} = State) ->
    case maps:find(ChannelPid, Consumers) of
        {ok, {ConsumerPid, _, _}} ->
            unsubscribe_consumer(ChannelPid, ConsumerPid, TID),
            Consumers2 = maps:remove(ChannelPid, Consumers),
            {reply, ok, State#state{consumers = Consumers2}};
        error ->
            {reply, {error, channel_not_found}, State}
    end;

handle_call(stop, _From, #state{connection = Connection, connection_ref = Ref,
                                params_network = Params, consumers = Consumers} = State) ->
    error_logger:info_msg("fox_connection_worker close connection ~s",
                          [fox_utils:params_network_to_str(Params)]),
    case Connection of
        undefined -> do_nothing;
        Pid ->
            maps:map(fun(ChannelPid, ConsumerPid) ->
                             fox_channel_consumer:stop(ConsumerPid),
                             fox_utils:close_channel(ChannelPid)
                     end, Consumers),
            erlang:demonitor(Ref, [flush]),
            try
                fox_utils:close_connection(Pid)
            catch
                %% connection may be already closed on server
                exit:{noproc, _} -> ok
            end
    end,
    {stop, normal, ok, State#state{connection = undefined,
                                   connection_ref = undefined,
                                   consumers = maps:new()}};

handle_call(Any, _From, State) ->
    error_logger:error_msg("unknown call ~p in ~p ~n", [Any, ?MODULE]),
    {noreply, State}.


-spec handle_cast(gs_request(), gs_state()) -> gs_cast_reply().
handle_cast(Any, State) ->
    error_logger:error_msg("unknown cast ~p in ~p ~n", [Any, ?MODULE]),
    {noreply, State}.


-spec handle_info(gs_request(), gs_state()) -> gs_info_reply().
handle_info(connect, #state{connection = undefined, connection_ref = undefined,
                            consumers = Consumers, params_network = Params,
                            reconnect_attempt = Attempt, monitor_subscribe_ets = TID} = State) ->
    case amqp_connection:start(Params) of
        {ok, Connection} ->
            Ref = erlang:monitor(process, Connection),
            error_logger:info_msg("fox_connection_worker connected to ~s",
                                  [fox_utils:params_network_to_str(Params)]),
            Consumers2 = reinit_consumers(Connection, Consumers, TID),
            {noreply, State#state{connection = Connection, connection_ref = Ref,
                                  consumers = Consumers2, reconnect_attempt = 0}};
        {error, Reason} ->
            error_logger:error_msg("fox_connection_worker could not connect to ~s ~p",
                                   [fox_utils:params_network_to_str(Params), Reason]),
            {ok, MaxTimeout} = application:get_env(fox, max_reconnect_timeout),
            {ok, MinTimeout} = application:get_env(fox, min_reconnect_timeout),
            Timeout = herd_reconnect:exp_backoff(Attempt, MinTimeout, MaxTimeout),
            error_logger:warning_msg("fox_connection_worker reconnect after ~p attempt ~p", [Timeout, Attempt]),
            erlang:send_after(Timeout, self(), connect),
            {noreply, State#state{connection = undefined, connection_ref = undefined,
                                  reconnect_attempt = Attempt + 1}}
    end;

handle_info({'DOWN', Ref, process, Connection, Reason},
            #state{connection = Connection, connection_ref = Ref} = State) ->
    error_logger:error_msg("fox_connection_worker, connection is DOWN: ~p", [Reason]),
    self() ! connect,
    {noreply, State#state{connection = undefined, connection_ref = undefined}};

handle_info({'DOWN', Ref, process, Pid, Reason},
            #state{consumers = Consumers, monitor_subscribe_ets = TID} = State) ->
    case ets:lookup(TID, Pid) of
        [{Pid, {consumer, Pid, Ref}, {channel, ChannelPid, ChannelRef}}] ->
            error_logger:error_msg("fox_connection_worker, consumer ~p is DOWN: ~p", [Pid, Reason]),
            erlang:demonitor(Ref),
            ets:delete(TID, Pid),
            {ok, {Pid, ConsumerModule, ConsumerArgs}} = maps:find(ChannelPid, Consumers),
            {ok, ConsumerPid} = fox_channel_sup:start_worker(ChannelPid, ConsumerModule, ConsumerArgs),
            ConsumerRef = erlang:monitor(process, ConsumerPid),
            ets:insert(TID, [{ConsumerPid, {consumer, ConsumerPid, ConsumerRef}, {channel, ChannelPid, ChannelRef}},
                             {ChannelPid, {consumer, ConsumerPid, ConsumerRef}, {channel, ChannelPid, ChannelRef}}]),
            Consumers2 = maps:put(ChannelPid, {ConsumerPid, ConsumerModule, ConsumerArgs}, Consumers),
            {noreply, State#state{consumers = Consumers2}};

        [{Pid, {consumers, ConsumerPid, _}, {channel, Pid, Ref}}] ->
            error_logger:error_msg("fox_connection_worker, channel ~p is DOWN: ~p", [Pid, Reason]),
            erlang:demonitor(Pid),
            ets:delete(TID, Pid),
            Consumers2 = maps:remove(Pid, Consumers),
            fox_channel_consumer:stop(ConsumerPid),
            {noreply, State#state{consumers = Consumers2}};

        [] ->
            error_logger:error_msg("fox_connection_worker, unknow process ~p is DOWN: ~p", [Pid, Reason]),
            {noreply, State}
    end;

handle_info(Request, State) ->
    error_logger:error_msg("unknown info ~p in ~p ~n", [Request, ?MODULE]),
    {noreply, State}.


-spec terminate(terminate_reason(), gs_state()) -> ok.
terminate(_Reason, _State) ->
    ok.


-spec code_change(term(), term(), term()) -> gs_code_change_reply().
code_change(_OldVersion, State, _Extra) ->
    {ok, State}.


%% inner functions

-spec subscribe_consumer(module(), list(), pid(), map(), ets:tid()) -> {{ok, pid()}, map()} | {{error, term()}, map()}.
subscribe_consumer(ConsumerModule, ConsumerArgs, Connection, Consumers, TID) ->
    case amqp_connection:open_channel(Connection) of
        {ok, ChannelPid} ->
            {ok, ConsumerPid} = fox_channel_sup:start_worker(ChannelPid, ConsumerModule, ConsumerArgs),
            Ref1 = erlang:monitor(process, ConsumerPid),
            Ref2 = erlang:monitor(process, ChannelPid),
            ets:insert(TID, [{ConsumerPid, {consumer, ConsumerPid, Ref1}, {channel, ChannelPid, Ref2}},
                             {ChannelPid,  {consumer, ConsumerPid, Ref1}, {channel, ChannelPid, Ref2}}]),
            Consumers2 = maps:put(ChannelPid, {ConsumerPid, ConsumerModule, ConsumerArgs}, Consumers),
            {{ok, ChannelPid}, Consumers2};
        {error, Reason} ->
            {{error, Reason}, Consumers}
    end.


-spec unsubscribe_consumer(pid(), pid(), ets:tid()) -> ok.
unsubscribe_consumer(ChannelPid, ConsumerPid, TID) ->
    case ets:lookup(TID, ChannelPid) of
        [{ChannelPid, _, {channel, ChannelPid, Ref2}}] ->
            erlang:demonitor(Ref2, [flush]),
            ets:delete(TID, ChannelPid);
        [] -> error_logger:error_msg("~p:unsubscribe uknown channel ~p", [?MODULE, ChannelPid])
    end,
    case ets:lookup(TID, ConsumerPid) of
        [{ConsumerPid, {consumer, ConsumerPid, Ref1}, _}] ->
            erlang:demonitor(Ref1, [flush]),
            ets:delete(TID, ConsumerPid);
        [] -> error_logger:error_msg("~p:unsubscribe uknown consumer ~p", [?MODULE, ConsumerPid])
    end,
    fox_channel_consumer:stop(ConsumerPid),
    fox_utils:close_channel(ChannelPid),
    ok.


-spec reinit_consumers(pid(), map(), ets:tid()) -> ok.
reinit_consumers(Connection, Consumers, TID) ->
    maps:fold(fun(ChannelPid, {ConsumerPid, ConsumerModule, ConsumerArgs}, Acc) ->
                      unsubscribe_consumer(ChannelPid, ConsumerPid, TID),
                      {_, Acc2} = subscribe_consumer(ConsumerModule, ConsumerArgs, Connection, Acc, TID),
                      Acc2
              end, maps:new(), Consumers).
