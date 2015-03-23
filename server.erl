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
    server_loop([], StorePid).
%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% - The server maintains a list of all connected clients and a store holding
%% the values of the global variable a, b, c and d
server_loop(ClientList, StorePid) ->
    receive
        {login, MM, Client} ->
            MM ! {ok, self()},
            io:format("New client has joined the server: ~p.~n", [Client]),
            StorePid ! {print, self()},
            server_loop([Client | ClientList], StorePid);
        {close, Client} ->
            io:format("Client~p has left the server.~n", [Client]),
            StorePid ! {print, self()},
            server_loop(lists:delete(Client, ClientList), StorePid);
        {request, Client} ->
            Client ! {proceed, self()},
            server_loop(ClientList, StorePid);
        {confirm, Client} ->
            Client ! {abort, self()},
            server_loop(ClientList, StorePid);
        {action, Client, Act} ->
            io:format("Received ~p from client ~p.~n", [Act, Client]),
            server_loop(ClientList, StorePid)
    after 50000 ->
        case ClientList of
            [] -> exit(normal);
            _ -> server_loop(ClientList, StorePid)
        end
    end.

%% - The values are maintained here
store_loop(Database, Locks) ->
    receive
        {print, _Pid} ->
            io:format("Database status:~n~p.~n",[Database]),
            store_loop(Database, Locks);
        {read, Prop, Pid} ->
            Pid ! read(Prop, Database),
            store_loop(Database, Locks);
        {write, Prop, Value, _Pid} ->
            store_loop(write(Prop, Value, Database), Locks);
        {lock, Prop, LockType, Pid} ->
            store_loop(Database, lock({Prop, LockType}, Pid, Locks));
        {unlock, Prop, LockType, _Pid} ->
            store_loop(Database, unlock({Prop, LockType}, Locks))
    end.

%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%%%%%%%%%%%%%% DATA MODIFICATION METHODS %%%%%%%%%%%%%%%%%%%%%%%%%%

%% - Returns the Database with the tuple containing the Prop key
%%   set to {Prop, Value}
write(Prop, Value, Database) ->
    lists:keyreplace(Prop, 1, Database, {Prop, Value}).

%% - Returns the Tuple in Database with the Prop key
read(Prop, Database) ->
    lists:keyfind(Prop, 1, Database).

%% - Returns the Locks list with the Lock tuple set to locked
lock(Lock, Pid, Locks) -> semaphore(Lock, Pid, Locks).

%% - Returns the Locks list with the Lock tuple set to unlocked
unlock(Lock, Locks) -> semaphore(Lock, [], Locks).

%% - Manipulation of lock tuples
semaphore(_Lock, _Pid, []) -> [];
semaphore(Lock = {Prop, readlock}, Pid, [{Prop, readlock, _Value} | TL]) ->
    [{Prop, readlock, Pid} | lock(Lock, Pid, TL)];
semaphore(Lock = {Prop, writelock}, Pid, [{Prop, LockType, _Value} | TL]) ->
    [{Prop, LockType, Pid} | lock(Lock, Pid, TL)];
semaphore(Lock, Pid, [HD | TL]) ->
    [HD | semaphore(Lock, Pid, TL)].

%%%%%%%%%%%%%%%%%%%%%%% DATA MODIFICATION METHODS %%%%%%%%%%%%%%%%%%%%%%%%%
