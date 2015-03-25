%% - Server module
%% - The server module creates a parallel registered process by spawning a process which 
%% evaluates initialize(). 
%% The function initialize() does the following: 
%%      1/ It makes the current process as a system process in order to trap exit.
%%      2/ It creates a process evaluating the store_loop() function.
%%      4/ It executes the server_loop() function.

-module(server).

-export([start/0]).

%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
start() ->
    register(transaction_server,
             spawn(fun() ->
                       process_flag(trap_exit, true),
                       Val = (catch initialize()),
                       io:format("Server terminated with: ~p~n", [Val])
                   end)).

initialize() ->
    process_flag(trap_exit, true),
    %% All variables set to 0
    InitialVals = [{a, 0},
                   {b, 0},
                   {c, 0},
                   {d, 0}],
    %% All locks set to unlocked (no pid)
    InitialLocks = [{a, readlock,  []},
                    {b, readlock,  []},
                    {c, readlock,  []},
                    {d, readlock,  []},
                    {a, writelock, []},
                    {b, writelock, []},
                    {c, writelock, []},
                    {d, writelock, []}],
    StorePid = spawn_link(fun() -> store_loop(InitialVals, InitialLocks, [], sets:new(), self()) end),
    server_loop([], StorePid, [], sets:new()).
%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% - The server maintains a list of all connected clients and a store holding

%% the values of the global variable a, b, c and d 
server_loop(ClientList, StorePid, TransState, AbortSet) ->
    receive
        {login, MM, Client} -> 
            MM ! {ok, self()},
            io:format("~p New client has joined the server.~n", [Client]),
            StorePid ! {print, self()},
            server_loop([Client | ClientList], StorePid, TransState, AbortSet);
        {close, Client} -> 
            io:format("~p Client has left the server.~n", [Client]),
            StorePid ! {print, self()},
            server_loop(lists:delete(Client, ClientList), StorePid, TransState, AbortSet);
        {request, Client} -> 
            Client ! {proceed, self()},
            server_loop(ClientList, StorePid, [{Client, []} | TransState], AbortSet);
        {confirm, Client, NumActions} ->
            case {sets:is_element(Client, AbortSet), length(get_actions(Client, TransState))} of
                {true, _} ->
                    Client ! {abort, self()},
                    io:format("~p Transaction could not receive all locks needed~n", [Client]);
                {_, NumActions} -> 
                    StorePid ! {committed, Client},
                    Client ! {committed, self()},
                    io:format("~p All actions received.~n", [Client]);
                _ ->
                    Client ! {abort, self()},
                    io:format("~p Not all actions received.~n", [Client])
            end,
            server_loop(ClientList, StorePid, delete_actions(Client, TransState), sets:del_element(Client, AbortSet));
        {abort, Client, SenderPid} ->
            io:format("~p transaction aborted.~n", [Client]),
            case SenderPid of
                StorePid ->
                    true;
                _ ->
                    StorePid ! {abort, Client, self()}
            end,
            io:format("~nTransaction State:~n~p.~n~n", [TransState]),
            server_loop(ClientList, StorePid, delete_actions(Client, TransState), sets:add_element(Client, AbortSet));
        {action, Client, Act, Num} ->
            case {sets:is_element(Client, AbortSet), get_previous(get_actions(Client, TransState))+1} of
                {true, _} ->
                    server_loop(ClientList, StorePid, TransState, AbortSet);
                {_, Num} ->
                    io:format("~p Received ~p, msg number ~p.~n", [Client, Act, Num]),
                    case Act of
                        {read, Prop} -> StorePid ! {read, Prop, Client};
                        {write, Prop, Value} -> StorePid ! {write, Prop, Value, Client}
                    end,
                    server_loop(ClientList, StorePid, add_action(Client, Act, Num, TransState), AbortSet);
                _ ->
                    io:format("~p Lost msg detected.~n", [Client]),
                    self() ! {abort, Client, self()}
            end,
            case ClientList of
                [] -> exit(normal);
                _ -> server_loop(ClientList, StorePid, TransState, AbortSet)
            end
    end.

