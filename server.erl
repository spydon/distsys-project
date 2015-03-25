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
    InitialLocks = [{a, {readlock,  []}},
                    {b, {readlock,  []}},
                    {c, {readlock,  []}},
                    {d, {readlock,  []}},
                    {a, {writelock, []}},
                    {b, {writelock, []}},
                    {c, {writelock, []}},
                    {d, {writelock, []}}],
    StorePid = spawn_link(fun() -> store_loop(InitialVals, InitialLocks, [], self()) end),
    server_loop([], StorePid, []).
%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% - The server maintains a list of all connected clients and a store holding

%% the values of the global variable a, b, c and d 
server_loop(ClientList, StorePid, TransState) ->
    io:format("Transaction State: ~p.~n", [TransState]),
    receive
        {login, MM, Client} -> 
            MM ! {ok, self()},
            io:format("New client has joined the server:~p.~n", [Client]),
            StorePid ! {print, self()},
            server_loop([Client | ClientList], StorePid, TransState);
        {close, Client} -> 
            io:format("Client~p has left the server.~n", [Client]),
            StorePid ! {print, self()},
            server_loop(lists:delete(Client, ClientList), StorePid, TransState);
        {request, Client} -> 
            Client ! {proceed, self()},
            server_loop(ClientList, StorePid, [{Client, []} | TransState]);
        {confirm, Client, NumActions} -> 
            io:format("get_actions: ~p .~n", [length(get_actions(Client, TransState))]),
            case length(get_actions(Client, TransState)) of
                NumActions -> 
                    StorePid ! {actions, self()},
                    Client ! {committed, self()},
                    io:format("All actions received.~n");
                _ ->
                    Client ! {abort, self()},
                    io:format("Not all actions received.~n")
            end,
            server_loop(ClientList, StorePid, delete_actions(Client, TransState));
        {abort, Client} ->
            io:format("Transaction for ~p aborted.~n", [Client]),
            Client ! {abort, self()},
            server_loop(ClientList, StorePid, delete_actions(Client, TransState));
        {action, Client, Act, Num} ->
            io:format("Received~p, number ~p, from client~p.~n", [Act, Num, Client]),
            case get_actions(Client, TransState) of
                [] -> 
                    case Num of
                        1 ->
                            case Act of
                                {read, Prop} -> StorePid ! {read, Prop, Client};
                                {write, Prop, Value} -> StorePid ! {write, Prop, Value, Client}
                            end,
                            server_loop(ClientList, StorePid, add_action(Client, Act, Num, TransState));
                        _ ->
                            io:format("Lost msg for ~p detected.~n", [Client]),
                            self() ! {abort, Client}
                    end;
                [{_, Prev} | _TL] ->
                    case Prev+1 of
                        Num ->
                            server_loop(ClientList, StorePid, add_action(Client, Act, Num, TransState));
                        _ ->
                            io:format("Lost msg for ~p detected.~n", [Client]),
                            self() ! {abort, Client}
                    end
            end,
            case ClientList of
                [] -> exit(normal);
                _ -> server_loop(ClientList, StorePid, TransState)
            end
    end.

%% - The values are maintained here
store_loop(Database, Locks, NotConfirmed, ServerPid) ->
    receive
        {print, _Pid} ->
            io:format("Database status:~n~p.~n", [Database]),
            store_loop(Database, Locks, NotConfirmed, ServerPid);
        {read, Prop, Pid} ->
            {Success, NewLocks} = lock_handler({Prop, readlock}, Pid, Locks),
            case Success of
                true ->
                    Pid ! read(Prop, Database),
                    store_loop(Database, NewLocks, [{read, Prop, Pid} | NotConfirmed], ServerPid);
                false ->
                    self() ! {abort, Pid}
            end;
        {write, Prop, Value, Pid} ->
            {Success, NewLocks} = lock_handler({Prop, writelock}, Pid, Locks),
            case Success of
                true ->
                    OldValue = read(Prop, Database),
                    store_loop(write(Prop, Value, Database), NewLocks, [{write, Prop, OldValue, Pid} | NotConfirmed], ServerPid);
                false ->
                    self() ! {abort, Pid}
            end;
        {abort, Pid} ->
            {AbortActions, FilteredActions} = lists:splitwith(fun({_Type, _Prop, Pid}) -> true;
                                                                 (_) -> false end,
                                                              NotConfirmed),
            ServerPid ! {abort, Pid},
            RestoredDatabase = undo_actions(Pid, AbortActions, Database),
            UnlockedLocks = unlock_all(Pid, Locks),
            store_loop(RestoredDatabase, UnlockedLocks, FilteredActions, ServerPid);
        {committed, Pid} ->
            Pid ! {committed, self()},
            store_loop(Database, unlock_all(Pid, Locks), lists:filter(fun({_Type, _Prop, Pid}) -> false;
                                                                         (_) -> true end,
                                                                      NotConfirmed), ServerPid)
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
    lists:keyfind(Prop, 1, Database).

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
            [{Prop, readlock, Pids}] = lists:filter(fun({Prop, readlock, _PidArgs}) -> true;
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
                        {_, _} ->
                            {false, Locks}
                    end
            end;
        {Prop, writelock} ->
            [{Prop, readlock, [WritePid]}] = lists:filter(fun({Prop, writelock, _PidArgs}) -> true;
                                                             (_) -> false end,
                                                          Locks),
            case {WritePid == Pid, WritePid == []} of
                {true, _} ->
                    {true, Locks};
                {_, true} ->
                    {true, [{Prop, writelock, [Pid]} | lists:delete({Prop, writelock, []}, locks)]}
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
