module pgator.app;

import pgator.rpc_table;
import pgator.sql_transaction;
import dpq2.oids: OidType;
import std.getopt;
import std.typecons: Tuple;
import std.exception: enforce;
import std.conv: to;
import vibe.http.server;
import vibe.core.concurrency;
import vibe.core.log;
import vibe.data.json;
import vibe.data.bson;
import vibe.db.postgresql;

string configFileName = "/wrong/path/to/file.json";
bool debugEnabled = false;
bool checkStatements = false;

void readOpts(string[] args)
{
    try
    {
        auto helpInformation = getopt(
                args,
                "debug", &debugEnabled,
                "check", &checkStatements,
                "config", &configFileName
            );
    }
    catch(Exception e)
    {
        logFatal(e.msg);
        throw e;
    }

    if(debugEnabled) setLogLevel = LogLevel.debugV;
}

private Bson _cfg;

Bson readConfig()
{
    import std.file;

    Bson cfg;

    try
    {
        auto text = readText(configFileName);
        cfg = Bson(parseJsonString(text));
    }
    catch(Exception e)
    {
        logFatal(e.msg);
        throw e;
    }

    return cfg;
}

private struct PrepareStatementsArgs
{
    const SQLVariablesNames varNames;
    bool methodsLoadedFlag = false; // need for bootstrap
    Method[string] methods;
    size_t rpcTableLength;
    size_t failedCount;
    string tableName;
}

int main(string[] args)
{
    try
    {
        readOpts(args);
        Bson cfg = readConfig();

        auto server = cfg["sqlServer"];
        const connString = server["connString"].get!string;
        auto maxConn = to!uint(server["maxConn"].get!long);

        PrepareStatementsArgs prepArgs = {
            varNames: SQLVariablesNames(
                cfg["sqlAuthVariables"]["username"].get!string,
                cfg["sqlAuthVariables"]["password"].get!string
            )
        };

        // delegate
        void afterConnectOrReconnect(__Conn conn)
        {
            if(prepArgs.methodsLoadedFlag)
            {
                logDebugV("Preparing");
                auto failedStatementsNames = prepareStatements(conn, prepArgs);
                prepArgs.failedCount += failedStatementsNames.length;

                foreach(n; failedStatementsNames)
                    prepArgs.methods.remove(n);

                logInfo("Number of statements in the table "~prepArgs.tableName~": "~
                    prepArgs.rpcTableLength.to!string~", failed to prepare: "~prepArgs.failedCount.to!string);
            }
        }

        // connect to db
        auto client = new shared PostgresClient(connString, maxConn, &afterConnectOrReconnect);

        {
            auto conn = client.lockConnection();
            auto sqlPgatorTable = cfg["sqlPgatorTable"].get!string;

            // read pgator_rpc
            prepArgs.tableName = conn.escapeIdentifier(sqlPgatorTable);

            QueryParams p;
            p.sqlCommand = "SELECT * FROM "~prepArgs.tableName;
            auto answer = conn.execStatement(p);

            prepArgs.rpcTableLength = answer.length;
            auto readMethodsResult = readMethods(answer);
            prepArgs.methods = readMethodsResult.methods;
            prepArgs.methodsLoadedFlag = true;

            {
                prepArgs.failedCount = prepArgs.rpcTableLength - readMethodsResult.loaded;
                logDebugV("Number of statements in the table "~prepArgs.tableName~": "~prepArgs.rpcTableLength.to!string~", failed to load into pgator: "~prepArgs.failedCount.to!string);
            }

            // prepare statements for previously used connection
            afterConnectOrReconnect(conn);

            delete conn;
        }

        if(!checkStatements)
        {
            immutable methods = cast(immutable) prepArgs.methods.dup;
            loop(cfg, client, methods);
        }

        return prepArgs.failedCount ? 2 : 0;
    }
    catch(Exception e)
    {
        logFatal(e.msg);

        return 1;
    }
}

