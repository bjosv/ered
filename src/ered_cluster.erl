-module(ered_cluster).

%% Cluster handling module. Keeps track of clients and keeps the slot map
%% up to date. Cluster status can be monitored by subscribing to info
%% messages.


-behaviour(gen_server).

%% API
-export([start_link/2,
         stop/1,
         update_slots/3,
         get_slot_map_info/1,
         connect_node/2
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).


-export_type([opt/0,
              addr/0]).

%%%===================================================================
%%% Definitions
%%%===================================================================

%% A check that all nodes return the same CLUSTER SLOTS response.
-type convergence_check() :: ok | nok |
                             %% Scheduled: Timer ref to start the check.
                             {scheduled, reference()} |
                             %% Ongoing: Nodes still to confirm and timer ref
                             %% for time limit.
                             {ongoing, addr_set(), reference()}.

-record(st, {
             cluster_state = nok :: ok | nok,
             %% Supervisor for our client processes
             client_sup :: pid(),
             %% The initial configured nodes, used as fallback if no nodes are
             %% reachable. If the init nodes are hostnames that map to IP
             %% addresses and all IP addresses of the cluster have changed at
             %% the same time, then this approach allows the client to recover.
             initial_nodes = [] :: [addr()],
             %% Mapping from address to client for all known clients
             nodes = #{} :: #{addr() => pid()},
             %% Clients in connected state for which we have received a
             %% connection_up. Includes reconnecting nodes until the
             %% node_down_timeout, and deactivated nodes pending to be closed
             %% at the close_wait timeout.
             up = new_set([]) :: addr_set(),
             %% Clients that are currently masters
             masters = new_set([]) :: addr_set(),
             %% Clients with a full queue
             queue_full = new_set([]) :: addr_set(),
             %% Clients started but not connected yet, i.e. not considered 'up'.
             pending = new_set([]) :: addr_set(),
             %% Clients that lost connection and trying to reconnect, probably a
             %% harmless situation. These are still considered 'up'.
             reconnecting = new_set([]) :: addr_set(),
             %% Clients pending to be closed. Mapped to the closing timer
             %% reference
             closing = #{} :: #{addr() => reference()},

             slot_map = [],
             slot_map_version = 0,
             slot_timer_ref = none,
             convergence_check = nok :: convergence_check(),

             info_pid = [] :: [pid()],
             client_opts = [],
             update_slot_wait = 500,
             min_replicas = 0,
             convergence_check_timeout = 1000,
             convergence_check_delay = 5000,
             close_wait = 10000
            }).


-type addr() :: ered_client:addr().
-type addr_set() :: sets:set(addr()).
-type server_ref() :: pid().
-type client_ref() :: ered_client:server_ref().

-type opt() ::
        %% List of pids to receive cluster info messages. See ered_info_msg module.
        {info_pid, [pid()]} |
        %% CLUSTER SLOTS command is used to fetch slots from the Redis cluster.
        %% This value sets how long to wait before trying to send the command again.
        {update_slot_wait, non_neg_integer()} |
        %% Options passed to the client
        {client_opts, [ered_client:opt()]} |
        %% For each Redis master node, the min number of replicas for the cluster
        %% to be considered OK.
        {min_replicas, non_neg_integer()} |
        %% If non-zero, a check that all nodes converge and report identical
        %% slot maps is performed before reporting 'cluster_ok'.
        {convergence_check_timeout, timeout()} |
        %% If non-zero, a check that all nodes converge and report identical
        %% slot maps is performed even when the state is already 'cluster_ok',
        %% but only after the specified delay.
        {convergence_check_delay, timeout()} |
        %% How long to delay the closing of clients that are no longer part of
        %% the slot map. The delay is needed so that messages sent to the client
        %% are not lost in transit.
        {close_wait, non_neg_integer()}.


%%%===================================================================
%%% API
%%%===================================================================

%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
-spec start_link([addr()], [opt()]) -> {ok, server_ref()} | {error, term()}.
%%
%% Start the cluster process. Clients will be set up to the provided
%% addresses and cluster information will be retrieved.
%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
start_link(Addrs, Opts) ->
    gen_server:start_link(?MODULE, [Addrs, Opts], []).

%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
-spec stop(server_ref()) -> ok.
%%
%% Stop the cluster handling process and in turn disconnect and stop
%% all clients.
%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
stop(ServerRef) ->
    gen_server:stop(ServerRef).

%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
-spec update_slots(server_ref(), non_neg_integer(), client_ref() | none) -> ok.
%%
%% Trigger a CLUSTER SLOTS command towards the specified Redis node if
%% the slot map version provided is the same as the one stored in the
%% cluster process state. This is used when a cluster state change is
%% detected with a MOVED redirection. It is also used when triggering
%% a slot update manually. In this case the node is 'none', meaning
%% no specific node is preferred.
%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
update_slots(ServerRef, SlotMapVersion, Node) ->
    gen_server:cast(ServerRef, {trigger_map_update, SlotMapVersion, Node}).

%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
-spec get_slot_map_info(server_ref()) ->
          {SlotMapVersion :: non_neg_integer(),
           SlotMap :: ered_lib:slot_map(),
           Clients :: #{addr() => pid()}}.
%%
%% Fetch the cluster information. This provides the current slot map
%% and a map with all the clients.
%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
get_slot_map_info(ServerRef) ->
    gen_server:call(ServerRef, get_slot_map_info).

%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
-spec connect_node(server_ref(), addr()) -> client_ref().
%%
%% Connect a client to the address and return a client reference. If a
%% client already exists for the address return a reference. This is
%% useful when a MOVE redirection is given to a address that has not
%% been seen before.
%% - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
connect_node(ServerRef, Addr) ->
    gen_server:call(ServerRef, {connect_node, Addr}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Addrs, Opts]) ->
    {ok, ClientSup} = ered_client_sup:start_link(),
    State = lists:foldl(
              fun ({info_pid, Val}, S)         -> S#st{info_pid = Val};
                  ({update_slot_wait, Val}, S) -> S#st{update_slot_wait = Val};
                  ({client_opts, Val}, S)      -> S#st{client_opts = Val};
                  ({min_replicas, Val}, S)     -> S#st{min_replicas = Val};
                  ({convergence_check_timeout, Val}, S) ->
                      S#st{convergence_check_timeout = Val};
                  ({convergence_check_delay, Val}, S) ->
                      S#st{convergence_check_delay = Val};
                  ({close_wait, Val}, S)       -> S#st{close_wait = Val};
                  (Other, _)                   -> error({badarg, Other})
              end,
              #st{client_sup = ClientSup,
                  initial_nodes = Addrs},
              Opts),
    {ok, start_clients(Addrs, State)}.


