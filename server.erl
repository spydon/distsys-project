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
    StorePid = spawn_link(fun() -> store_loop(InitialVals, InitialLocks) end),
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
        {action, Client, Act, Num} ->
            io:format("Received~p, number ~p, from client~p.~n", [Act, Num, Client]),
            case get_actions(Client, TransState) of
                [] -> 
                    case Num of 
                        1 -> 
                            server_loop(ClientList, StorePid, add_action(Client, Act, Num, TransState));
                        _ ->
                            Client ! {abort, self()},
                            io:format("Lost msg detected.~n"),
                            server_loop(ClientList, StorePid, delete_actions(Client, TransState))
                    end;
                [{_, Prev} | _TL] ->
                    case Prev +1 of
                        Num ->
                            server_loop(ClientList, StorePid, add_action(Client, Act, Num, TransState));
                        _ ->
                            Client ! {abort, self()},
                            io:format("Lost msg detected.~n"),
                            server_loop(ClientList, StorePid, delete_actions(Client, TransState))
                    end
            end,
            case ClientList of
                [] -> exit(normal);
                _ -> server_loop(ClientList, StorePid, TransState)
            end
    end.

%% - The logic around executing the transaction is done here
%%   TODO: How does one operation of a transaction look like?
transaction([], _StorePid) ->
    something;
transaction(Transaction, StorePid) ->
    something.

%% - The values are maintained here
store_loop(Database, Locks) ->
    receive
        {print, _Pid} ->
            io:format("Database status:~n~p.~n", [Database]),
            store_loop(Database, Locks);
        {transaction, Transaction, Pid} -> % TODO: Probably shouldn't have this one as problem gets too simple?
            LocksNeeded = lock_check(Transaction),
            case request_locks(LocksNeeded, Pid, Locks) of
                {true, ModLocks} ->
                    Pid ! transaction(Transaction, self());
                _ ->
                    %% Abort
                    Pid ! abort
            end,
            store_loop(Database, unlock_all(Pid, Locks));
        {read, Prop, Pid} ->
            Pid ! read(Prop, Database),
            store_loop(Database, Locks);
        {write, Prop, Value, _Pid} ->
            store_loop(write(Prop, Value, Database), Locks);
        {lock, Prop, LockType, Pid} -> % TODO: Will not work as Lock() is rewritten
            store_loop(Database, lock({Prop, LockType}, Pid, Locks));
        {unlock, Prop, LockType, _Pid} -> % TODO: Will not work as Unlock() is rewritten
            store_loop(Database, unlock({Prop, LockType}, Locks))
    end.

%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%% DATA MODIFICATION METHODS %%%%%%%%%%%%%%%%%%%%%%%%%%

%% - Checks whether all locks can be obtained or not
%%   TODO: Should probably call store_loop to lock and unlock as problem is
%%   trivial otherwise
request_locks(LocksNeeded, ClientPid, Locks) ->
    request_locks(LocksNeeded, ClientPid, Locks, true).
request_locks([], _ClientPid, Locks, Result) ->
    {Result, Locks};
request_locks([Lock | TL], ClientPid, Locks, Result) ->
    {Modified, ModLocks} = lock(Lock, ClientPid, Locks),
    request_locks(TL, ClientPid, ModLocks, Result and Modified).

%% - Checks which locks that are required for Transaction
lock_check([]) ->
    [];
lock_check([{read, Prop} | TL]) ->
    [{Prop, readlock} | lock_check(TL)];
lock_check([{write, Prop, _Value} | TL]) ->
    [{Prop, writelock} | lock_check(TL)].

%% - Returns the Database with the tuple containing the Prop key
%%   set to {Prop, Value}
write(Prop, Value, Database) ->
    lists:keyreplace(Prop, 1, Database, {Prop, Value}).

%% - Returns the Tuple in Database with the Prop key
read(Prop, Database) ->
    lists:keyfind(Prop, 1, Database).

%% - Returns the Locks list with true and the Lock tuple set to locked 
%%   operation succeeded and false and the old Lock tuple if the operation
%%   failed
lock(Lock, Pid, Locks) ->
    Modified = semaphore(Lock, Pid, Locks),
    {Modified == Locks, Modified}.

%% - Returns the Locks list with the Lock tuple set to unlocked
unlock(Lock, Locks) -> semaphore(Lock, [], Locks).

%% - Unlock all locks for a certain Pid
unlock_all(_Pid, []) ->
    [];
unlock_all(Pid, [{Prop, LockType, Pid} | TL]) ->
    [{Prop, LockType, []} | unlock_all(Pid, TL)].

%% - Manipulation of lock tuples, only to be used by the
%%   lock and unlock functions
semaphore(_Lock, _Pid, []) ->
    [];
semaphore(Lock = {Prop, readlock}, Pid, [{Prop, readlock, []} | TL]) ->
    [{Prop, readlock, Pid} | semaphore(Lock, Pid, TL)];
semaphore(Lock = {Prop, writelock}, Pid, [{Prop, LockType, []} | TL]) ->
    [{Prop, LockType, Pid} | semaphore(Lock, Pid, TL)];
semaphore(Lock, Pid, [HD | TL]) ->
    [HD | semaphore(Lock, Pid, TL)].

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
