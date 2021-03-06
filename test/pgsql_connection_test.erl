-module(pgsql_connection_test).
-include_lib("eunit/include/eunit.hrl").

%%%% CREATE ROLE test LOGIN;
%%%% ALTER USER test WITH SUPERUSER
%%%%
%%%% CREATE DATABASE test WITH OWNER=test;
%%%%

kill_sup(SupPid) ->
    OldTrapExit = process_flag(trap_exit, true),
    exit(SupPid, kill),
    receive {'EXIT', SupPid, _Reason} -> ok after 5000 -> throw({error, timeout}) end,
    process_flag(trap_exit, OldTrapExit).


open_close_test_() ->
    {setup,
    fun() ->
        {ok, Pid} = pgsql_connection_sup:start_link(),
        Pid
    end,
    fun(SupPid) ->
        kill_sup(SupPid)
    end,
    [
        {"Open connection to test database with test account",
        ?_test(begin
            {ok, R} = pgsql_connection:open("test", "test"),
            pgsql_connection:close(R)
        end)},
        {"Open connection to test database with test account, expliciting empty password",
        ?_test(begin
            {ok, R} = pgsql_connection:open("test", "test", ""),
            pgsql_connection:close(R)
        end)},
        {"Open connection to test database with test account, expliciting host",
        ?_test(begin
            {ok, R} = pgsql_connection:open("0.0.0.0", "test", "test", ""),
            pgsql_connection:close(R)
        end)},
        {"Open connection to test database with test account, expliciting host, using IP for host and binaries for account/database/password",
        ?_test(begin
            {ok, R} = pgsql_connection:open({0,0,0,0}, <<"test">>, <<"test">>, <<>>),
            pgsql_connection:close(R)
        end)},
        {"Open connection to test database with test account, expliciting host and options",
        ?_test(begin
            {ok, R} = pgsql_connection:open("0.0.0.0", "test", "test", "", [{application_name, eunit_tests}]),
            pgsql_connection:close(R)
        end)},
        {"Open connection to test database with options as list",
        ?_test(begin
            {ok, R} = pgsql_connection:open([{host, "0.0.0.0"}, {database, "test"}, {user, "test"}, {password, ""}]),
            pgsql_connection:close(R)
        end)},
        {"Bad user returns an error",
        ?_test(begin
            {error, _} = pgsql_connection:open("test", "bad_user")
        end)}
    ]}.

reconnect_proxy_loop() ->
    {ok, LSock} = gen_tcp:listen(35432, [{active, true}, binary, {reuseaddr, true}]),    
    reconnect_proxy_loop0(LSock, undefined, undefined).

reconnect_proxy_loop0(LSock, undefined, undefined) ->
    {ok, CSock} = gen_tcp:accept(LSock),
    {ok, PSock} = gen_tcp:connect({0, 0, 0, 0}, 5432, [{active, true}, binary]),
    reconnect_proxy_loop0(LSock, CSock, PSock);
reconnect_proxy_loop0(LSock, CSock, PSock) ->
    receive
        {TestClient, close} ->
            ok = gen_tcp:close(CSock),
            ok = gen_tcp:close(PSock),
            TestClient ! {self(), closed},
            reconnect_proxy_loop0(LSock, undefined, undefined);
        {_TestClient, close_during_xfer} ->
            receive {tcp, CSock, _} -> ok end,
            ok = gen_tcp:close(CSock),
            ok = gen_tcp:close(PSock),
            reconnect_proxy_loop0(LSock, undefined, undefined);
        {tcp, CSock, Data} ->
            ok = gen_tcp:send(PSock, Data),
            reconnect_proxy_loop0(LSock, CSock, PSock);
        {tcp, PSock, Data} ->
            ok = gen_tcp:send(CSock, Data),
            reconnect_proxy_loop0(LSock, CSock, PSock);
        {tcp_closed, CSock} ->
            ok = gen_tcp:close(PSock),
            reconnect_proxy_loop0(LSock, undefined, undefined);
        {tcp_closed, PSock} ->
            ok = gen_tcp:close(CSock),
            reconnect_proxy_loop0(LSock, undefined, undefined);
        Message ->
            ?debugVal(Message),
            ?assert(false)
    end.

reconnect_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        ProxyPid = spawn_link(fun reconnect_proxy_loop/0),
        {SupPid, ProxyPid}
    end,
    fun({SupPid, ProxyPid}) ->
        unlink(ProxyPid),
        exit(ProxyPid, normal),
        kill_sup(SupPid)
    end,
    fun({_SupPid, ProxyPid}) ->
        [
            {"Reconnect after close",
            ?_test(begin
                {ok, Conn} = pgsql_connection:open([{host, "0.0.0.0"}, {port, 35432}, {database, "test"}, {user, "test"}, {password, ""}, reconnect]),
                ?assertMatch({{select, 1}, [_], [{null}]}, pgsql_connection:simple_query(Conn, "select null")),
                ProxyPid ! {self(), close},
                receive {ProxyPid, closed} -> ok end,
                timer:sleep(100),   % make sure the driver got the tcp closed notice.
                ?assertMatch({{select, 1}, [_], [{null}]}, pgsql_connection:simple_query(Conn, "select null")),
                ?assertMatch({{select, 1}, [_], [{null}]}, pgsql_connection:simple_query(Conn, "select null")),
                ok = pgsql_connection:close(Conn)
            end)},
            {"Socket is closed during transfer, driver returns {error, closed} even with reconnect",
            ?_test(begin
                {ok, Conn} = pgsql_connection:open([{host, "0.0.0.0"}, {port, 35432}, {database, "test"}, {user, "test"}, {password, ""}, reconnect]),
                ?assertMatch({{select, 1}, [_], [{null}]}, pgsql_connection:simple_query(Conn, "select null")),
                ProxyPid ! {self(), close_during_xfer},
                ?assertEqual({error, closed}, pgsql_connection:simple_query(Conn, "select null")),
                ?assertMatch({{select, 1}, [_], [{null}]}, pgsql_connection:simple_query(Conn, "select null")),
                ok = pgsql_connection:close(Conn)
            end)},
            {"Socket is closed during transfer, driver does not return {error, closed} with retry",
            ?_test(begin
                {ok, Conn} = pgsql_connection:open([{host, "0.0.0.0"}, {port, 35432}, {database, "test"}, {user, "test"}, {password, ""}, reconnect]),
                ?assertMatch({{select, 1}, [_], [{null}]}, pgsql_connection:simple_query(Conn, "select null")),
                ProxyPid ! {self(), close_during_xfer},
                ?assertMatch({{select, 1}, [_], [{null}]}, pgsql_connection:simple_query(Conn, "select null", [retry])),
                ok = pgsql_connection:close(Conn)
            end)},
            {"Do not reconnect at all without reconnect",
            ?_test(begin
                {ok, Conn} = pgsql_connection:open([{host, "0.0.0.0"}, {port, 35432}, {database, "test"}, {user, "test"}, {password, ""}, {reconnect, false}]),
                ?assertMatch({{select, 1}, [_], [{null}]}, pgsql_connection:simple_query(Conn, "select null")),
                ProxyPid ! {self(), close},
                receive {ProxyPid, closed} -> ok end,
                timer:sleep(100),   % make sure the driver got the tcp closed notice.
                ?assertEqual({error, closed}, pgsql_connection:simple_query(Conn, "select null")),
                ?assertEqual({error, closed}, pgsql_connection:simple_query(Conn, "select null")),
                ok = pgsql_connection:close(Conn)
            end)}
        ]
    end
    }.

select_null_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        ?_assertEqual({selected, [{null}]}, pgsql_connection:sql_query(Conn, "select null")),
        ?_assertEqual({selected, [{null}]}, pgsql_connection:param_query(Conn, "select null", [])),
        ?_assertMatch({{select, 1}, [_], [{null}]}, pgsql_connection:simple_query(Conn, "select null")),
        ?_assertMatch({{select, 1}, [_], [{null}]}, pgsql_connection:extended_query(Conn, "select null", []))
    ]
    end}.

sql_query_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        {"Create temporary table",
            ?_assertEqual({updated, 1}, pgsql_connection:sql_query(Conn, "create temporary table foo (id integer primary key, some_text text)"))
        },
        {"Insert into",
            ?_assertEqual({updated, 1}, pgsql_connection:sql_query(Conn, "insert into foo (id, some_text) values (1, 'hello')"))
        },
        {"Update",
            ?_assertEqual({updated, 1}, pgsql_connection:sql_query(Conn, "update foo set some_text = 'hello world'"))
        },
        {"Insert into",
            ?_assertEqual({updated, 1}, pgsql_connection:sql_query(Conn, "insert into foo (id, some_text) values (2, 'hello again')"))
        },
        {"Update on matching condition",
            ?_assertEqual({updated, 1}, pgsql_connection:sql_query(Conn, "update foo set some_text = 'hello world' where id = 1"))
        },
        {"Update on non-matching condition",
            ?_assertEqual({updated, 0}, pgsql_connection:sql_query(Conn, "update foo set some_text = 'goodbye, all' where id = 3"))
        },
        {"Select *",
            ?_assertEqual({selected, [{1, <<"hello world">>}, {2, <<"hello again">>}]}, pgsql_connection:sql_query(Conn, "select * from foo order by id asc"))
        },
        {"Select with named columns",
            ?_assertEqual({selected, [{1, <<"hello world">>}, {2, <<"hello again">>}]}, pgsql_connection:sql_query(Conn, "select id as the_id, some_text as the_text from foo order by id asc"))
        },
        {"Select with inverted columns",
            ?_assertEqual({selected, [{<<"hello world">>, 1}, {<<"hello again">>, 2}]}, pgsql_connection:sql_query(Conn, "select some_text, id from foo order by id asc"))
        },
        {"Select with matching condition",
            ?_assertEqual({selected, [{<<"hello again">>}]}, pgsql_connection:sql_query(Conn, "select some_text from foo where id = 2"))
        },
        {"Select with non-matching condition",
            ?_assertEqual({selected, []}, pgsql_connection:sql_query(Conn, "select * from foo where id = 3"))
        }
    ]
    end}.

