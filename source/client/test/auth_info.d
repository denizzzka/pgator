module client.test.auth_info;

import client.test.testcase;
import client.rpcapi;
import pgator.db.pool;

class AuthInfoTestCase : ITestCase
{
    protected void insertMethods(shared IConnectionPool pool, string tableName)
    {
        insertRow(pool, tableName,
            JsonRpcRow("with_auth", [0],
                ["SELECT current_setting('pgator.username') || current_setting('pgator.password') as user_pass"],
                true
            )
        );
    }
    
    /**
    *   Removes row describing method from json_rpc table after tests are finished.
    */
    protected void deleteMethods(shared IConnectionPool pool, string tableName)
    {
        removeRow(pool, tableName, "with_auth");
    }
    
    /**
    *   All testing procedures should be located here. Rpc-server is called and respond
    *   is checked to be an expected value.
    */
    protected void performTests(IRpcApi api)
    {
        auto with_auth = api.runRpc!"with_auth".assertOk!(Column!(string, "user_pass"));
        assert(with_auth.user_pass[0] == "Aladdinopen sesame");
    }
}