handle_call(get_slot_map_info, _From, State) ->
    Nodes = ered_lib:slotmap_all_nodes(State#st.slot_map),
    Clients = maps:with(Nodes, State#st.nodes),
    Reply = {State#st.slot_map_version, State#st.slot_map, Clients},
    {reply,Reply,State};

handle_call({connect_node, Addr}, _From, State) ->
    State1 = start_clients([Addr], State),
    ClientPid = maps:get(Addr, State1#st.nodes),
    {reply, ClientPid, State1}.

handle_cast({trigger_map_update, SlotMapVersion, Node}, State) ->
    case (SlotMapVersion == State#st.slot_map_version) and (State#st.slot_timer_ref == none) of
        true ->
            %% Get the address of the client. The address is needd to look up the node status
            %% before sending an update. This could need to go through all the nodes
            %% but it should not be done often enough to be a problem
            NodeAddr = case lists:keyfind(Node, 2, maps:to_list(State#st.nodes)) of
                           false ->
                               [];
                           {Addr, _Client} ->
                               [Addr]
                       end,
            {noreply, start_periodic_slot_info_request(NodeAddr, State)};
        false  ->
            {noreply, State}
    end.

handle_info(Msg = {connection_status, {Pid, Addr, _Id}, Status}, State0) ->
    State = case maps:find(Addr, State0#st.nodes) of
                {ok, Pid} ->
                    %% Client pid unchanged.
                    State0;
                {ok, _OldPid} ->
                    %% New client pid for this address. It may have been
                    %% restarted by the client supervisor.
                    State0#st{nodes = (State0#st.nodes)#{Addr => Pid}};
                error ->
                    %% Node not part of the cluster and was already removed.
                    State0
            end,
    IsMaster = sets:is_element(Addr, State#st.masters),
    ered_info_msg:connection_status(Msg, IsMaster, State#st.info_pid),
    State1 = case Status of
                 {connection_down, {Reason, _}} when Reason =:= socket_closed;
                                                     Reason =:= connect_error ->
                     %% Avoid triggering the alarm for a socket closed by the
                     %% peer. The cluster will be marked down on the node down
                     %% timeout.
                     Reconnecting = sets:add_element(Addr, State#st.reconnecting),
                     NewState = State#st{reconnecting = Reconnecting},
                     case (sets:is_element(Addr, State#st.masters) andalso
                           sets:is_element(Addr, State#st.up) andalso
                           not sets:is_element(Addr, State#st.reconnecting)) of
                         true ->
                             %% Update the slotmap now, just in case the node
                             %% which is failing is no longer a master, so we
                             %% don't need to signal 'cluster_not_ok' if we can
                             %% avoid it.
                             start_periodic_slot_info_request(NewState);
                         false ->
                             NewState
                     end;
                 {connection_down,_} ->
                     State#st{up = sets:del_element(Addr, State#st.up),
                              pending = sets:del_element(Addr, State#st.pending),
                              reconnecting = sets:del_element(Addr, State#st.reconnecting)};
                 connection_up ->
                     State#st{up = sets:add_element(Addr, State#st.up),
                              pending = sets:del_element(Addr, State#st.pending),
                              reconnecting = sets:del_element(Addr, State#st.reconnecting)};
                 node_deactivated ->
                     %% A deactivated node is still pending or up, but it might be
                     %% removed later by the close_wait timer.
                     State;
                 queue_full ->
                     State#st{queue_full = sets:add_element(Addr, State#st.queue_full)};
                 queue_ok ->
                     State#st{queue_full = sets:del_element(Addr, State#st.queue_full)}
             end,
    case check_cluster_status(State1) of
        ok ->
            %% Do not set the cluster state to OK yet. Wait for a slot info message.
            %% The slot info message will set the cluster state to OK if the map and
            %% connections are OK. This is to avoid to send the cluster OK info message
            %% too early if there are slot map updates in addition to connection errors.
            {noreply, State1};
        ClusterStatus ->
            {noreply, update_cluster_state(ClusterStatus, State1)}
    end;

handle_info({slot_info, Version, Response, FromAddr}, State) ->
    case Response of
        _ when Version < State#st.slot_map_version ->
            %% got a response for a request triggered for an old version of the slot map, ignore
            {noreply, State};
        {error, _} ->
            %% client error, i.e queue full or socket error or similar, ignore. New request will be sent periodically
            {noreply, State};
        {ok, {error, Error}} ->
            %% error sent from redis
            ered_info_msg:cluster_slots_error_response(Error, FromAddr, State#st.info_pid),
            {noreply, State};
        {ok, []} ->
            %% Empty slotmap. Maybe the node has been CLUSTER RESET.
            ered_info_msg:cluster_slots_error_response(empty, FromAddr, State#st.info_pid),
            {noreply, State};
        {ok, ClusterSlotsReply} ->
            NewMap = ered_lib:slotmap_sort(ClusterSlotsReply),
            case NewMap == State#st.slot_map of
                true ->
                    {noreply, update_cluster_state(State)};
                false ->
                    Nodes = ered_lib:slotmap_all_nodes(NewMap),
                    MasterNodes = new_set(ered_lib:slotmap_master_nodes(NewMap)),

                    %% Open new clients or reactivate any not yet stopped.
                    State1 = start_clients(Nodes, State),

                    %% Remove nodes if they are not in the new map.
                    Remove = maps:keys(maps:without(Nodes, State1#st.nodes)),

                    %% Deactivate the clients, so they can fail queued and new
                    %% commands immediately.
                    [ered_client:deactivate(maps:get(Addr, State1#st.nodes)) || Addr <- Remove],

                    %% Stopping the clients is delayed to give time to update
                    %% slot map and to handle any messages in transit. If the
                    %% node comes back to the cluster soon enough, we can
                    %% reactivate these clients if they're not yet stopped.
                    TimerRef = erlang:start_timer(State1#st.close_wait, self(), {close_clients, Remove}),
                    NewClosing = maps:merge(maps:from_list([{Addr, TimerRef} || Addr <- Remove]),
                                            State1#st.closing),

                    ered_info_msg:slot_map_updated(ClusterSlotsReply, Version + 1,
                                                   FromAddr, State1#st.info_pid),

                    cancel_convergence_check(State1),
                    State2 = State1#st{slot_map_version = Version + 1,
                                       slot_map = NewMap,
                                       convergence_check = nok,
                                       masters = MasterNodes,
                                       closing = NewClosing},
                    {noreply, update_cluster_state(State2)}
            end
    end;

handle_info({converged, Result, FromAddr, Version},
            State = #st{convergence_check = {ongoing, Pending, Timeout},
                        slot_map_version = Version}) ->
    case Result of
        true ->
            Pending1 = sets:del_element(FromAddr, Pending),
            case sets:is_empty(Pending1) of
                true ->
                    cancel_convergence_check(State),
                    State1 = State#st{convergence_check = ok},
                    {noreply, update_cluster_state(State1)};
                false ->
                    State1 = State#st{convergence_check = {ongoing, Pending1, Timeout}},
                    {noreply, update_cluster_state(State1)}
            end;
        false ->
            cancel_convergence_check(State),
            State1 = State#st{convergence_check = nok},
            {noreply, update_cluster_state(State1)}
    end;

handle_info({timeout, TimerRef, {time_to_update_slots,PreferredNodes}}, State) ->
    case State#st.slot_timer_ref of
        TimerRef when State#st.cluster_state == nok ->
            {noreply, start_periodic_slot_info_request(PreferredNodes,
                                                       State#st{slot_timer_ref = none})};
        TimerRef ->
            {noreply, State#st{slot_timer_ref = none}};
        _ ->
            {noreply, State}
    end;

handle_info({timeout, TimerRef, start_convergence_check},
            State = #st{convergence_check = {scheduled, TimerRef}}) ->
    {noreply, start_convergence_check(State)};

handle_info({timeout, TimerRef, cancel_convergence_check},
            State = #st{convergence_check = {scheduled, TimerRef}}) ->
    cancel_convergence_check(State),
    State1 = State#st{convergence_check = nok},
    {noreply, update_cluster_state(State1)};

handle_info({timeout, TimerRef, {close_clients, Remove}}, State) ->
    %% make sure they are still closing and mapped to this Timer
    ToCloseNow = [Addr ||
                     {Addr, Tref} <- maps:to_list(maps:with(Remove, State#st.closing)),
                     Tref == TimerRef],
    Clients = maps:with(ToCloseNow, State#st.nodes),
    [ered_client_sup:stop_client(State#st.client_sup, Client)
     || Client <- maps:keys(Clients)],
    %% remove from nodes and closing map
    {noreply, State#st{nodes = maps:without(ToCloseNow, State#st.nodes),
                       up = sets:subtract(State#st.up, new_set(ToCloseNow)),
                       closing = maps:without(ToCloseNow, State#st.closing)}};

handle_info(_Ignored, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    [ered_client_sup:stop_client(State#st.client_sup, Pid)
     || Pid <- maps:keys(State#st.nodes)],
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-if(?OTP_RELEASE >= 24).
new_set(List) ->
    sets:from_list(List, [{version, 2}]).
-else.
new_set(List) ->
    sets:from_list(List).
-endif.

check_cluster_status(State) ->
    case is_slot_map_ok(State) of
        ok ->
            NonPendingMasters = sets:subtract(State#st.masters, State#st.pending),
            case sets:is_subset(NonPendingMasters, State#st.up) of
                false ->
                    master_down;
                true ->
                    case sets:is_disjoint(State#st.masters, State#st.queue_full) of
                        false ->
                            master_queue_full;
                        true ->
                            case sets:is_disjoint(State#st.masters, State#st.pending) of
                                false ->
                                    pending;
                                true ->
                                    ok
                            end
                    end
            end;
        Reason ->
            Reason
    end.

update_cluster_state(State) ->
    update_cluster_state(check_cluster_status(State), State).

%% Update the cluster state and make sure that the periodic slot map is always
%% scheduled while we're in cluster_not_ok state.
update_cluster_state(ClusterStatus, State) ->
    case {ClusterStatus, State#st.cluster_state} of
        {ok, nok} when State#st.convergence_check =:= ok ->
            ered_info_msg:cluster_ok(State#st.info_pid),
            State1 = stop_periodic_slot_info_request(State),
            State1#st{cluster_state = ok};
        {ok, nok} ->
            State1 = stop_periodic_slot_info_request(State),
            case State1#st.convergence_check of
                {ongoing, _, _} ->
                    State1;
                _Otherwise ->
                    start_convergence_check(State1)
            end;
        {ok, ok} when State#st.convergence_check =:= nok ->
            State1 = stop_periodic_slot_info_request(State),
            schedule_convergence_check(State1);
        {ok, ok} ->
            %% Convergence check is ok or scheduled or ongoing.
            stop_periodic_slot_info_request(State);
        {pending, _} ->
            State;
        {_, ok} ->
            ered_info_msg:cluster_nok(ClusterStatus, State#st.info_pid),
            State1 = start_periodic_slot_info_request(State),
            State1#st{cluster_state = nok};
        {_, nok} ->
            start_periodic_slot_info_request(State)
    end.

start_periodic_slot_info_request(State) ->
    %% If we need to update the slot map due to a failover, it is likely that a
    %% replica of a failing master is located on a different machine
    %% (anti-affinity) and thus less likely to have crashed along with its
    %% master than other nodes.
    PreferredNodes = replicas_of_unavailable_masters(State),
    start_periodic_slot_info_request(PreferredNodes, State).

start_periodic_slot_info_request(PreferredNodes, State) ->
    case State#st.slot_timer_ref of
        none ->
            case pick_node(PreferredNodes, State) of
                none ->
                    %% All nodes are unavailable. Connect to the init nodes to
                    %% see if they are available. If they are hostnames that map
                    %% to IP addresses and all IP addresses of the cluster have
                    %% changed, then this helps us rediscover the cluster.
                    State1 = start_clients(State#st.initial_nodes, State),
                    start_update_slots_timer([], State1);
                Node ->
                    send_slot_info_request(Node, State),
                    start_update_slots_timer(lists:delete(Node, PreferredNodes), State)
            end;
        _Else ->
            State
    end.

start_update_slots_timer(PreferredNodes, State) ->
    Tref = erlang:start_timer(
             State#st.update_slot_wait,
             self(),
             {time_to_update_slots, PreferredNodes}),
    State#st{slot_timer_ref = Tref}.

stop_periodic_slot_info_request(State) ->
    case State#st.slot_timer_ref of
        none ->
            State;
        Tref ->
            erlang:cancel_timer(Tref),
            State#st{slot_timer_ref = none}
    end.

send_slot_info_request(Addr, State) ->
    Node = maps:get(Addr, State#st.nodes),
    Pid = self(),
    Cb = fun(Answer) -> Pid ! {slot_info, State#st.slot_map_version, Answer, Addr} end,
    ered_client:command_async(Node, [<<"CLUSTER">>, <<"SLOTS">>], Cb).

%% Schedules a check that all master nodes report identical slot maps. Used
%% after a slot map change when the cluster state is already 'cluster_ok'.
schedule_convergence_check(State = #st{convergence_check_delay = 0}) ->
    %% Scheduling disabled. Mark convergence as being ok.
    update_cluster_state(State#st{convergence_check = ok});
schedule_convergence_check(State) ->
    cancel_convergence_check(State),
    TimerRef = erlang:start_timer(State#st.convergence_check_delay,
                                  self(), start_convergence_check),
    State#st{convergence_check = {scheduled, TimerRef}}.

%% Starts a check that all master nodes report identical slot maps.
start_convergence_check(State = #st{convergence_check_timeout = 0}) ->
    %% Check disabled. Mark convergence as being ok.
    update_cluster_state(State#st{convergence_check = ok});
start_convergence_check(State) ->
    cancel_convergence_check(State),
    AddrSet = State#st.masters,
    ClusterPid = self(),
    Cmd = [<<"CLUSTER">>, <<"SLOTS">>],
    Version = State#st.slot_map_version,
    Expected = ered_lib:slotmap_master_slots(State#st.slot_map),
    lists:foreach(fun (Addr) ->
                          ClientPid = maps:get(Addr, State#st.nodes),
                          Cb = fun ({ok, Reply}) ->
                                       IsMatch = ered_lib:slotmap_master_slots(Reply) =:= Expected,
                                       ClusterPid ! {converged, IsMatch, Addr, Version};
                                   (_) ->
                                       ignore
                               end,
                          ered_client:command_async(ClientPid, Cmd, Cb)
                  end,
                  sets:to_list(AddrSet)),
    TimerRef = erlang:start_timer(State#st.convergence_check_timeout,
                                  ClusterPid, cancel_convergence_check),
    State#st{convergence_check = {ongoing, AddrSet, TimerRef}}.

cancel_convergence_check(#st{convergence_check = {scheduled, TimerRef}}) ->
    erlang:cancel_timer(TimerRef, [{async, true}]);
cancel_convergence_check(#st{convergence_check = {ongoing, _, TimerRef}}) ->
    erlang:cancel_timer(TimerRef, [{async, true}]);
cancel_convergence_check(_State) ->
    ok.

%% Pick a random available node, preferring the ones in PreferredNodes if any of
%% them is available.
%%
%% Random is useful, since we may send multiple async CLUSTER SLOTS before we
%% get a reply for the first one, so we don't want the same node over and over.
pick_node(PreferredNodes, State) ->
    case pick_available_node(shuffle(PreferredNodes), State) of
        none ->
            %% No preferred node available. Pick one from the 'up' set.
            pick_available_node(shuffle(sets:to_list(State#st.up)), State);
        Addr ->
            Addr
    end.

shuffle(List) ->
    [Y || {_, Y} <- lists:sort([{rand:uniform(16384), X} || X <- List])].

%% Pick node that is up and not queue full.
pick_available_node([Addr|Addrs], State) ->
    case node_is_available(Addr, State) of
        true ->
            Addr;
        false ->
            pick_available_node(Addrs, State)
    end;
pick_available_node([], _State) ->
    none.

node_is_available(Addr, State) ->
    sets:is_element(Addr, State#st.up) andalso
        not sets:is_element(Addr, State#st.queue_full) andalso
        not sets:is_element(Addr, State#st.reconnecting) andalso
        not maps:is_key(Addr, State#st.closing).

-spec replicas_of_unavailable_masters(#st{}) -> [addr()].
replicas_of_unavailable_masters(State) ->
    DownMasters = sets:subtract(State#st.masters,
                                sets:subtract(State#st.up,
                                              State#st.reconnecting)),
    case sets:is_empty(DownMasters) of
        true ->
            [];
        false ->
            ered_lib:slotmap_replicas_of(DownMasters, State#st.slot_map)
    end.

is_slot_map_ok(State) ->
    case all_slots_covered(State) of
        false ->
            not_all_slots_covered;
        true ->
            case check_replica_count(State) of
                false ->
                    too_few_replicas;
                true ->
                    ok
            end
    end.

all_slots_covered(State) ->
    %% check so that the slot map covers all slots. the slot map is sorted so it
    %% should be a continuous range
    R = lists:foldl(fun([Start, Stop| _Rest], Expect) ->
                            case Start of
                                Expect ->
                                    Stop+1;
                                _Else ->
                                    false
                            end
                    end,
                    0,
                    State#st.slot_map),
    %% check so last slot is ok
    R == 16384.

check_replica_count(#st{min_replicas = 0}) ->
    true;
check_replica_count(State) ->
    lists:all(fun([_Start, _Stop, _Master | Replicas]) ->
                      length(Replicas) >= State#st.min_replicas
              end,
              State#st.slot_map).

start_client(Addr, State) ->
    {Host, Port} = Addr,
    Opts = [{info_pid, self()}, {use_cluster_id, true}] ++ State#st.client_opts,
    {ok, Pid} = ered_client_sup:start_client(State#st.client_sup, Host, Port, Opts),
    Pid.

start_clients(Addrs, State) ->
    %% open clients to new nodes not seen before
    %% cancel closing for requested clients
    {NewNodes, NewClosing} =
        lists:foldl(fun (Addr, {Nodes, Closing}) ->
                            case maps:find(Addr, Nodes) of
                                error ->
                                    Pid = start_client(Addr, State),
                                    {Nodes#{Addr => Pid}, Closing};
                                {ok, Pid} ->
                                    ered_client:reactivate(Pid),
                                    {Nodes, maps:remove(Addr, Closing)}
                            end
                    end,
                    {State#st.nodes, State#st.closing},
                    Addrs),

    State#st{nodes = NewNodes,
             pending = sets:union(State#st.pending,
                                  sets:subtract(new_set(maps:keys(NewNodes)),
                                                State#st.up)),
             closing = NewClosing}.