types_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        {"Create temporary table for the types",
            ?_assertEqual({updated, 1}, pgsql_connection:sql_query(Conn, "create temporary table types (id integer primary key, an_integer integer, a_bigint bigint, a_text text, a_uuid uuid, a_bytea bytea, a_real real)"))
        },
        {"Insert nulls (literal)",
            ?_assertEqual({updated, 1}, pgsql_connection:sql_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (1, null, null, null, null, null, null)"))
        },
        {"Select nulls (1)",
            ?_assertMatch({selected, [{1, null, null, null, null, null, null}]}, pgsql_connection:sql_query(Conn, "select * from types where id = 1"))
        },
        {"Insert nulls (params)",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)", [2, null, null, null, null, null, null]))
        },
        {"Select nulls (2)",
            ?_assertMatch({selected, [{2, null, null, null, null, null, null}]}, pgsql_connection:sql_query(Conn, "select * from types where id = 2"))
        },
        {"Insert integer",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)",
                [3, 42, null, null, null, null, null]))
        },
        {"Insert bigint",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)",
                [4, null, 1099511627776, null, null, null, null]))
        },
        {"Insert text (list)",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)",
                [5, null, null, "And in the end, the love you take is equal to the love you make", null, null, null]))
        },
        {"Insert text (binary)",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)",
                [6, null, null, <<"And in the end, the love you take is equal to the love you make">>, null, null, null]))
        },
        {"Insert uuid (list)",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)",
                [7, null, null, null, "727F42A6-E6A0-4223-9B72-6A5EB7436AB5", null, null]))
        },
        {"Insert uuid (binary)",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)",
                [8, null, null, null, {uuid, <<114,127,66,166,230,160,66,35,155,114,106,94,183,67,106,181>>}, null, null]))
        },
        {"Insert bytea",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)",
                [9, null, null, null, null, <<"deadbeef">>, null]))
        },
        {"Insert float",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)",
                [10, null, null, null, null, null, 3.1415]))
        },
        {"Insert float",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)",
                [11, null, null, null, null, null, 3.0]))
        },
        {"Insert all",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)",
                [12, 42, 1099511627776, "And in the end, the love you take is equal to the love you make", "727F42A6-E6A0-4223-9B72-6A5EB7436AB5", <<"deadbeef">>, 3.1415]))
        },
        {"Select values (12)",
            ?_test(begin
                R = pgsql_connection:sql_query(Conn, "select * from types where id = 12"),
                ?assertMatch({selected, [_Row]}, R),
                {selected, [Row]} = R,
                ?assertMatch({12, 42, 1099511627776, <<"And in the end, the love you take is equal to the love you make">>, _UUID, <<"deadbeef">>, _Float}, Row),
                {12, 42, 1099511627776, <<"And in the end, the love you take is equal to the love you make">>, UUID, <<"deadbeef">>, Float} = Row,
                ?assertEqual({uuid, <<114,127,66,166,230,160,66,35,155,114,106,94,183,67,106,181>>}, UUID),
                ?assert(Float > 3.1413),
                ?assert(Float < 3.1416)
            end)
        },
        {"Select values (12) (with bind)",
            ?_test(begin
                R = pgsql_connection:param_query(Conn, "select * from types where id = ?", [12]),
                ?assertMatch({selected, [_Row]}, R),
                {selected, [Row]} = R,
                ?assertMatch({12, 42, 1099511627776, <<"And in the end, the love you take is equal to the love you make">>, _UUID, <<"deadbeef">>, _Float}, Row),
                {12, 42, 1099511627776, <<"And in the end, the love you take is equal to the love you make">>, UUID, <<"deadbeef">>, Float} = Row,
                ?assertEqual({uuid, <<114,127,66,166,230,160,66,35,155,114,106,94,183,67,106,181>>}, UUID),
                ?assert(Float > 3.1413),
                ?assert(Float < 3.1416)
            end)
        },
        {"Insert bytea",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)",
                [13, null, null, null, null, <<"deadbeef">>, null]))
        },
        {"Insert with returning",
            ?_assertEqual({updated, 1, [{14}]}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?) RETURNING id",
                [14, null, null, null, null, <<"deadbeef">>, null]))
        },
        {"Select values (13)",
            ?_test(begin
                R = pgsql_connection:param_query(Conn, "select * from types where id = ?", [13]),
                ?assertMatch({selected, [_Row]}, R),
                {selected, [Row]} = R,
                ?assertEqual({13, null, null, null, null, <<"deadbeef">>, null}, Row)
            end)
        },
        {"Insert uuid in lowercase",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)",
                [15, null, null, null, "727f42a6-e6a0-4223-9b72-6a5eb7436ab5", null, null]))
        },
        {"Insert uc uuid in text column",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)",
                [16, null, null, "727F42A6-E6A0-4223-9B72-6A5EB7436AB5", null, null, null]))
        },
        {"Insert lc uuid in text column",
            ?_assertEqual({updated, 1}, pgsql_connection:param_query(Conn, "insert into types (id, an_integer, a_bigint, a_text, a_uuid, a_bytea, a_real) values (?, ?, ?, ?, ?, ?, ?)",
                [17, null, null, "727f42a6-e6a0-4223-9b72-6a5eb7436ab5", null, null, null]))
        },
        {"Select text uuid (16 \& 17)",
            ?_test(begin
                R = pgsql_connection:param_query(Conn, "select a_text from types where id IN ($1, $2) order by id", [16, 17]),
                ?assertMatch({selected, [_Row16, _Row17]}, R),
                {selected, [Row16, Row17]} = R,
                ?assertEqual({<<"727F42A6-E6A0-4223-9B72-6A5EB7436AB5">>}, Row16),
                ?assertEqual({<<"727f42a6-e6a0-4223-9b72-6a5eb7436ab5">>}, Row17)
            end)
        }
        ]
    end}.

text_types_test_() ->
    {setup,
        fun() ->
                {ok, SupPid} = pgsql_connection_sup:start_link(),
                {ok, Conn} = pgsql_connection:open("test", "test"),
                {SupPid, Conn}
        end,
        fun({SupPid, Conn}) ->
                pgsql_connection:close(Conn),
                kill_sup(SupPid)
        end,
        fun({_SupPid, Conn}) ->
                [
                    ?_assertMatch({{select,1},[_],[{<<"foo">>}]}, pgsql_connection:simple_query(Conn, "select 'foo'::text")),
                    ?_assertMatch({{select,1},[_],[{<<"foo">>}]}, pgsql_connection:extended_query(Conn, "select $1::text", [<<"foo">>])),
                    ?_assertMatch({{select,1},[_],[{<<"foo         ">>}]}, pgsql_connection:simple_query(Conn, "select 'foo'::char(12)")),
                    ?_assertMatch({{select,1},[_],[{<<"foo         ">>}]}, pgsql_connection:extended_query(Conn, "select $1::char(12)", [<<"foo">>])),
                    ?_assertMatch({{select,1},[_],[{<<"foo">>}]}, pgsql_connection:simple_query(Conn, "select 'foo'::varchar(12)")),
                    ?_assertMatch({{select,1},[_],[{<<"foo">>}]}, pgsql_connection:extended_query(Conn, "select $1::varchar(12)", [<<"foo">>])),
                    ?_assertMatch({{select,1},[_],[{<<"foo">>}]}, pgsql_connection:simple_query(Conn, "select 'foobar'::char(3)")),
                    ?_assertMatch({{select,1},[_],[{<<"foo">>}]}, pgsql_connection:extended_query(Conn, "select $1::char(3)", [<<"foobar">>]))
                ]
        end
    }.