void loop(in Bson cfg, shared PostgresClient client, immutable Method[string] methods)
{
    // http-server
    import vibe.core.core;

    void httpRequestHandler(scope HTTPServerRequest req, HTTPServerResponse res)
    {
        try
        {
            RpcRequestResults results = performRpcRequests(methods, client, req);

            final switch(results.type)
            {
                case RpcType.vibedREST:
                    auto result = &results.results[0];

                    if(result.exception is null)
                    {
                        res.writeJsonBody(result.responseBody["result"]); //FIXME
                    }
                    else
                    {
                        res.writeJsonBody(result.responseBody, result.exception.httpCode);
                    }                    

                    break;

                case RpcType.jsonRpc:
                    auto result = &results.results[0];

                    if(result.exception is null)
                    {
                        if(result.isNotify)
                        {
                            res.statusCode = HTTPStatus.noContent;
                            res.writeVoidBody();
                        }
                        else
                        {
                            res.writeJsonBody(result.responseBody);
                        }
                    }
                    else // error handling
                    {
                        if(result.isNotify)
                        {
                            res.statusCode = HTTPStatus.noContent;
                            res.statusPhrase = result.exception.msg;
                            res.writeVoidBody();
                        }
                        else
                        {
                            res.writeJsonBody(result.responseBody, result.exception.httpCode);
                        }
                    }

                    break;

                case RpcType.jsonRpcBatchMode:
                    Bson[] ret;

                    foreach(ref r; results.results) // fill response array
                    {
                        if(!r.isNotify) // skip notify responses
                            ret ~= r.responseBody;
                    }

                    if(ret.length)
                    {
                        res.writeJsonBody(Bson(ret)); // normal batch response
                    }
                    else
                    {
                        res.statusCode = HTTPStatus.noContent;
                        res.writeVoidBody(); // empty response for batch with notifies only
                    }

                    break;
            }
        }
        catch(LoopException e)
        {
            res.writeJsonBody(Bson(e.msg), e.httpCode); // FIXME: wrong error body format

            logWarn(e.msg);
        }
        catch(Exception e)
        {
            logFatal(e.toString);
        }
    }

    //setupWorkerThreads(); // TODO: read number of threads from config

    auto settings = new HTTPServerSettings;
    // settings.options |= HTTPServerOption.distribute; // causes stuck on epoll_wait () from /lib/x86_64-linux-gnu/libc.so.6
    settings.options |= HTTPServerOption.parseJsonBody;
    settings.bindAddresses = cfg["listenAddresses"].deserializeBson!(string[]);
    settings.port = to!ushort(cfg["listenPort"].get!long);

    auto listenHandler = listenHTTP(settings, &httpRequestHandler);

    runEventLoop();
}

struct SQLVariablesNames
{
    string username;
    string password;
}