get_previous([]) -> 0;
get_previous([{_, Prev} | _TL]) -> Prev.

%% - The values are maintained here
store_loop(Database, Locks, NotConfirmed, AbortSet, ServerPid) ->
    receive
        {print, _Pid} ->
            io:format("~nDatabase status:~n~p.~n", [Database]),
            store_loop(Database, Locks, NotConfirmed, AbortSet, ServerPid);
        {read, Prop, Pid} ->
            case sets:is_element(Pid, AbortSet) of
                true ->
                    % Silently skip part of an already aborted transaction
                    store_loop(Database, Locks, NotConfirmed, AbortSet, ServerPid);
                false ->
                    io:format("~p tries to read: ~p.~n", [Pid, Prop]),
                    {Success, NewLocks} = lock_handler({Prop, readlock}, Pid, Locks),
                    io:format("~nLock state:~n~p~n", [NewLocks]),
                    case Success of
                        true ->
                            io:format("~p read ~p from ~p.~n", [Pid, read(Prop, Database), Prop]),
                            store_loop(Database, NewLocks, [{read, Prop, Pid} | NotConfirmed], AbortSet, ServerPid);
                        false ->
                            io:format("~p failed to read ~p, aborting~n", [Pid, Prop]),
                            self() ! {abort, Pid, self()},
                            store_loop(Database, NewLocks, NotConfirmed, sets:add_element(Pid, AbortSet), ServerPid)
                    end
            end;
        {write, Prop, Value, Pid} ->
            case sets:is_element(Pid, AbortSet) of
                true ->
                    % Silently abort part of already aborted transaction
                    store_loop(Database, Locks, NotConfirmed, AbortSet, ServerPid);
                false ->
                    io:format("~p tries to write ~p to ~p.~n", [Pid, Value, Prop]),
                    {Success, NewLocks} = lock_handler({Prop, writelock}, Pid, Locks),
                    io:format("~nLock state:~n~p~n", [NewLocks]),
                    case Success of
                        true ->
                            io:format("~p successfully wrote ~p to ~p.~n", [Pid, Value, Prop]),
                            OldValue = read(Prop, Database),
                            store_loop(write(Prop, Value, Database), NewLocks, [{write, Prop, OldValue, Pid} | NotConfirmed], AbortSet, ServerPid);
                        false ->
                            io:format("~p failed to write to ~p, aborting~n", [Pid, Prop]),
                            self() ! {abort, Pid, self()},
                            store_loop(Database, NewLocks, NotConfirmed, sets:add_element(Pid, AbortSet), ServerPid)
                    end
            end;
        {abort, Pid, SenderPid} ->
            io:format("~p aborted and cleaned up.~n", [Pid]),
            {AbortActions, FilteredActions} = lists:splitwith(fun({_Type, _Prop, PidArg}) -> PidArg == Pid;
                                                                 ({_Type, _Prop, _OldValue, PidArg}) -> PidArg == Pid end,
                                                              NotConfirmed),
            case SenderPid of
                ServerPid ->
                    true;
                _ ->
                    ServerPid ! {abort, Pid, self()}
            end,
            RestoredDatabase = undo_actions(Pid, AbortActions, Database),
            UnlockedLocks = unlock_all(Pid, Locks),
            store_loop(RestoredDatabase, UnlockedLocks, FilteredActions, sets:add_element(Pid, AbortSet), ServerPid);
        {committed, Pid} ->
            io:format("~nDatabase status:~n~p.~n~n", [Database]),
            io:format("~p transaction committed.~n", [Pid]),
            store_loop(Database, unlock_all(Pid, Locks), lists:filter(fun({_Type, _Prop, PidArg}) -> PidArg /= Pid;
                                                                         ({_Type, _Prop, _OldValue, PidArg}) -> PidArg /= Pid end,
                                                                      NotConfirmed), AbortSet, ServerPid)
    end.

%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%% DATA MODIFICATION METHODS %%%%%%%%%%%%%%%%%%%%%%%%%%
undo_actions(_Pid, [], Database) ->
    Database;