array_types_test_() ->
    {setup,
        fun() ->
                {ok, SupPid} = pgsql_connection_sup:start_link(),
                {ok, Conn} = pgsql_connection:open("test", "test"),
                {SupPid, Conn}
        end,
        fun({SupPid, Conn}) ->
                pgsql_connection:close(Conn),
                kill_sup(SupPid)
        end,
        fun({_SupPid, Conn}) ->
                [
                    ?_assertMatch({{select,1},[_],[{{array,[<<"2">>,<<"3">>]}}]}, pgsql_connection:simple_query(Conn, "select '{2,3}'::text[]")),
                    ?_assertMatch({{select,1},[_],[{{array,[2,3]}}]}, pgsql_connection:simple_query(Conn, "select '{2,3}'::int[]")),
                    ?_assertMatch({{select,1},[_],[{{array,[]}}]}, pgsql_connection:simple_query(Conn, "select '{}'::text[]")),
                    ?_assertMatch({{select,1},[_],[{{array,[]}}]}, pgsql_connection:simple_query(Conn, "select '{}'::int[]")),
                    ?_assertMatch({{select,1},[_],[{{array,[]}}]}, pgsql_connection:simple_query(Conn, "select ARRAY[]::text[]")),
                    ?_assertMatch({{select,1},[_],[{{array,[<<"2">>,<<"3">>]}}]}, pgsql_connection:extended_query(Conn, "select $1::text[]", ["{\"2\", \"3\"}"])),
                    ?_assertMatch({{select,1},[_],[{{array,[<<"2">>,<<"3">>]}}]}, pgsql_connection:extended_query(Conn, "select $1::text[]", [{array, ["2", "3"]}])),
                    ?_assertMatch({{select,1},[_],[{{array,[<<"2">>,<<"3">>]}}]}, pgsql_connection:extended_query(Conn, "select $1::text[]", [{array, [<<"2">>, <<"3">>]}])),
                    ?_assertMatch({{select,1},[_],[{{array,[<<"2,3">>,<<"4">>]}}]}, pgsql_connection:extended_query(Conn, "select $1::text[]", [{array, [<<"2,3">>, <<"4">>]}])),
                    ?_assertMatch({{select,1},[_],[{{array,[<<"2,,3">>,<<"4">>]}}]}, pgsql_connection:extended_query(Conn, "select $1::text[]", [{array, [<<"2,,3">>, <<"4">>]}])),
                    ?_assertMatch({{select,1},[_],[{{array,[<<"2\"3">>,<<"4">>]}}]}, pgsql_connection:extended_query(Conn, "select $1::text[]", [{array, [<<"2\"3">>, <<"4">>]}])),
                    ?_assertMatch({{select,1},[_],[{{array,[<<"2\",,\"3">>,<<"4">>]}}]}, pgsql_connection:extended_query(Conn, "select $1::text[]", [{array, [<<"2\",,\"3">>, <<"4">>]}])),
                    ?_assertMatch({{select,1},[_],[{{array,[<<"2'3">>,<<"4">>]}}]}, pgsql_connection:extended_query(Conn, "select $1::text[]", [{array, [<<"2'3">>, <<"4">>]}])),
                    ?_assertMatch({{select,1},[_],[{{array,[<<"2\\3">>,<<"4">>]}}]}, pgsql_connection:extended_query(Conn, "select $1::text[]", [{array, [<<"2\\3">>, <<"4">>]}])),
                    ?_assertMatch({{select,1},[_],[{{array,[<<"2">>,<<"3">>]}}]}, pgsql_connection:extended_query(Conn, "select $1::bytea[]", [{array, [<<"2">>, <<"3">>]}])),
                    ?_assertMatch({{select,1},[_],[{{array,[<<"2  ">>,<<"3  ">>]}}]}, pgsql_connection:extended_query(Conn, "select $1::char(3)[]", [{array, [<<"2">>, <<"3">>]}])),
                    ?_assertMatch({{select,1},[_],[{{array,[<<"2">>,<<"3">>]}}]}, pgsql_connection:extended_query(Conn, "select $1::varchar(3)[]", [{array, [<<"2">>, <<"3">>]}])),
                    ?_assertMatch({{select,1},[_],[{{array,[{array,[<<"2">>]},{array, [<<"3">>]}]}}]}, pgsql_connection:extended_query(Conn, "select $1::text[]", [{array, [{array, [<<"2">>]}, {array, [<<"3">>]}]}])),
                    ?_assertMatch({{select,1},[_],[{{array,[]}}]}, pgsql_connection:extended_query(Conn, "select '{}'::text[]", [])),
                    ?_assertMatch({{select,1},[_],[{{array,[]}}]}, pgsql_connection:extended_query(Conn, "select '{}'::int[]", [])),
                    ?_assertMatch({{select,1},[_],[{{array,[]}}]}, pgsql_connection:extended_query(Conn, "select ARRAY[]::text[]", [])),
                    
                    ?_assertMatch({{select,1},[_],[{{array,[{array,[<<"2">>]},{array, [<<"3">>]}]}}]}, pgsql_connection:simple_query(Conn, "select '{{\"2\"}, {\"3\"}}'::text[][]")),
                    ?_assertMatch({{select,1},[_],[{{array,[{array,[1,2]}, {array, [3,4]}]}}]}, pgsql_connection:simple_query(Conn, "select ARRAY[ARRAY[1,2], ARRAY[3,4]]")),
                    ?_assertMatch({{select,1},[_],[{{array,[]}}]}, pgsql_connection:extended_query(Conn, "select $1::bytea[]", [{array, []}])),
                    ?_assertMatch({{select,1},[_, _],[{{array,[]},{array,[<<"foo">>]}}]}, pgsql_connection:extended_query(Conn, "select $1::bytea[], $2::bytea[]", [{array, []}, {array, [<<"foo">>]}])),

                    ?_assertMatch({{select,1},[_],[{{array,[1,2]}}]}, pgsql_connection:simple_query(Conn, "select ARRAY[1,2]::int[]")),
                    {timeout, 20, ?_test(
                        begin
                                {{create, table},[],[]} = pgsql_connection:simple_query(Conn, "create temporary table tmp (id integer primary key, ints integer[])"),
                                Array = lists:seq(1,1000000),
                                R = pgsql_connection:extended_query(Conn, "insert into tmp(id, ints) values($1, $2)", [1, {array, Array}]),
                                ?assertMatch({{insert, 0, 1}, [], []}, R)
                        end)},
                    ?_test(
                        begin
                                {{create, table}, [], []} = pgsql_connection:simple_query(Conn, "create temporary table tmp2 (id integer primary key, bins bytea[])"),
                                R = pgsql_connection:extended_query(Conn, "insert into tmp2(id, bins) values($1, $2)", [1, {array, [<<2>>, <<3>>]}]),
                                ?assertMatch({{insert, 0, 1}, [], []}, R),
                                R2 = pgsql_connection:extended_query(Conn, "insert into tmp2(id, bins) values($1, $2)", [2, {array, [<<16#C2,1>>]}]),
                                ?assertMatch({{insert, 0, 1}, [], []}, R2),
                                R3 = pgsql_connection:extended_query(Conn, "insert into tmp2(id, bins) values($1, $2)", [3, {array, [<<2,0,3>>, <<4>>]}]),
                                ?assertMatch({{insert, 0, 1}, [], []}, R3)
                        end)
                ]
        end
    }.

geometric_types_test_() ->
    [{setup,
      fun() ->
              {ok, SupPid} = pgsql_connection_sup:start_link(),
              {ok, Conn} = pgsql_connection:open("test", "test"),
              {SupPid, Conn}
      end,
      fun({SupPid, Conn}) ->
              pgsql_connection:close(Conn),
              kill_sup(SupPid)
      end,
      fun({_SupPid, Conn}) ->
              [
               ?_assertMatch({{select,1},[_],[{{point,{2.0,-3.0}}}]}, pgsql_connection:simple_query(Conn, "select '(2,-3)'::point")),
               ?_assertMatch({{select,1},[_],[{{point,{2.0,1.45648}}}]}, pgsql_connection:simple_query(Conn, "select '(2,1.45648)'::point")),
               ?_assertMatch({{select,1},[_],[{{point,{-3.154548,-3.0}}}]}, pgsql_connection:simple_query(Conn, "select '(-3.154548,-3)'::point")),
               ?_assertMatch({{select,1},[_],[{{point,{-3.154548,1.45648}}}]}, pgsql_connection:simple_query(Conn, "select '(-3.154548,1.45648)'::point")),
               ?_assertMatch({{select,1},[_],[{{point,{2.0,-3.0}}}]}, pgsql_connection:extended_query(Conn, "select '(2,-3)'::point", [])),
               ?_assertMatch({{select,1},[_],[{{point,{2.0,1.45648}}}]}, pgsql_connection:extended_query(Conn, "select '(2,1.45648)'::point", [])),
               ?_assertMatch({{select,1},[_],[{{point,{-3.154548,-3.0}}}]}, pgsql_connection:extended_query(Conn, "select '(-3.154548,-3)'::point", [])),
               ?_assertMatch({{select,1},[_],[{{point,{-3.154548,1.45648}}}]}, pgsql_connection:extended_query(Conn, "select '(-3.154548,1.45648)'::point", [])),

               ?_assertMatch({{select,1},[_],[{{lseg,{2.0,1.45648},{-3.154548,-3.0}}}]}, pgsql_connection:simple_query(Conn, "select '[(2,1.45648),(-3.154548,-3)]'::lseg")),
               ?_assertMatch({{select,1},[_],[{{lseg,{2.0,1.45648},{-3.154548,-3.0}}}]}, pgsql_connection:extended_query(Conn, "select '[(2,1.45648),(-3.154548,-3))'::lseg", [])),

               ?_assertMatch({{select,1},[_],[{{box,{2.0,1.45648},{-3.154548,-3.0}}}]}, pgsql_connection:simple_query(Conn, "select '((-3.154548,-3),(2,1.45648))'::box")),
               ?_assertMatch({{select,1},[_],[{{box,{2.0,1.45648},{-3.154548,-3.0}}}]}, pgsql_connection:extended_query(Conn, "select '((-3.154548,-3),(2,1.45648))'::box", [])),

               ?_assertMatch({{select,1},[_],[{{polygon,[{-3.154548,-3.0},{2.0,1.45648}]}}]}, pgsql_connection:simple_query(Conn, "select '((-3.154548,-3),(2,1.45648))'::polygon")),
               ?_assertMatch({{select,1},[_],[{{polygon,[{-3.154548,-3.0},{2.0,1.45648}]}}]}, pgsql_connection:extended_query(Conn, "select '((-3.154548,-3),(2,1.45648))'::polygon", [])),

               ?_assertMatch({{select,1},[_],[{{path,closed,[{-3.154548,-3.0},{2.0,1.45648}]}}]}, pgsql_connection:simple_query(Conn, "select '((-3.154548,-3),(2,1.45648))'::path")),
               ?_assertMatch({{select,1},[_],[{{path,closed,[{-3.154548,-3.0},{2.0,1.45648}]}}]}, pgsql_connection:extended_query(Conn, "select '((-3.154548,-3),(2,1.45648))'::path", [])),

               ?_assertMatch({{select,1},[_],[{{path,open,[{-3.154548,-3.0},{2.0,1.45648}]}}]}, pgsql_connection:simple_query(Conn, "select '[(-3.154548,-3),(2,1.45648)]'::path")),
               ?_assertMatch({{select,1},[_],[{{path,open,[{-3.154548,-3.0},{2.0,1.45648}]}}]}, pgsql_connection:extended_query(Conn, "select '[(-3.154548,-3),(2,1.45648)]'::path", [])),

               {setup,
                fun() ->
                        {updated, 1} = pgsql_connection:sql_query(Conn, "create temporary table tmp (id integer primary key, mypoint point, mylseg lseg, mybox box, mypath path, mypolygon polygon)"),
                        ok
                end,
                fun(_) ->
                        ok
                end,
                fun(_) ->
                        [
                         ?_assertMatch(
                            {{insert, 0, 1}, [<<"id">>, <<"mypoint">>], [{1, {point,{2.0,3.0}}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mypoint) values($1, $2) returning id, mypoint", [1, {point,{2,3}}])
                           ),
                         ?_assertEqual(
                            {{insert, 0, 1}, [<<"id">>, <<"mypoint">>], [{2, {point,{-10.0,3.254}}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mypoint) values($1, $2) returning id, mypoint", [2, {point,{-10,3.254}}])
                           ),
                         ?_assertEqual(
                            {{insert, 0, 1}, [<<"id">>, <<"mypoint">>], [{3, {point,{-10.0,-3.5015}}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mypoint) values($1, $2) returning id, mypoint", [3, {point,{-10,-3.5015}}])
                           ),
                         ?_assertEqual(
                            {{insert, 0, 1}, [<<"id">>, <<"mypoint">>], [{4, {point,{2.25,-3.59}}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mypoint) values($1, $2) returning id, mypoint", [4, {point,{2.25,-3.59}}])
                           ),

                         ?_assertEqual(
                            {{insert, 0, 1}, [<<"id">>, <<"mylseg">>], [{101, {lseg,{2.54,3.14},{-10.0,-3.5015}}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mylseg) values($1, $2) returning id, mylseg", [101, {lseg,{2.54,3.14},{-10,-3.5015}}])
                           ),

                         ?_assertEqual(
                            {{insert, 0, 1}, [<<"id">>, <<"mybox">>], [{201, {box,{2.0,3.0},{-10.14,-3.5015}}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mybox) values($1, $2) returning id, mybox", [201, {box,{2,3},{-10.14,-3.5015}}])
                           ),
                         ?_assertEqual(
                            {{insert, 0, 1}, [<<"id">>, <<"mybox">>], [{202, {box,{2.0,3.0},{-10.14,-3.5015}}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mybox) values($1, $2) returning id, mybox", [202, {box,{-10.14,3},{2,-3.5015}}])
                           ),
                         ?_assertEqual(
                            {{insert, 0, 1}, [<<"id">>, <<"mybox">>], [{203, {box,{2.0,3.0},{-10.14,-3.5015}}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mybox) values($1, $2) returning id, mybox", [203, {box,{2,-3.5015},{-10.14,3}}])
                           ),
                         ?_assertEqual(
                            {{insert, 0, 1}, [<<"id">>, <<"mybox">>], [{204, {box,{2.0,3.0},{-10.14,-3.5015}}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mybox) values($1, $2) returning id, mybox", [204, {box,{-10.14,-3.5015},{2,3}}])
                           ),

                         ?_assertEqual(
                            {{insert, 0, 1}, [<<"id">>, <<"mypath">>], [{301, {path,open,[{-10.85,-3.5015}]}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mypath) values($1, $2) returning id, mypath", [301, {path,open,[{-10.85,-3.5015}]}])
                           ),
                         ?_assertEqual(
                            {{insert, 0, 1}, [<<"id">>, <<"mypath">>], [{302, {path,open,[{-10.85,-3.5015},{2.0,3.0}]}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mypath) values($1, $2) returning id, mypath", [302, {path,open,[{-10.85,-3.5015},{2,3}]}])
                           ),

                         ?_assertEqual(
                            {{insert, 0, 1}, [<<"id">>, <<"mypath">>], [{351, {path,closed,[{-10.85,-3.5015}]}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mypath) values($1, $2) returning id, mypath", [351, {path,closed,[{-10.85,-3.5015}]}])
                           ),
                         ?_assertEqual(
                            {{insert, 0, 1}, [<<"id">>, <<"mypath">>], [{352, {path,closed,[{-10.85,-3.5015},{2.0,3.0}]}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mypath) values($1, $2) returning id, mypath", [352, {path,closed,[{-10.85,-3.5015},{2,3}]}])
                           ),

                         ?_assertEqual(
                            {{insert, 0, 1}, [<<"id">>, <<"mypolygon">>], [{401, {polygon,[{-10.85,-3.5015}]}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mypolygon) values($1, $2) returning id, mypolygon", [401, {polygon,[{-10.85,-3.5015}]}])
                           ),
                         ?_assertEqual(
                            {{insert, 0, 1}, [<<"id">>, <<"mypolygon">>], [{402, {polygon,[{-10.85,-3.5015},{2.0,3.0}]}}]},
                            pgsql_connection:extended_query(Conn, "insert into tmp(id, mypolygon) values($1, $2) returning id, mypolygon", [402, {polygon,[{-10.85,-3.5015},{2,3}]}])
                           )
                        ]
                end
               }
              ]
      end
     },
     {setup,
      fun() ->
              {ok, SupPid} = pgsql_connection_sup:start_link(),
              {ok, Conn} = pgsql_connection:open("test", "test"),
              {updated, 1} = pgsql_connection:sql_query(Conn, "create temporary table tmp (id integer primary key, mypath path)"),
              {SupPid, Conn}
      end,
      fun({SupPid, Conn}) ->
              pgsql_connection:close(Conn),
              kill_sup(SupPid)
      end,
      fun({_SupPid, Conn}) ->
              ?_assertMatch(
                  {error, {badarg, {path,open,[]}}},
                  pgsql_connection:extended_query(Conn, "insert into tmp(id, mypath) values($1, $2) returning id, mypath", [300, {path,open,[]}])
              )
      end},
     {setup,
      fun() ->
              {ok, SupPid} = pgsql_connection_sup:start_link(),
              {ok, Conn} = pgsql_connection:open("test", "test"),
              {updated, 1} = pgsql_connection:sql_query(Conn, "create temporary table tmp (id integer primary key, mypath path)"),
              {SupPid, Conn}
      end,
      fun({SupPid, Conn}) ->
              pgsql_connection:close(Conn),
              kill_sup(SupPid)
      end,
      fun({_SupPid, Conn}) ->
              ?_assertMatch(
                  {error, {badarg, {path,closed,[]}}},
                  pgsql_connection:extended_query(Conn, "insert into tmp(id, mypath) values($1, $2) returning id, mypath", [350, {path,closed,[]}])
              )
      end},
     {setup,
      fun() ->
              {ok, SupPid} = pgsql_connection_sup:start_link(),
              {ok, Conn} = pgsql_connection:open("test", "test"),
              {updated, 1} = pgsql_connection:sql_query(Conn, "create temporary table tmp (id integer primary key, mypolygon polygon)"),
              {SupPid, Conn}
      end,
      fun({SupPid, Conn}) ->
              pgsql_connection:close(Conn),
              kill_sup(SupPid)
      end,
      fun({_SupPid, Conn}) ->
              ?_assertMatch(
                  {error, {badarg, {polygon, []}}},
                  pgsql_connection:extended_query(Conn, "insert into tmp(id, mypolygon) values($1, $2) returning id, mypolygon", [400, {polygon,[]}])
              )
      end}
    ].

float_types_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        ?_assertEqual({selected, [{1.0}]}, pgsql_connection:sql_query(Conn, "select 1.0::float4")),
        ?_assertEqual({selected, [{1.0}]}, pgsql_connection:sql_query(Conn, "select 1.0::float8")),
        ?_assertEqual({selected, [{1.0}]}, pgsql_connection:param_query(Conn, "select 1.0::float4", [])),
        ?_assertEqual({selected, [{1.0}]}, pgsql_connection:param_query(Conn, "select 1.0::float8", [])),

        ?_assertEqual({selected, [{3.14159}]}, pgsql_connection:sql_query(Conn, "select 3.141592653589793::float4")),
        ?_assertEqual({selected, [{3.14159265358979}]}, pgsql_connection:sql_query(Conn, "select 3.141592653589793::float8")),
        ?_assertEqual({selected, [{3.1415927410125732}]}, pgsql_connection:param_query(Conn, "select 3.141592653589793::float4", [])),
        ?_assertEqual({selected, [{3.141592653589793}]}, pgsql_connection:param_query(Conn, "select 3.141592653589793::float8", [])),

        ?_assertEqual({selected, [{'NaN'}]}, pgsql_connection:sql_query(Conn, "select 'NaN'::float4")),
        ?_assertEqual({selected, [{'NaN'}]}, pgsql_connection:sql_query(Conn, "select 'NaN'::float8")),
        ?_assertEqual({selected, [{'NaN'}]}, pgsql_connection:param_query(Conn, "select 'NaN'::float4", [])),
        ?_assertEqual({selected, [{'NaN'}]}, pgsql_connection:param_query(Conn, "select 'NaN'::float8", [])),

        ?_assertEqual({selected, [{'Infinity'}]}, pgsql_connection:sql_query(Conn, "select 'Infinity'::float4")),
        ?_assertEqual({selected, [{'Infinity'}]}, pgsql_connection:sql_query(Conn, "select 'Infinity'::float8")),
        ?_assertEqual({selected, [{'Infinity'}]}, pgsql_connection:param_query(Conn, "select 'Infinity'::float4", [])),
        ?_assertEqual({selected, [{'Infinity'}]}, pgsql_connection:param_query(Conn, "select 'Infinity'::float8", [])),

        ?_assertEqual({selected, [{'-Infinity'}]}, pgsql_connection:sql_query(Conn, "select '-Infinity'::float4")),
        ?_assertEqual({selected, [{'-Infinity'}]}, pgsql_connection:sql_query(Conn, "select '-Infinity'::float8")),
        ?_assertEqual({selected, [{'-Infinity'}]}, pgsql_connection:param_query(Conn, "select '-Infinity'::float4", [])),
        ?_assertEqual({selected, [{'-Infinity'}]}, pgsql_connection:param_query(Conn, "select '-Infinity'::float8", []))
    ]
    end}.

boolean_type_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        ?_assertEqual({selected, [{true}]}, pgsql_connection:sql_query(Conn, "select true::boolean")),
        ?_assertEqual({selected, [{false}]}, pgsql_connection:sql_query(Conn, "select false::boolean")),
        ?_assertEqual({selected, [{true}]}, pgsql_connection:param_query(Conn, "select true::boolean", [])),
        ?_assertEqual({selected, [{false}]}, pgsql_connection:param_query(Conn, "select false::boolean", []))
    ]
    end}.

null_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        ?_assertEqual({selected, [{null}]}, pgsql_connection:sql_query(Conn, "select null")),
        ?_assertEqual({selected, [{null}]}, pgsql_connection:param_query(Conn, "select null", [])),
        ?_assertEqual({selected, [{null}]}, pgsql_connection:sql_query(Conn, "select null::int2")),
        ?_assertEqual({selected, [{null}]}, pgsql_connection:param_query(Conn, "select null::int2", []))
    ]
    end}.

integer_types_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        ?_assertEqual({selected, [{127}]}, pgsql_connection:sql_query(Conn, "select 127::int2")),
        ?_assertEqual({selected, [{-126}]}, pgsql_connection:sql_query(Conn, "select -126::int2")),
        ?_assertEqual({selected, [{127}]}, pgsql_connection:sql_query(Conn, "select 127::int4")),
        ?_assertEqual({selected, [{-126}]}, pgsql_connection:sql_query(Conn, "select -126::int4")),
        ?_assertEqual({selected, [{127}]}, pgsql_connection:sql_query(Conn, "select 127::int8")),
        ?_assertEqual({selected, [{-126}]}, pgsql_connection:sql_query(Conn, "select -126::int8")),
        ?_assertEqual({selected, [{127}]}, pgsql_connection:param_query(Conn, "select 127::int2", [])),
        ?_assertEqual({selected, [{-126}]}, pgsql_connection:param_query(Conn, "select -126::int2", [])),
        ?_assertEqual({selected, [{127}]}, pgsql_connection:param_query(Conn, "select 127::int4", [])),
        ?_assertEqual({selected, [{-126}]}, pgsql_connection:param_query(Conn, "select -126::int4", [])),
        ?_assertEqual({selected, [{127}]}, pgsql_connection:param_query(Conn, "select 127::int8", [])),
        ?_assertEqual({selected, [{-126}]}, pgsql_connection:param_query(Conn, "select -126::int8", []))
    ]
    end}.

% Numerics can be either integers or floats.
numeric_types_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        % text values (simple_query)
        ?_assertMatch({{select, 1}, [_], [{127}]}, pgsql_connection:simple_query(Conn, "select 127::numeric")),
        ?_assertMatch({{select, 1}, [_], [{-126}]}, pgsql_connection:simple_query(Conn, "select -126::numeric")),
        ?_assertMatch({{select, 1}, [_], [{123456789012345678901234567890}]}, pgsql_connection:simple_query(Conn, "select 123456789012345678901234567890::numeric")),
        ?_assertMatch({{select, 1}, [_], [{-123456789012345678901234567890}]}, pgsql_connection:simple_query(Conn, "select -123456789012345678901234567890::numeric")),
        ?_assertMatch({{select, 1}, [_], [{'NaN'}]}, pgsql_connection:simple_query(Conn, "select 'NaN'::numeric")),
        ?_assertMatch({{select, 1}, [_], [{123456789012345678901234.567890}]}, pgsql_connection:simple_query(Conn, "select 123456789012345678901234.567890::numeric")),
        ?_assertMatch({{select, 1}, [_], [{-123456789012345678901234.567890}]}, pgsql_connection:simple_query(Conn, "select -123456789012345678901234.567890::numeric")),
        ?_assertMatch({{select, 1}, [_], [{1000000.0}]}, pgsql_connection:simple_query(Conn, "select 1000000.0::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{10000.0}]}, pgsql_connection:simple_query(Conn, "select 10000.0::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{100.0}]}, pgsql_connection:simple_query(Conn, "select 100.0::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{1.0}]}, pgsql_connection:simple_query(Conn, "select 1.0::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{0.0}]}, pgsql_connection:simple_query(Conn, "select 0.0::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{0.1}]}, pgsql_connection:simple_query(Conn, "select 0.1::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{0.00001}]}, pgsql_connection:simple_query(Conn, "select 0.00001::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{0.0000001}]}, pgsql_connection:simple_query(Conn, "select 0.0000001::numeric", [])),

        % binary values (extended_query)
        ?_assertMatch({{select, 1}, [_], [{127}]}, pgsql_connection:extended_query(Conn, "select 127::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{-126}]}, pgsql_connection:extended_query(Conn, "select -126::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{123456789012345678901234567890}]}, pgsql_connection:extended_query(Conn, "select 123456789012345678901234567890::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{-123456789012345678901234567890}]}, pgsql_connection:extended_query(Conn, "select -123456789012345678901234567890::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{'NaN'}]}, pgsql_connection:extended_query(Conn, "select 'NaN'::numeric", [])),
        ?_test(begin
            {{select, 1}, [_], [{Val}]} = pgsql_connection:extended_query(Conn, "select 123456789012345678901234.567890::numeric", []),
            ?assert(Val > 123456789012345500000000.0),
            ?assert(Val < 123456789012345700000000.0)
        end),
        ?_test(begin
            {{select, 1}, [_], [{Val}]} = pgsql_connection:extended_query(Conn, "select -123456789012345678901234.567890::numeric", []),
            ?assert(Val > -123456789012345700000000.0),
            ?assert(Val < -123456789012345500000000.0)
        end),
        ?_assertMatch({{select, 1}, [_], [{1000000.0}]}, pgsql_connection:extended_query(Conn, "select 1000000.0::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{10000.0}]}, pgsql_connection:extended_query(Conn, "select 10000.0::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{100.0}]}, pgsql_connection:extended_query(Conn, "select 100.0::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{1.0}]}, pgsql_connection:extended_query(Conn, "select 1.0::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{0.0}]}, pgsql_connection:extended_query(Conn, "select 0.0::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{0.1}]}, pgsql_connection:extended_query(Conn, "select 0.1::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{0.00001}]}, pgsql_connection:extended_query(Conn, "select 0.00001::numeric", [])),
        ?_assertMatch({{select, 1}, [_], [{0.0000001}]}, pgsql_connection:extended_query(Conn, "select 0.0000001::numeric", []))
    ]
    end}.

datetime_types_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("127.0.0.1", "test", "test", "", [{timezone, "UTC"}]),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        ?_assertEqual({selected, [{{2012,1,17}}]},    pgsql_connection:sql_query(Conn, "select '2012-01-17 10:54:03.45'::date")),
        ?_assertEqual({selected, [{{10,54,3}}]},   pgsql_connection:sql_query(Conn, "select '2012-01-17 10:54:03'::time")),
        ?_assertEqual({selected, [{{10,54,3.45}}]},   pgsql_connection:sql_query(Conn, "select '2012-01-17 10:54:03.45'::time")),
        ?_assertEqual({selected, [{{10,54,3.45}}]},   pgsql_connection:sql_query(Conn, "select '2012-01-17 10:54:03.45'::timetz")),
        ?_assertEqual({selected, [{{{2012,1,17},{10,54,3}}}]},   pgsql_connection:sql_query(Conn, "select '2012-01-17 10:54:03'::timestamp")),
        ?_assertEqual({selected, [{{{2012,1,17},{10,54,3.45}}}]},   pgsql_connection:sql_query(Conn, "select '2012-01-17 10:54:03.45'::timestamp")),
        ?_assertEqual({selected, [{{{2012,1,17},{10,54,3.45}}}]},   pgsql_connection:sql_query(Conn, "select '2012-01-17 10:54:03.45'::timestamptz")),
        ?_assertEqual({selected, [{{{1972,1,17},{10,54,3.45}}}]},   pgsql_connection:sql_query(Conn, "select '1972-01-17 10:54:03.45'::timestamp")),
        ?_assertEqual({selected, [{{{1972,1,17},{10,54,3.45}}}]},   pgsql_connection:sql_query(Conn, "select '1972-01-17 10:54:03.45'::timestamptz")),
        ?_assertEqual({selected, [{{1970,1,1}}]},   pgsql_connection:sql_query(Conn, "select 'epoch'::date")),
        ?_assertEqual({selected, [{{0,0,0}}]},   pgsql_connection:sql_query(Conn, "select 'allballs'::time")),
        ?_assertEqual({selected, [{infinity}]},   pgsql_connection:sql_query(Conn, "select 'infinity'::timestamp")),
        ?_assertEqual({selected, [{'-infinity'}]},   pgsql_connection:sql_query(Conn, "select '-infinity'::timestamp")),
        ?_assertEqual({selected, [{infinity}]},   pgsql_connection:sql_query(Conn, "select 'infinity'::timestamptz")),
        ?_assertEqual({selected, [{'-infinity'}]},   pgsql_connection:sql_query(Conn, "select '-infinity'::timestamptz")),

        ?_assertEqual({selected, [{{2012,1,17}}]},    pgsql_connection:param_query(Conn, "select '2012-01-17 10:54:03.45'::date", [])),
        ?_assertEqual({selected, [{{10,54,3}}]},   pgsql_connection:param_query(Conn, "select '2012-01-17 10:54:03'::time", [])),
        ?_assertEqual({selected, [{{10,54,3.45}}]},   pgsql_connection:param_query(Conn, "select '2012-01-17 10:54:03.45'::time", [])),
        ?_assertEqual({selected, [{{10,54,3.45}}]},   pgsql_connection:param_query(Conn, "select '2012-01-17 10:54:03.45'::timetz", [])),
        ?_assertEqual({selected, [{{{2012,1,17},{10,54,3}}}]},   pgsql_connection:param_query(Conn, "select '2012-01-17 10:54:03'::timestamp", [])),
        ?_assertEqual({selected, [{{{2012,1,17},{10,54,3.45}}}]},   pgsql_connection:param_query(Conn, "select '2012-01-17 10:54:03.45'::timestamp", [])),
        ?_assertEqual({selected, [{{{2012,1,17},{10,54,3.45}}}]},   pgsql_connection:param_query(Conn, "select '2012-01-17 10:54:03.45'::timestamptz", [])),
        ?_assertEqual({selected, [{{{1972,1,17},{10,54,3.45}}}]},   pgsql_connection:param_query(Conn, "select '1972-01-17 10:54:03.45'::timestamp", [])),
        ?_assertEqual({selected, [{{{1972,1,17},{10,54,3.45}}}]},   pgsql_connection:param_query(Conn, "select '1972-01-17 10:54:03.45'::timestamptz", [])),
        ?_assertEqual({selected, [{{1970,1,1}}]},   pgsql_connection:param_query(Conn, "select 'epoch'::date", [])),
        ?_assertEqual({selected, [{{0,0,0}}]},   pgsql_connection:param_query(Conn, "select 'allballs'::time", [])),
        ?_assertEqual({selected, [{infinity}]},   pgsql_connection:param_query(Conn, "select 'infinity'::timestamp", [])),
        ?_assertEqual({selected, [{'-infinity'}]},   pgsql_connection:param_query(Conn, "select '-infinity'::timestamp", [])),
        ?_assertEqual({selected, [{infinity}]},   pgsql_connection:param_query(Conn, "select 'infinity'::timestamptz", [])),
        ?_assertEqual({selected, [{'-infinity'}]},   pgsql_connection:param_query(Conn, "select '-infinity'::timestamptz", [])),

        ?_assertMatch({{select, 1}, [_], [{{{2012,1,17},{10,54,3}}}]},   pgsql_connection:extended_query(Conn, "select $1::timestamptz", [{{2012,1,17},{10,54,3}}])),
        ?_assertMatch({{select, 1}, [_], [{{2012,1,17}}]},   pgsql_connection:extended_query(Conn, "select $1::date", [{2012,1,17}])),
        ?_assertMatch({{select, 1}, [_], [{{10,54,3}}]},   pgsql_connection:extended_query(Conn, "select $1::time", [{10,54,3}])),

        {"Create temporary table for the times", ?_assertEqual({updated, 1}, pgsql_connection:sql_query(Conn, "create temporary table times (a_timestamp timestamp, a_time time)"))},
        {"Insert timestamp with micro second resolution",
            ?_assertEqual({{insert, 0, 1}, [], []}, pgsql_connection:extended_query(Conn, "insert into times (a_timestamp, a_time) values ($1, $2)", [{{2014, 5, 15}, {12, 12, 12.999999}}, null]))
        },
        {"Insert timestamp without micro second resolution",
            ?_assertEqual({{insert, 0, 1}, [], []}, pgsql_connection:extended_query(Conn, "insert into times (a_timestamp, a_time) values ($1, $2)", [{{2014, 5, 15}, {12, 12, 12}}, null]))
        },
        {"Insert a time with micro second resolution",
            ?_assertEqual({{insert, 0, 1}, [], []}, pgsql_connection:extended_query(Conn, "insert into times (a_timestamp, a_time) values ($1, $2)", [null, {12, 12, 12.999999}]))
        },
        {"Insert a time without micro second resolution",
            ?_assertEqual({{insert, 0, 1}, [], []}, pgsql_connection:extended_query(Conn, "insert into times (a_timestamp, a_time) values ($1, $2)", [null, {12, 12, 12}]))
        }
    ]
    end}.

fold_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        {timeout, 20,
        ?_test(begin
            {updated, 1} = pgsql_connection:sql_query(Conn, "create temporary table tmp (id integer primary key, a_text text)"),
            {updated, 0} = pgsql_connection:sql_query(Conn, "BEGIN"),
            Val = lists:foldl(fun(I, Acc) ->
                Str = "foobar " ++ integer_to_list(I * 42),
                {updated, 1} = pgsql_connection:param_query(Conn, "insert into tmp (id, a_text) values (?, ?)", [I, Str]),
                Acc + length(Str)
            end, 0, lists:seq(1, 3742)),
            {updated, 0} = pgsql_connection:sql_query(Conn, "COMMIT"),
            R = pgsql_connection:fold(fun([_], {Text}, Acc) ->
                Acc + byte_size(Text)
            end, 0, Conn, "select a_text from tmp"),
            ?assertEqual({ok, Val}, R)
        end)
        }
    ]
    end}.

map_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        {timeout, 20,
        ?_test(begin
            {updated, 1} = pgsql_connection:sql_query(Conn, "create temporary table tmp (id integer primary key, a_text text)"),
            {updated, 0} = pgsql_connection:sql_query(Conn, "BEGIN"),
            ValR = lists:foldl(fun(I, Acc) ->
                Str = "foobar " ++ integer_to_list(I * 42),
                {updated, 1} = pgsql_connection:param_query(Conn, "insert into tmp (id, a_text) values (?, ?)", [I, Str]),
                [length(Str) | Acc]
            end, [], lists:seq(1, 3742)),
            Val = lists:reverse(ValR),
            {updated, 0} = pgsql_connection:sql_query(Conn, "COMMIT"),
            R = pgsql_connection:map(fun([_], {Text}) ->
                byte_size(Text)
            end, Conn, "select a_text from tmp"),
            ?assertEqual({ok, Val}, R)
        end)
        }
    ]
    end}.

map_fold_foreach_should_return_when_query_is_invalid_test_() ->
   {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        ?_test(begin
            R = pgsql_connection:extended_query(Conn, "select toto", []),
            ?assertMatch({error, _}, R)
        end),
        ?_test(begin
            R = pgsql_connection:map(fun(_, _) -> ok end, Conn, "select toto"),
            ?assertMatch({error, _}, R)
        end),
        ?_test(begin
            R = pgsql_connection:fold(fun(_, _, _) -> ok end, ok, Conn, "select toto"),
            ?assertMatch({error, _}, R)
        end),
        ?_test(begin
            R = pgsql_connection:foreach(fun(_, _) -> ok end, Conn, "select toto"),
            ?assertMatch({error, _}, R)
        end)
    ]
    end}.

foreach_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        {timeout, 20,
        ?_test(begin
            {updated, 1} = pgsql_connection:sql_query(Conn, "create temporary table tmp (id integer primary key, a_text text)"),
            {updated, 0} = pgsql_connection:sql_query(Conn, "BEGIN"),
            ValR = lists:foldl(fun(I, Acc) ->
                Str = "foobar " ++ integer_to_list(I * 42),
                {updated, 1} = pgsql_connection:param_query(Conn, "insert into tmp (id, a_text) values (?, ?)", [I, Str]),
                [length(Str) | Acc]
            end, [], lists:seq(1, 3742)),
            Val = lists:reverse(ValR),
            {updated, 0} = pgsql_connection:sql_query(Conn, "COMMIT"),
            Self = self(),
            R = pgsql_connection:foreach(fun([_], {Text}) ->
                Self ! {foreach_inner, byte_size(Text)}
            end, Conn, "select a_text from tmp"),
            ?assertEqual(ok, R),
            lists:foreach(fun(AVal) ->
                receive {foreach_inner, AVal} -> ok end
            end, Val)
        end)
        }
    ]
    end}.

timeout_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        ?_assertEqual({selected, [{null}]}, pgsql_connection:sql_query(Conn, "select pg_sleep(2)")),
        ?_assertEqual({selected, [{null}]}, pgsql_connection:param_query(Conn, "select pg_sleep(2)", [])),
        ?_assertEqual({selected, [{null}]}, pgsql_connection:sql_query(Conn, "select pg_sleep(2)", [], infinity)),
        ?_assertEqual({selected, [{null}]}, pgsql_connection:param_query(Conn, "select pg_sleep(2)", [], [], infinity)),
        ?_assertEqual({selected, [{null}]}, pgsql_connection:sql_query(Conn, "select pg_sleep(2)", [], 2500)),
        ?_assertEqual({selected, [{null}]}, pgsql_connection:param_query(Conn, "select pg_sleep(2)", [], [], 2500)),
        ?_assertMatch({error, _}, pgsql_connection:sql_query(Conn, "select pg_sleep(2)", [], 1500)),
        ?_assertMatch({error, _}, pgsql_connection:param_query(Conn, "select pg_sleep(2)", [], [], 1500)),
        ?_assertEqual({selected, [{null}]}, pgsql_connection:sql_query(Conn, "select pg_sleep(2)")),
        ?_assertEqual({selected, [{null}]}, pgsql_connection:param_query(Conn, "select pg_sleep(2)", [])),
        ?_test(begin
            ShowResult1 = pgsql_connection:simple_query(Conn, "show statement_timeout"),
            ?assertMatch({show, [_], [{_}]}, ShowResult1),
            {show, [<<"statement_timeout">>], [{Value1}]} = ShowResult1,
            ?assertMatch({{select, 1}, [_], [{1}]}, pgsql_connection:simple_query(Conn, "select 1", [], 2500)),
            ?assertMatch({{select, 1}, [_], [{1}]}, pgsql_connection:simple_query(Conn, "select 1", [])),
            ShowResult2 = pgsql_connection:simple_query(Conn, "show statement_timeout"),
            ?assertMatch({show, [<<"statement_timeout">>], [{_}]}, ShowResult2),
            {show, [<<"statement_timeout">>], [{Value2}]} = ShowResult2,
            ?assertEqual({set, [], []}, pgsql_connection:simple_query(Conn, "set statement_timeout to 2500")),
            ?assertMatch({{select, 1}, [_], [{1}]}, pgsql_connection:simple_query(Conn, "select 1", [], 2500)),
            ?assertMatch({{select, 1}, [_], [{1}]}, pgsql_connection:simple_query(Conn, "select 1", [])),
            ShowResult3 = pgsql_connection:simple_query(Conn, "show statement_timeout"),
            ?assertMatch({show, [<<"statement_timeout">>], [{_}]}, ShowResult3),
            
            % Only guarantee is that if the default was 0 (infinity), it is maintained
            % after a query with a default (infinity) timeout.
            if
                Value1 =:= <<"0">> -> ?assertEqual(Value1, Value2);
                true -> ok
            end
        end)
    ]
    end}.

postgression_ssl_test_() ->
    {setup,
    fun() ->
        ssl:start(),
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        ok = application:start(inets),
        {ok, Result} = httpc:request("http://api.postgression.com/"),
        ConnInfo = case Result of
            {{"HTTP/1.1", 200, "OK"}, _Headers, ConnectionString} ->
                {match, [User, Password, Host, PortStr, Database]} =
                    re:run(ConnectionString, "^postgres://(.*):(.*)@(.*):([0-9]+)/(.*)$", [{capture, all_but_first, list}]),
                Port = list_to_integer(PortStr),
                {Host, Database, User, Password, Port};
            {{"HTTP/1.1", 500, HTTPStatus}, _Headers, FailureDescription} ->
                ?debugFmt("Postgression unavailable: ~s\n~s\n", [HTTPStatus, FailureDescription]),
                unavailable
        end,
        {SupPid, ConnInfo}
    end,
    fun({SupPid, _ConnInfo}) ->
        kill_sup(SupPid),
        ssl:stop()
    end,
    fun({_SupPid, ConnInfo}) ->
        case ConnInfo of
            unavailable ->
                ?debugMsg("Skipped.\n"),
                [];
            {Host, Database, User, Password, Port} ->
                [
                    {"Postgression requires SSL",
                    ?_test(begin
                        {error, _} = pgsql_connection:open(Host, Database, User, Password, [{port, Port}])
                    end)
                    },
                    {"SSL Connection test",
                    ?_test(begin
                        {ok, Conn} = pgsql_connection:open(Host, Database, User, Password, [{port, Port}, {ssl, true}]),
                        ?assertMatch({show, [_], [{<<"on">>}]}, pgsql_connection:simple_query(Conn, "show ssl")),
                        pgsql_connection:close(Conn)
                    end)
                    }
                ]
        end
    end}.

constraint_violation_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        ?_test(begin
            {updated, 1} = pgsql_connection:sql_query(Conn, "create temporary table tmp (id integer primary key, a_text text)"),
            {updated, 1} = pgsql_connection:param_query(Conn, "insert into tmp (id, a_text) values (?, ?)", [1, <<"hello">>]),
            E = pgsql_connection:param_query(Conn, "insert into tmp (id, a_text) values (?, ?)", [1, <<"world">>]),
            ?assertMatch({error, _}, E),
            {error, Err} = E,
            ?assert(pgsql_error:is_integrity_constraint_violation(Err))
        end)
    ]
    end}.

custom_enum_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        pgsql_connection:sql_query(Conn, "DROP TYPE IF EXISTS mood;"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:sql_query(Conn, "DROP TYPE mood;"),
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        ?_test(begin
            {updated, 0} = pgsql_connection:sql_query(Conn, "BEGIN"),
            {updated, 1} = pgsql_connection:sql_query(Conn, "CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy');"),
            ?assertMatch({selected, [{{MoodOID, <<"sad">>}}]} when is_integer(MoodOID), pgsql_connection:sql_query(Conn, "select 'sad'::mood;")),
            ?assertMatch({selected, [{{MoodOID, <<"sad">>}}]} when is_integer(MoodOID), pgsql_connection:param_query(Conn, "select 'sad'::mood;", [])),
            {updated, 0} = pgsql_connection:sql_query(Conn, "COMMIT"),
            ?assertMatch({selected, [{{mood, <<"sad">>}}]}, pgsql_connection:sql_query(Conn, "select 'sad'::mood;")),
            ?assertMatch({selected, [{{mood, <<"sad">>}}]}, pgsql_connection:param_query(Conn, "select 'sad'::mood;", [])),
            ?assertMatch({selected, [{{mood, <<"sad">>}}]}, pgsql_connection:param_query(Conn, "select ?::mood;", [<<"sad">>])),
            ?assertMatch({selected, [{{array, [{mood, <<"sad">>}]}}]}, pgsql_connection:sql_query(Conn, "select '{sad}'::mood[];")),
            ?assertMatch({selected, [{{array, [{mood, <<"sad">>}]}}]}, pgsql_connection:param_query(Conn, "select ?::mood[];", [{array, [<<"sad">>]}]))
        end)
    ]
    end}.

custom_enum_native_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        pgsql_connection:simple_query(Conn, "DROP TYPE IF EXISTS mood;"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        {{drop, type}, [], []} = pgsql_connection:simple_query(Conn, "DROP TYPE mood;"),
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        ?_test(begin
            {'begin', [], []} = pgsql_connection:simple_query(Conn, "BEGIN"),
            {{create, type}, [], []} = pgsql_connection:simple_query(Conn, "CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy');"),
            ?assertMatch({{select, 1}, [_], [{{MoodOID, <<"sad">>}}]} when is_integer(MoodOID), pgsql_connection:simple_query(Conn, "select 'sad'::mood;")),
            ?assertMatch({{select, 1}, [_], [{{MoodOID, <<"sad">>}}]} when is_integer(MoodOID), pgsql_connection:extended_query(Conn, "select 'sad'::mood;", [])),
            {'commit', [], []} = pgsql_connection:simple_query(Conn, "COMMIT"),
            ?assertMatch({{select, 1}, [_], [{{mood, <<"sad">>}}]}, pgsql_connection:simple_query(Conn, "select 'sad'::mood;")),
            ?assertMatch({{select, 1}, [_], [{{mood, <<"sad">>}}]}, pgsql_connection:extended_query(Conn, "select 'sad'::mood;", [])),
            ?assertMatch({{select, 1}, [_], [{{mood, <<"sad">>}}]}, pgsql_connection:extended_query(Conn, "select $1::mood;", [<<"sad">>])),
            ?assertMatch({{select, 1}, [_], [{{array, [{mood, <<"sad">>}]}}]}, pgsql_connection:simple_query(Conn, "select '{sad}'::mood[];")),
            ?assertMatch({{select, 1}, [_], [{{array, [{mood, <<"sad">>}]}}]}, pgsql_connection:extended_query(Conn, "select $1::mood[];", [{array, [<<"sad">>]}]))
        end)
    ]
    end}.

invalid_query_test_() ->
    {setup,
        fun() ->
                {ok, SupPid} = pgsql_connection_sup:start_link(),
                {ok, Conn} = pgsql_connection:open("test", "test"),
                {{create, table}, [], []} = pgsql_connection:simple_query(Conn, "CREATE TEMPORARY TABLE tmp(id integer primary key, other text)"),
                {SupPid, Conn}
        end,
        fun({SupPid, Conn}) ->
                pgsql_connection:close(Conn),
                kill_sup(SupPid)
        end,
        fun({_SupPid, Conn}) ->
                [
                    ?_test(begin
                                ?assertMatch({error, _Error}, pgsql_connection:simple_query(Conn, "FOO")),
                                ?assertMatch({error, _Error}, pgsql_connection:simple_query(Conn, "FOO", [])),
                                ?assertMatch({error, _Error}, pgsql_connection:simple_query(Conn, "FOO", [], 5000)),
                                % connection still usable
                                R = pgsql_connection:extended_query(Conn, "insert into tmp(id, other) values (2, $1)", ["toto"]),
                                ?assertEqual({{insert, 0, 1}, [], []}, R)
                        end),
                    ?_test(begin
                                {'begin', [], []} = pgsql_connection:simple_query(Conn, "BEGIN"),
                                R1 = pgsql_connection:extended_query(Conn, "insert into tmp(id, other) values (3, $1)", ["toto"]),
                                ?assertEqual({{insert, 0, 1}, [], []}, R1),
                                ?assertMatch({error, _Error}, pgsql_connection:simple_query(Conn, "FOO", [], 5000)),
                                ?assertMatch({error, _Error}, pgsql_connection:simple_query(Conn, "FOO", [], 5000)),
                                {'rollback', [], []} = pgsql_connection:simple_query(Conn, "COMMIT"),
                                % row 3 was not inserted.
                                R1 = pgsql_connection:extended_query(Conn, "insert into tmp(id, other) values (3, $1)", ["toto"]),
                                ?assertEqual({{insert, 0, 1}, [], []}, R1)
                        end),
                    ?_test(begin
                                {'begin', [], []} = pgsql_connection:simple_query(Conn, "BEGIN"),
                                R1 = pgsql_connection:extended_query(Conn, "insert into tmp(id, other) values (4, $1)", ["toto"]),
                                ?assertEqual({{insert, 0, 1}, [], []}, R1),
                                ?assertMatch({error, _Error}, pgsql_connection:extended_query(Conn, "FOO", [], [], 5000)),
                                ?assertMatch({error, _Error}, pgsql_connection:extended_query(Conn, "FOO", [], [], 5000)),
                                {'rollback', [], []} = pgsql_connection:simple_query(Conn, "COMMIT"),
                                R1 = pgsql_connection:extended_query(Conn, "insert into tmp(id, other) values (4, $1)", ["toto"]),
                                ?assertEqual({{insert, 0, 1}, [], []}, R1)
                        end),
                    ?_test(begin
                                {'begin', [], []} = pgsql_connection:simple_query(Conn, "BEGIN"),
                                R1 = pgsql_connection:extended_query(Conn, "insert into tmp(id, other) values (5, $1)", ["toto"]),
                                ?assertEqual({{insert, 0, 1}, [], []}, R1),
                                ?assertMatch({error, _Error}, pgsql_connection:extended_query(Conn, "FOO", [], [], 5000)),
                                {'rollback', [], []} = pgsql_connection:simple_query(Conn, "ROLLBACK"),
                                R1 = pgsql_connection:extended_query(Conn, "insert into tmp(id, other) values (5, $1)", ["toto"]),
                                ?assertEqual({{insert, 0, 1}, [], []}, R1)
                        end),
                    ?_test(begin
                                {'begin', [], []} = pgsql_connection:simple_query(Conn, "BEGIN"),
                                R1 = pgsql_connection:extended_query(Conn, "insert into tmp(id, other) values (6, $1)", ["toto"]),
                                ?assertEqual({{insert, 0, 1}, [], []}, R1),
                                ?assertMatch({error, _Error}, pgsql_connection:extended_query(Conn, "FOO", [], [], 5000)),
                                {'rollback', [], []} = pgsql_connection:simple_query(Conn, "ROLLBACK", [], 5000),
                                R1 = pgsql_connection:extended_query(Conn, "insert into tmp(id, other) values (6, $1)", ["toto"]),
                                ?assertEqual({{insert, 0, 1}, [], []}, R1)
                        end)
                ]
        end
    }.


cancel_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        ?_test(begin
            Self = self(),
            spawn_link(fun() ->
                SleepResult = pgsql_connection:sql_query(Conn, "select pg_sleep(2)"),
                Self ! {async_result, SleepResult}
            end),
            ?assertEqual(ok, pgsql_connection:cancel(Conn)),
            receive
                {async_result, R} ->
                    ?assertMatch({error, _}, R),
                    {error, #{code := Code}} = R,
                    ?assertEqual(Code, <<"57014">>)
            end
        end)
    ]
    end}.