private Bson execMethod(
    shared PostgresClient client,
    in Method method,
    in RpcRequest rpcRequest
)
{
    TransactionQueryParams qp;
    qp.auth = rpcRequest.auth;
    qp.queryParams.length = method.statements.length;
    size_t paramCounter = 0;

    foreach(i, statement; method.statements)
    {
        qp.queryParams[i].preparedStatementName = preparedName(method, statement);

        if(rpcRequest.positionParams.length == 0) // named parameters
        {
            qp.queryParams[i].args = named2positionalParameters(statement, rpcRequest.namedParams);
        }
        else // positional parameters
        {
            if(rpcRequest.positionParams.length - paramCounter < statement.argsNames.length)
                throw new LoopException(JsonRpcErrorCode.invalidParams, HTTPStatus.badRequest, "Parameters number is too few", __FILE__, __LINE__);

            qp.queryParams[i].args = new Value[statement.argsNames.length];

            foreach(n, ref b; rpcRequest.positionParams[paramCounter .. paramCounter + statement.argsNames.length])
            {
                auto v = &qp.queryParams[i].args[n];
                const oid = statement.argsOids[n];

                *v = bsonToValue(b, oid);

                if(v.oidType != oid)
                    throw new LoopException(
                        JsonRpcErrorCode.invalidParams,
                        HTTPStatus.badRequest,
                        "Parameter #"~i.to!string~" type is "~v.oidType.to!string~", but expected "~oid.to!string,
                        __FILE__, __LINE__);
            }

            paramCounter += statement.argsNames.length;
        }
    }

    if(rpcRequest.positionParams.length != 0 && paramCounter != rpcRequest.positionParams.length)
    {
        assert(paramCounter < rpcRequest.positionParams.length);
        throw new LoopException(JsonRpcErrorCode.invalidParams, HTTPStatus.badRequest, "Parameters number is too big", __FILE__, __LINE__);
    }

    try
    {
        if(method.needAuthVariablesFlag && !qp.auth.authVariablesSet)
            throw new LoopException(JsonRpcErrorCode.invalidParams, HTTPStatus.unauthorized, "Basic HTTP authentication need", __FILE__, __LINE__);

        auto trans = SQLTransaction(client, method.readOnlyFlag);

        immutable answer = trans.execMethod(method, qp);

        enforce(answer.length == method.statements.length);

        Bson ret = Bson.emptyObject;

        if(!method.isMultiStatement)
        {
            ret = formatResult(answer[0], method.statements[0].resultFormat);
        }
        else
        {
            foreach(i, statement; method.statements)
            {
                if(statement.resultFormat != ResultFormat.VOID)
                    ret[statement.resultName] = formatResult(answer[i], statement.resultFormat);
            }
        }

        trans.commit();

        return ret;
    }
    catch(ConnectionException e)
    {
        // TODO: restart connection
        throw new LoopException(JsonRpcErrorCode.internalError, HTTPStatus.internalServerError, e.msg, __FILE__, __LINE__);
    }
    catch(AnswerCreationException e)
    {
        throw new LoopException(JsonRpcErrorCode.internalError, HTTPStatus.internalServerError, e.msg, __FILE__, __LINE__, e);
    }
}

private Bson formatResult(immutable Answer answer, ResultFormat format)
{
    Bson getValue(size_t rowNum, size_t colNum)
    {
        string columnName = answer.columnName(colNum);

        try
        {
            return answer[rowNum][colNum].as!Bson;
        }
        catch(AnswerConvException e)
        {
            e.msg = "Column "~columnName~" ("~rowNum.to!string~" row): "~e.msg;
            throw e;
        }
    }

    with(ResultFormat)
    final switch(format)
    {
        case CELL:
        {
            if(answer.length != 1 || answer.columnCount != 1)
                throw new LoopException(JsonRpcErrorCode.internalError, HTTPStatus.internalServerError, "One cell flag constraint failed", __FILE__, __LINE__);

            return getValue(0, 0);
        }

        case ROW:
        {
            if(answer.length != 1)
                throw new LoopException(JsonRpcErrorCode.internalError, HTTPStatus.internalServerError, "One row flag constraint failed", __FILE__, __LINE__);

            Bson ret = Bson.emptyObject;

            foreach(colNum; 0 .. answer.columnCount)
                ret[answer.columnName(colNum)] = getValue(0, colNum);

            return ret;
        }

        case TABLE:
        {
            Bson ret = Bson.emptyObject;

            foreach(colNum; 0 .. answer.columnCount)
            {
                Bson[] col = new Bson[answer.length];

                foreach(rowNum; 0 .. answer.length)
                    col[rowNum] = getValue(rowNum, colNum);

                ret[answer.columnName(colNum)] = col;
            }

            return ret;
        }

        case ROTATED:
        {
            Bson[] ret = new Bson[answer.length];

            foreach(rowNum; 0 .. answer.length)
            {
                Bson row = Bson.emptyObject;

                foreach(colNum; 0 .. answer.columnCount)
                    row[answer.columnName(colNum)] = getValue(rowNum, colNum);

                ret[rowNum] = row;
            }

            return Bson(ret);
        }

        case VOID:
        {
            return Bson.emptyObject;
        }
    }
}