undo_actions(Pid, [{read, _Prop, _Pid} | TL], Database) ->
    undo_actions(Pid, TL, Database);
undo_actions(Pid, [{write, Prop, OldValue, Pid} | TL], Database) ->
    undo_actions(Pid, TL, write(Prop, OldValue, Database)).

%% - Returns the Database with the tuple containing the Prop key
%%   set to {Prop, Value}
write(Prop, Value, Database) ->
    lists:keyreplace(Prop, 1, Database, {Prop, Value}).

%% - Returns the Tuple in Database with the Prop key
read(Prop, Database) ->
    element(2, lists:keyfind(Prop, 1, Database)).

%% - Unlock all locks for a certain Pid
unlock_all(_Pid, []) ->
    [];
unlock_all(Pid, [{Prop, LockType, Pids} | TL]) ->
    [{Prop, LockType, lists:delete(Pid, Pids)} | unlock_all(Pid, TL)].

%% - Manipulation of lock tuples, only to be used by the
%%   lock and unlock functions
lock_handler(Lock, Pid, Locks) ->
    case Lock of
        {Prop, readlock} ->
            io:format("~p tries to readlock ~p~n", [Pid, Prop]),
            [{Prop, readlock, Pids}] = lists:filter(fun({PropArg, readlock, _PidArgs}) -> PropArg == Prop;
                                                        (_) -> false end,
                                                    Locks),
            case lists:member(Pid, Pids) of
                true ->
                    {true, Locks};
                false ->
                    case {lists:member({Prop, writelock, []}, Locks), lists:member({Prop, writelock, [Pid]}, Locks)} of
                        {true, _} ->
                            {true, [{Prop, readlock, [Pid | Pids]} | lists:delete({Prop, readlock, Pids}, Locks)]};
                        {_, true} ->
                            {true, Locks};
                        _ ->
                            {false, Locks}
                    end
            end;
        {Prop, writelock} ->
            io:format("~p tries to writelock ~p~n", [Pid, Prop]),
            [{Prop, readlock, ReadPids}] = lists:filter(fun({PropArg, readlock, _PidArgs}) -> PropArg == Prop;
                                                        (_) -> false end,
                                                    Locks),
            [{Prop, writelock, WritePid}] = lists:filter(fun({PropArg, writelock, _PidArgs}) -> PropArg == Prop;
                                                             (_) -> false end,
                                                          Locks),
            case {WritePid == [Pid], WritePid == [], ReadPids == [Pid], ReadPids == []} of
                {true, _, _, _} ->
                    {true, Locks};
                {_, true, true, _} ->
                    {true, [{Prop, writelock, [Pid]} | lists:delete({Prop, writelock, []}, Locks)]};
                {_, true, _, true} ->
                    {true, [{Prop, writelock, [Pid]} | lists:delete({Prop, writelock, []}, Locks)]};
                _ ->
                    {false, Locks}
            end
    end.

%% add_action(C,A,O,L) 
%% C = Client
%% A = Action
%% O = A's order in its tranaction
%% L = List of partial transactions received from clients
%% Adds the tuple {A,O} to the list L 
%% Its added to the action list of the tuple belonging to client C 
add_action(_C, _A, _O, []) -> [];
add_action(C, A, O, [{C, Actions} | T]) -> [{C, [{A, O} | Actions]} | T];
add_action(C, A, O, [{H, Actions} | T]) -> [{H, Actions} | add_action(C, A, O, T)].

delete_actions(_C, []) -> [];
delete_actions(C, [{C, _Actions} | T]) -> T;
delete_actions(C, [{H, Actions} | T]) -> [{H, Actions} | delete_actions(C, T)].

get_actions(_C, []) -> [];
get_actions(C, [{C, Actions} | _T]) -> Actions;
get_actions(C, [{_H, _Actions} | T]) -> get_actions(C, T).

%%%%%%%%%%%%%%%%%%%%%%% DATA MODIFICATION METHODS %%%%%%%%%%%%%%%%%%%%%%%%%