pending_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        {timeout, 10, ?_test(begin
            {{create, table}, [], []} = pgsql_connection:simple_query(Conn, "CREATE TEMPORARY TABLE tmp(id integer primary key, other text)"),
            Parent = self(),
            WorkerA = spawn(fun() ->
                R0 = pgsql_connection:simple_query(Conn, "SELECT COUNT(*) FROM tmp"),
                Parent ! {r0, R0},
                receive continue -> ok end,
                R2 = pgsql_connection:simple_query(Conn, "SELECT pg_sleep(1), COUNT(*) FROM tmp"),
                Parent ! {r2, R2},
                R4 = pgsql_connection:simple_query(Conn, "SELECT pg_sleep(1), COUNT(*) FROM tmp"),
                Parent ! {r4, R4},
                R6 = pgsql_connection:simple_query(Conn, "SELECT COUNT(*) FROM tmp"),
                Parent ! {r6, R6}
            end),
            spawn(fun() ->
                R1 = pgsql_connection:simple_query(Conn, "INSERT INTO tmp (id) VALUES (1)"),
                Parent ! {r1, R1},
                WorkerA ! continue,
                loop_until_process_is_waiting(WorkerA), % make sure command 2 was sent.
                R3 = pgsql_connection:simple_query(Conn, "INSERT INTO tmp SELECT 2 AS id, CAST (pg_sleep(0.5) AS text) AS other"),
                Parent ! {r3, R3},
                R5 = pgsql_connection:simple_query(Conn, "INSERT INTO tmp (id) VALUES (3)"),
                Parent ! {r5, R5}
            end),
            receive {RT0, R0} -> ?assertEqual(r0, RT0), ?assertMatch({{select, 1}, [_], [{0}]}, R0) end,
            receive {RT1, R1} -> ?assertEqual(r1, RT1), ?assertEqual({{insert, 0, 1}, [], []}, R1) end,
            receive {RT2, R2} -> ?assertEqual(r2, RT2), ?assertMatch({{select, 1}, [_, _], [{null, 1}]}, R2) end,
            receive {RT3, R3} -> ?assertEqual(r3, RT3), ?assertEqual({{insert, 0, 1}, [], []}, R3) end,
            receive {RT4, R4} -> ?assertEqual(r4, RT4), ?assertMatch({{select, 1}, [_, _], [{null, 2}]}, R4) end,
            receive {RT5, R5} -> ?assertEqual(r5, RT5), ?assertEqual({{insert, 0, 1}, [], []}, R5) end,
            receive {RT6, R6} -> ?assertEqual(r6, RT6), ?assertMatch({{select, 1}, [_], [{3}]}, R6) end
        end)}
    ]
    end}.