Value[] named2positionalParameters(in Statement method, in Bson[string] namedParams)
{
    Value[] ret = new Value[method.argsNames.length];

    foreach(i, argName; method.argsNames)
    {
        auto b = argName in namedParams;

        if(b)
        {
            const oid = method.argsOids[i];
            Value v = bsonToValue(*b, oid);

            if(v.oidType != oid)
                throw new LoopException(
                    JsonRpcErrorCode.invalidParams,
                    HTTPStatus.badRequest,
                    argName~" parameter type is "~v.oidType.to!string~", but expected "~oid.to!string,
                    __FILE__, __LINE__);

            ret[i] = v;
        }
        else
        {
            throw new LoopException(JsonRpcErrorCode.invalidParams, HTTPStatus.badRequest, "Missing required parameter "~argName, __FILE__, __LINE__);
        }
    }

    return ret;
}

private struct AuthorizationCredentials
{
    bool authVariablesSet = false;
    string username;
    string password;
}

RpcRequestResults performRpcRequests(immutable Method[string] methods, shared PostgresClient client, scope HTTPServerRequest req)
{
    if(req.contentType != "application/json")
        throw new LoopException(JsonRpcErrorCode.invalidRequest, HTTPStatus.unsupportedMediaType, "Supported only application/json content type", __FILE__, __LINE__);

    RpcRequestResults ret;

    // Recognition of request type
    Json j = req.json;
    RpcRequest[] dbRequests;

    switch(j.type)
    {
        case Json.Type.array:
        {
            if(!j.length)
                throw new LoopException(JsonRpcErrorCode.invalidRequest, HTTPStatus.badRequest, "Empty batch array", __FILE__, __LINE__);

            ret.type = RpcType.jsonRpcBatchMode;
            dbRequests.length = j.length;

            foreach(i, ref request; dbRequests)
                request = RpcRequest.jsonToRpcRequest(j[i], req);

            break;
        }

        case Json.Type.object:
            dbRequests.length = 1;

            if(RpcRequest.isValidJsonRpcRequest(j))
            {
                ret.type = RpcType.jsonRpc;
                dbRequests[0] = RpcRequest.jsonToRpcRequest(j, req);
            }
            else
            {
                ret.type = RpcType.vibedREST;
                dbRequests[0] = RpcRequest.vibeRestToRpcRequest(j, req);
            }

            break;

        default:
            throw new LoopException(JsonRpcErrorCode.parseError, HTTPStatus.badRequest, "Parse error", __FILE__, __LINE__);
    }

    ret.results.length = dbRequests.length;

    foreach(i, const ref request; dbRequests)
    {
        ret.results[i] = async({
            return request.performRpcRequest(methods, client);
        });
    }

    return ret;
}

struct RpcRequest
{
    Bson id;
    string methodName;
    Bson[string] namedParams = null;
    Bson[] positionParams = null;
    AuthorizationCredentials auth;

    invariant()
    {
        assert(namedParams is null || positionParams is null);
    }

    bool isNotify() const
    {
        return id.type == Bson.Type.undefined;
    }

    private static bool isValidJsonRpcRequest(scope Json j)
    {
        return j["jsonrpc"] == "2.0";
    }

    private static RpcRequest jsonToRpcRequest(scope Json j, in HTTPServerRequest req)
    {
        if(!isValidJsonRpcRequest(j))
            throw new LoopException(JsonRpcErrorCode.invalidRequest, HTTPStatus.badRequest, "Isn't JSON-RPC 2.0 protocol", __FILE__, __LINE__);

        RpcRequest r;

        r.id = j["id"];
        r.methodName = j["method"].get!string;

        Json params = j["params"];

        switch(params.type)
        {
            case Json.Type.undefined: // params omitted
                break;

            case Json.Type.object:
                foreach(string key, value; params)
                    r.namedParams[key] = value;

                break;

            case Json.Type.array:
                foreach(value; params)
                    r.positionParams ~= Bson(value);

                break;

            default:
                throw new LoopException(JsonRpcErrorCode.invalidParams, HTTPStatus.badRequest, "Unexpected params type", __FILE__, __LINE__);
        }

        // pick out name and password from the request
        {
            import std.string;
            import std.base64;

            // Copypaste from vibe.d code, see https://github.com/rejectedsoftware/vibe.d/issues/1449
            auto pauth = "Authorization" in req.headers;
            if( pauth && (*pauth).startsWith("Basic ") )
            {
                string user_pw = cast(string)Base64.decode((*pauth)[6 .. $]);

                auto idx = user_pw.indexOf(":");
                enforceBadRequest(idx >= 0, "Invalid auth string format!");

                r.auth.authVariablesSet = true;
                r.auth.username = user_pw[0 .. idx];
                r.auth.password = user_pw[idx+1 .. $];
            }
        }

        return r;
    }

