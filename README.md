# riak-erlang-http-client

![Riak Erlang HTTP Client OpenRiak Status](https://github.com/OpenRiak/riak-erlang-http-client/actions/workflows/erlang.yml/badge.svg?branch=openriak-3.2)

## Overview

riak-erlang-http-client is an Erlang client for Riak, using the HTTP interface

##  Quick Start

You must have [[http://erlang.org/download.html][Erlang/OTP 20]] or later and a GNU-style build system to compile and run =riak-erlang-http-client=.

```
git clone git://github.com/basho/riak-erlang-http-client.git
cd riak-erlang-http-client
make
```

If the Protocol Buffers Riak Erlang Client ([[http://github.com/basho/riak-erlang-client][riak-erlang-client]]) is already familiar to you, you should find this client familiar.  Just substitute calls to `riakc_pb_socket` with calls to `rhc`.

As a quick example, here is how to create and retrieve a value with the key "foo" in the bucket "bar" using the riak-erlang-http-client.

First, start up an Erlang shell with the path to `riak-erlang-http-client` and all dependenciess included, then  start `sasl` and `ibrowse`:

```
erl -pa path/to/riak-erlang-http-client/ebin path/to/riak-erlang-http-client/deps/*/ebin
Eshell V5.8.2  (abort with ^G)
1> [ ok = application:start(A) || A <- [sasl, ibrowse] ].
```

Next, create your client:

```
2> IP = "127.0.0.1",
2> Port = 8098,
2> Prefix = "riak",
2> Options = [],
2> C = rhc:create(IP, Port, Prefix, Options).
{rhc,"10.0.0.42",80,"riak",[{client_id,"ACoc4A=="}]}
```

Sidenote: if you will be using the defaults, as in the example above, you may call `rhc:create/0` instead of specifying the defaults yourself.

Create a new object, and store it with `rhc:put/2`:

```
3> Bucket = <<"bar">>,
3> Key = <<"foo">>,
3> Data = <<"hello world">>,
3> ContentType = <<"text/plain">>,
3> Object0 = riakc_obj:new(Bucket, Key, Data, ContentType),
3> rhc:put(C, Object0).
ok
```

Retrieve an object with =rhc:get/3=:

```
4> Bucket = <<"bar">>,
4> Key = <<"foo">>,
4> {ok, Object1} = rhc:get(C, Bucket, Key).
{ok,{riakc_obj,<<"bar">>,<<"foo">>,
               <<107,206,97,96,96,96,204,96,202,5,82,44,12,167,92,95,100,
                 48,37,50,230,177,50,...>>,
               [{{dict,3,16,16,8,80,48,
                       {[],[],[],[],[],[],[],[],[],[],[],[],...},
                       {{[],[],[],[],[],[],[],[],[],[],...}}},
                 <<"hello world">>}],
               undefined,undefined}}
```

Please refer to the generated documentation for more information:

```
+BEGIN_SRC shell
make doc && open doc/index.html
```