loop_until_process_is_waiting(Pid) ->
    case process_info(Pid, status) of
        {status, waiting} -> ok;
        _ -> loop_until_process_is_waiting(Pid)
    end.

batch_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        {ok, Conn} = pgsql_connection:open("test", "test"),
        {SupPid, Conn}
    end,
    fun({SupPid, Conn}) ->
        pgsql_connection:close(Conn),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn}) ->
    [
        ?_assertMatch([{{select, 1}, [_], [{1}]},{{select, 1}, [_], [{2}]},{{select, 1}, [_], [{3}]}], pgsql_connection:batch_query(Conn, "select $1::int", [[1], [2], [3]])),
        ?_assertMatch([{{select, 1}, [_], [{<<"bar">>}]},{{select, 1}, [_], [{<<"foo">>}]},{{select, 1}, [_], [{null}]}], pgsql_connection:batch_query(Conn, "select $1::bytea", [[<<"bar">>], [<<"foo">>], [null]]))
    ]
    end}.

async_process_loop(TestProcess) ->
    receive
        {set_test_process, Pid} ->
            async_process_loop(Pid);
        OtherMessage ->
            ?assert(is_pid(TestProcess)),
            TestProcess ! {self(), OtherMessage},
            async_process_loop(TestProcess)
    end.
        