    /// Converts Vibe.d REST client request to RpcRequest
    private static RpcRequest vibeRestToRpcRequest(scope Json j, in HTTPServerRequest req)
    {
        RpcRequest r;

        enforce(req.path.length > 0);
        r.methodName = req.path[1..$]; // strips first '/'

        foreach(string key, ref value; req.query)
            r.namedParams[key] = value;

        r.id = Bson("REST request"); // Means what it isn't JSON-RPC "notify"

        return r;
    }

    RpcRequestResult performRpcRequest(immutable Method[string] methods, shared PostgresClient client) const
    {
        try
        {
            try
            {
                const method = (methodName in methods);

                if(method is null)
                    throw new LoopException(JsonRpcErrorCode.methodNotFound, HTTPStatus.badRequest, "Method "~methodName~" not found", __FILE__, __LINE__);

                RpcRequestResult ret;
                ret.isNotify = isNotify;

                if(!ret.isNotify)
                {
                    ret.responseBody = Bson(["id": id]);
                    ret.responseBody["jsonrpc"] = "2.0";
                    ret.responseBody["result"] = client.execMethod(*method, this);
                }
                else // JSON-RPC 2.0 Notification
                {
                    client.execMethod(*method, this);
                    ret.responseBody = Bson.emptyObject;
                }

                return ret;
            }
            catch(PostgresClientTimeoutException e)
            {
                // TODO: restart connection
                throw new LoopException(JsonRpcErrorCode.internalError, HTTPStatus.internalServerError, e.msg, __FILE__, __LINE__);
            }
            catch(AnswerConvException e)
            {
                throw new LoopException(JsonRpcErrorCode.internalError, HTTPStatus.internalServerError, e.msg, __FILE__, __LINE__);
            }
        }
        catch(LoopException e)
        {
            Bson err = Bson.emptyObject;

            err["id"] = id;
            err["jsonrpc"] = "2.0";

            if(e.answerException is null)
            {
                err["error"] = Bson([
                    "message": Bson(e.msg),
                    "code": Bson(e.jsonCode)
                ]);
            }
            else
            {
                Bson data = Bson([
                    "hint":    Bson(e.answerException.resultErrorField(PG_DIAG_MESSAGE_HINT)),
                    "detail":  Bson(e.answerException.resultErrorField(PG_DIAG_MESSAGE_DETAIL)),
                    "errcode": Bson(e.answerException.resultErrorField(PG_DIAG_SQLSTATE))
                ]);

                err["error"] = Bson([
                    "message": Bson(e.msg),
                    "code": Bson(e.jsonCode),
                    "data": data
                ]);
            }

            RpcRequestResult ret;
            ret.isNotify = isNotify;
            ret.responseBody = err;
            ret.exception = e;

            logWarn(methodName~": "~e.httpCode.to!string~" "~err.toString);

            return ret;
        }
    }
}

private struct RpcRequestResult
{
    Bson responseBody;
    LoopException exception;
    bool isNotify;

    void opAssign(shared RpcRequestResult s) shared
    {
        synchronized
        {
            // This need because Bson don't have shared opAssign
            Bson copy = s.responseBody;
            (cast() this.responseBody) = copy;

            this.exception = s.exception;
            this.isNotify = s.isNotify;
        }
    }
}

private struct RpcRequestResults
{
    Future!RpcRequestResult[] results;
    RpcType type;
}

private enum RpcType
{
    jsonRpc, /// Normal JSON mode response
    jsonRpcBatchMode, /// Batch JSON mode response
    vibedREST /// Vibe.d REST client mode response
}

enum JsonRpcErrorCode : short
{
    /// Invalid JSON was received by the server.
    /// An error occurred on the server while parsing the JSON text
    parseError = -32700,

