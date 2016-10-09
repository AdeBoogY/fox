-module(fox_conn_pool).
-behavior(gen_server).

-export([start_link/0, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("otp_types.hrl").
-include("fox.hrl").

-record(state, {
    connections :: queue:queue()
}).


%%% module API

-spec start_link() -> gs_start_link_reply().
start_link() ->
    gen_server:start_link(?MODULE, no_args, []).


-spec stop(pid()) -> ok.
stop(_Pid) ->
    %% TODO
    %% gen_server:call(Pid, stop).
    ok.


%%% gen_server API

-spec init(gs_args()) -> gs_init_reply().
init(_Args) ->
    put('$module', ?MODULE),
    {ok, #state{}}.


-spec handle_call(gs_request(), gs_from(), gs_reply()) -> gs_call_reply().
handle_call(Any, _From, State) ->
    error_logger:error_msg("unknown call ~p in ~p ~n", [Any, ?MODULE]),
    {noreply, State}.


-spec handle_cast(gs_request(), gs_state()) -> gs_cast_reply().
handle_cast(Any, State) ->
    error_logger:error_msg("unknown cast ~p in ~p ~n", [Any, ?MODULE]),
    {noreply, State}.


-spec handle_info(gs_request(), gs_state()) -> gs_info_reply().
handle_info(Request, State) ->
    error_logger:error_msg("unknown info ~p in ~p ~n", [Request, ?MODULE]),
    {noreply, State}.


-spec terminate(terminate_reason(), gs_state()) -> ok.
terminate(_Reason, _State) ->
    ok.


-spec code_change(term(), term(), term()) -> gs_code_change_reply().
code_change(_OldVersion, State, _Extra) ->
    {ok, State}.