notify_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        AsyncProcess = spawn_link(fun() ->
            async_process_loop(undefined)
        end),
        {ok, Conn1} = pgsql_connection:open([{database, "test"}, {user, "test"}, {async, AsyncProcess}]),
        {ok, Conn2} = pgsql_connection:open("test", "test"),
        {SupPid, Conn1, Conn2, AsyncProcess}
    end,
    fun({SupPid, Conn1, Conn2, AsyncProcess}) ->
        pgsql_connection:close(Conn1),
        pgsql_connection:close(Conn2),
        unlink(AsyncProcess),
        exit(AsyncProcess, normal),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn1, Conn2, AsyncProcess}) ->
    [
        ?_test(begin
            R = pgsql_connection:simple_query(Conn1, "LISTEN test_channel"),
            ?assertEqual({listen, [], []}, R)
        end),
        {"Notifications are received while idle",
        ?_test(begin
            AsyncProcess ! {set_test_process, self()},
            R = pgsql_connection:simple_query(Conn2, "NOTIFY test_channel"),
            ?assertEqual({notify, [], []}, R),
            receive {AsyncProcess, NotifyMessage} ->
                ?assertMatch({pgsql, Conn1, {notification, _PID, <<"test_channel">>, <<>>}}, NotifyMessage)
            after 1000 -> ?assert(false)
            end
        end)
        },
        {"Notifications are received with payload",
        ?_test(begin
            AsyncProcess ! {set_test_process, self()},
            R = pgsql_connection:simple_query(Conn2, "NOTIFY test_channel, 'payload string'"),
            ?assertEqual({notify, [], []}, R),
            receive {AsyncProcess, NotifyMessage} ->
                ?assertMatch({pgsql, Conn1, {notification, _PID, <<"test_channel">>, <<"payload string">>}}, NotifyMessage)
            after 1000 -> ?assert(false)
            end
        end)
        },
        {"Notifications are received with a busy connection executing several requests",
        ?_test(begin
            Parent = self(),
            AsyncProcess ! {set_test_process, Parent},
            spawn_link(fun() ->
                R = pgsql_connection:simple_query(Conn1, "SELECT pg_sleep(0.5)"),
                ?assertMatch({{select, 1}, [_], [{null}]}, R),
                AsyncProcess ! sleep_1
            end),
            timer:sleep(100),
            spawn_link(fun() ->
                R = pgsql_connection:simple_query(Conn1, "SELECT pg_sleep(0.5)"),
                ?assertMatch({{select, 1}, [_], [{null}]}, R),
                AsyncProcess ! sleep_2
            end),
            R = pgsql_connection:simple_query(Conn2, "NOTIFY test_channel"),
            ?assertEqual({notify, [], []}, R),
            % Acceptable orders are : sleep_1, notification, sleep_2 or notification, sleep_1, sleep_2.
            % PostgreSQL currently (9.2) sends notification after sleep_1 is completed, once the transaction is finished.
            % See note at http://www.postgresql.org/docs/9.2/static/protocol-flow.html#PROTOCOL-ASYNC
            Message0 = receive {AsyncProcess, Msg0} -> Msg0 after 1500 -> ?assert(false) end,
            Message1 = receive {AsyncProcess, Msg1} -> Msg1 after 1500 -> ?assert(false) end,
            Message2 = receive {AsyncProcess, Msg2} -> Msg2 after 1500 -> ?assert(false) end,
            ?assertEqual(sleep_2, Message2),
            case Message0 of
                sleep_1 ->
                    ?assertMatch({pgsql, Conn1, {notification, _PID, <<"test_channel">>, <<>>}}, Message1);
                {pgsql, Conn1, {notification, _PID, <<"test_channel">>, <<>>}} ->
                    ?assertEqual(sleep_1, Message1)
            end
        end)
        },
        {"Subscribe for notifications",
        ?_test(begin
            pgsql_connection:subscribe(Conn1, self()),
            AsyncProcess ! {set_test_process, self()},
            R = pgsql_connection:simple_query(Conn2, "NOTIFY test_channel, '1'"),
            ?assertEqual({notify, [], []}, R),
            receive {AsyncProcess, {pgsql, Conn1, {notification, _PID1, <<"test_channel">>, <<"1">>}}} -> ok
            after 1000 -> ?assert(false)
            end,
            receive {pgsql, Conn1, {notification, _PID2, <<"test_channel">>, <<"1">>}} -> ok
            after 1000 -> ?assert(false)
            end,
            pgsql_connection:unsubscribe(Conn1, self()),
            R = pgsql_connection:simple_query(Conn2, "NOTIFY test_channel, '2'"),
            ?assertEqual({notify, [], []}, R),
            receive {AsyncProcess, {pgsql, Conn1, {notification, _PID3, <<"test_channel">>, <<"2">>}}} -> ok
            after 1000 -> ?assert(false)
            end,
            receive {pgsql, Conn1, {notification, _PID4, <<"test_channel">>, <<"2">>}} -> ?assert(false)
            after 1000 -> ok
            end
        end)
        }
    ]
    end}.