    /// The JSON sent is not a valid Request object.
    invalidRequest = -32600,

    /// Statement not found
    methodNotFound = -32601,

    /// Invalid params
    invalidParams = -32602,

    /// Internal error
    internalError = -32603,
}

class LoopException : Exception
{
    const JsonRpcErrorCode jsonCode;
    const HTTPStatus httpCode;
    const AnswerCreationException answerException;

    this(JsonRpcErrorCode jsonCode, HTTPStatus httpCode, string msg, string file, size_t line, AnswerCreationException ae = null) pure
    {
        this.jsonCode = jsonCode;
        this.httpCode = httpCode;
        this.answerException = ae;

        super(msg, file, line);
    }
}

/// returns names of unprepared methods, but length is number of unprepared statements
private string[] prepareStatements(__Conn conn, ref PrepareStatementsArgs args)
{
    {
        logDebugV("try to prepare internal statements");

        conn.prepareStatement(BuiltInPrep.BEGIN, "BEGIN");
        conn.prepareStatement(BuiltInPrep.BEGIN_RO, "BEGIN READ ONLY");
        conn.prepareStatement(BuiltInPrep.COMMIT, "COMMIT");
        conn.prepareStatement(BuiltInPrep.ROLLBACK, "ROLLBACK");
        conn.prepareStatement(BuiltInPrep.SET_AUTH_VARS,
            "SELECT set_config("~conn.escapeLiteral(args.varNames.username)~", $1, true), "~
            "set_config("~conn.escapeLiteral(args.varNames.password)~", $2, true)");

        logDebugV("internal statements prepared");
    }

    string[] failedStatements;

    foreach(ref method; args.methods.byValue)
    {
        foreach(ref statement; method.statements)
        {
            const prepName = preparedName(method, statement);

            logDebugV("try to prepare statement "~prepName~": "~statement.sqlCommand);

            try
            {
                conn.prepareStatement(prepName, statement.sqlCommand);
                statement.argsOids = conn.retrieveArgsTypes(prepName);

                logDebugV("statement "~prepName~" prepared");
            }
            catch(ConnectionException e)
            {
                throw e;
            }
            catch(Exception e)
            {
                logWarn("Skipping "~prepName~": "~e.msg);
                failedStatements ~= method.name;
            }
        }
    }

    return failedStatements;
}

string preparedName(in Method method, in Statement statement)
{
    if(statement.statementNum < 0)
    {
        return method.name;
    }
    else
    {
        import std.conv: to;

        return method.name~"_"~statement.statementNum.to!string;
    }
}

private OidType[] retrieveArgsTypes(__Conn conn, string preparedStatementName)
{
    auto desc = conn.describePreparedStatement(preparedStatementName);

    OidType[] ret = new OidType[desc.nParams];

    argsLoop:
    foreach(i, ref t; ret)
    {
        t = desc.paramType(i);

        foreach(sup; argsSupportedTypes)
        {
            try
                if(t == sup || t == oidConvTo!"array"(sup)) continue argsLoop;
            catch(AnswerConvException)
            {}
        }

        throw new Exception("unsupported parameter $"~(i+1).to!string~" type: "~t.to!string, __FILE__, __LINE__);
    }

    // Result fields type check
    resultTypesLoop:
    foreach(i; 0 .. desc.columnCount)
    {
        auto t = desc.OID(i);

        foreach(sup; resultSupportedTypes)
        {
            try
                if(t == sup || t == oidConvTo!"array"(sup)) continue resultTypesLoop;
            catch(AnswerConvException)
            {}
        }

        throw new Exception("unsupported result field "~desc.columnName(i)~" ("~i.to!string~") type: "~t.to!string, __FILE__, __LINE__);
    }

    return ret;
}

private immutable OidType[] argsSupportedTypes =
[
    OidType.Bool,
    OidType.Int4,
    OidType.Int8,
    OidType.Float8,
    OidType.Text,
    OidType.Json
];

private immutable OidType[] resultSupportedTypes = argsSupportedTypes ~
[
    OidType.Numeric,
    OidType.FixedString,
    //OidType.UUID
];
