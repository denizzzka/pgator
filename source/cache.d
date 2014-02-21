// Written in D programming language
/**
* Caching system
*
*
* Authors: Zaramzan <shamyan.roman@gmail.com>
*
*/
module cache;


import std.digest.md;

import json_rpc.response;
import json_rpc.request;
import json_rpc.error;

import sql_json;

import util;

private enum VERSION
{
	/// Drop all cache by method
	FULL, 
	
	/// Drop only cache by uniq request
	REQUEST
}

/// CHOOSE ME
private immutable VER = VERSION.REQUEST;


shared class Cache
{
	private alias RpcResponse[RpcRequest] stash;
	 
	private stash[string] cache;
	
	private SqlJsonTable table;
	
	this(shared SqlJsonTable table)
	{
		this.table = table;
	}
	
	this(SqlJsonTable table)
	{
		this.table = toShared(table);
	}
	
	bool reset(ref RpcRequest req)
	{
		if (!table.needDrop(req.method))
		{
			return false;
		}
		
		static if (VER == VERSION.FULL)
		{
			synchronized (this) 
			{
				return cache.remove(req.method);
			}
		}
		else
		{
			synchronized (this)
			{
				return cache[req.method].remove(req);
			}
		}
	}
	
	bool reset(string method)
	{
		if (!table.needDrop(method))
		{
			return false;
		}
		
		synchronized (this) 
		{
			return cache.remove(method);
		}
	}
	
	void add(RpcRequest req, ref RpcResponse res)
	{	
		//dirty, for ignoring id in cache
		req.id = vibe.data.json.Json("forcache");
		
		if ((req.method in cache) is null)
		{
			stash aa;
			aa[req] = res;
			
			synchronized(this)
				cache[req.method] = toShared(aa);
		}
		else synchronized (this) 
		{
			cache[req.method][req] = toShared(res);
		}
		
	}
	
	bool get(ref RpcRequest req, out RpcResponse res)
	{
		scope(failure)
		{
			return false;
		}
		
		res = cast(RpcResponse) cache[req.method][req];
		
		res.id = req.id;
		
		return true; 
	}
	
}

version(unittest)
{
	shared Cache cache;
	
	void initCache()
	{
		cache = new shared Cache(table);
	}
	
	//get
	void get()
	{
		import std.stdio;
		RpcResponse res;
		if (cache.get(normalReq, res))
		{
			//writeln(res.toJson);
		}
		
		if (cache.get(notificationReq, res))
		{
			//writeln(res.toJson);
		}
		
		if (cache.get(methodNotFoundReq, res))
		{
			//writeln(res.toJson);
		}
		
		if (cache.get(invalidParamsReq, res))
		{
			//writeln(res.toJson);
		}
	}
	
	// get -> reset -> get
	void foo()
	{
		scope(failure)
		{
			assert(false, "foo exception");
		}
		
		get();
		
		//std.stdio.writeln("Reseting cache");
		
		cache.reset(normalReq);
		
		cache.reset(notificationReq);
		
		cache.reset(methodNotFoundReq);
		
		cache.reset(invalidParamsReq);
		
		//std.stdio.writeln("Trying to get");
		
		get();
		
		import std.concurrency;
		send(ownerTid, 1);
	}
}

unittest
{	
	scope(failure)
	{
		assert(false, "Caching system unittest failed");
	}
	
	initTable();
	
	initCache();
	
	initResponses();
	
	cache.add(normalReq, normalRes);
	
	cache.add(notificationReq, notificationRes);
	
	cache.add(methodNotFoundReq, mnfRes);
	
	cache.add(invalidParamsReq, invalidParasmRes);
	
	import std.concurrency;
	
	Tid tid;
	
	for(int i = 0; i < 10; i++)
	{
		tid = spawn(&foo);
	}
	
	receiveOnly!int();
	
	std.stdio.writeln("Caching system test finished");
		
}
