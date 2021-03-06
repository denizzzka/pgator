module pgator.sql_transaction;

import pgator.rpc_table;
import pgator.app;
import vibe.db.postgresql;

struct TransactionQueryParams
{
    QueryParams[] queryParams;
    AuthorizationCredentials auth;
}

struct SQLTransaction
{
    private LockedConnection!__Conn conn;
    private bool isCommitDone = false;

    @disable this(this){}

    this(shared PostgresClient client, bool isReadOnly)
    {
        conn = client.lockConnection();

        import vibe.core.log;
        logDebugV("after lock connection");

        try
        {
            execBuiltIn(isReadOnly ? BuiltInPrep.BEGIN_RO : BuiltInPrep.BEGIN);
        }
        catch(ConnectionException e)
        {
            conn.dropConnection();
            delete conn;
            throw e;
        }
    }

    void commit()
    {
        execBuiltIn(BuiltInPrep.COMMIT);
        isCommitDone = true;
    }

    ~this()
    {
        if(conn.status == CONNECTION_BAD)
        {
            conn.dropConnection();
        }
        else
        {
            if(!isCommitDone)
                execBuiltIn(BuiltInPrep.ROLLBACK);
        }

        delete conn;
    }

    immutable(Answer)[] execMethod(in Method method, TransactionQueryParams qp)
    {
        assert(!isCommitDone);

        if(method.needAuthVariablesFlag)
        {
            QueryParams q;
            q.preparedStatementName = BuiltInPrep.SET_AUTH_VARS;
            q.args = [qp.auth.username.toValue, qp.auth.password.toValue];

            conn.execPreparedStatement(q);
        }

        immutable(Answer)[] ret;

        foreach(i, s; method.statements)
        {
            ret ~= conn.execPreparedStatement(qp.queryParams[i]);
        }

        return ret;
    }

    private void execBuiltIn(BuiltInPrep prepared)
    {
        QueryParams q;
        q.preparedStatementName = prepared;

        conn.execPreparedStatement(q);
    }
}

enum BuiltInPrep : string
{
    BEGIN = "#b#",
    BEGIN_RO = "#r#",
    COMMIT = "#C#",
    ROLLBACK = "#R#",
    SET_AUTH_VARS = "#a#"
}