notice_test_() ->
    {setup,
    fun() ->
        {ok, SupPid} = pgsql_connection_sup:start_link(),
        NoticeProcess = spawn_link(fun() ->
            async_process_loop(undefined)
        end),
        {ok, Conn1} = pgsql_connection:open([{database, "test"}, {user, "test"}, {async, NoticeProcess}]),
        {SupPid, Conn1, NoticeProcess}
    end,
    fun({SupPid, Conn1, NoticeProcess}) ->
        pgsql_connection:close(Conn1),
        unlink(NoticeProcess),
        exit(NoticeProcess, normal),
        kill_sup(SupPid)
    end,
    fun({_SupPid, Conn1, AsyncProcess}) ->
    [
        ?_test(begin
            AsyncProcess ! {set_test_process, self()},
            % Set client_min_messages to NOTICE. This is the default, but some environment (e.g. Travis) may have it configured otherwise.
            R1 = pgsql_connection:simple_query(Conn1, "SET client_min_messages=NOTICE;"),
            ?assertEqual({'set', [], []}, R1),
            R2 = pgsql_connection:simple_query(Conn1, "DO $$ BEGIN RAISE NOTICE 'test notice'; END $$;"),
            ?assertEqual({'do', [], []}, R2),
            receive {AsyncProcess, NoticeMessage} ->
                ?assertMatch({pgsql, Conn1, {notice, _Fields}}, NoticeMessage),
                {pgsql, Conn1, {notice, Fields}} = NoticeMessage,
                ?assertEqual({severity, <<"NOTICE">>}, lists:keyfind(severity, 1, Fields)),
                ?assertEqual({message, <<"test notice">>}, lists:keyfind(message, 1, Fields))
            after 1000 -> ?assert(false)
            end
        end)
    ]
    end}.

