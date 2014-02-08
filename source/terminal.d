// Written in D programming language
/**
*    Describes server attached to tty console. Specified delegate 
*    is called when SIGHUP signal is caught (linux only).
*
*    See_Also: daemon
*    Authors: NCrashed <ncrashed@gmail.com>
*    
*/
module terminal;

import std.c.stdlib;
import std.stdio;
import std.conv;
version (linux) import std.c.linux.linux;
import log;

private 
{
    void delegate() savedListener;
    extern (C) 
    {
        version (linux) 
        {
            // Signal trapping in Linux
            alias void function(int) sighandler_t;
            sighandler_t signal(int signum, sighandler_t handler);
            
            void sighandler(int sig)
            {
                logInfo("Signal %d caught..." ~ to!string(sig));
                savedListener();
            }
        }
    }
}

/**
*    Run application as casual process (attached to tty) with $(B progMain) main function and passes $(B args) into it. 
*    Function also initializes logging system with $(B logFile) name. If daemon catches SIGHUP signal, $(B listener)
*    delegate is called (available on linux only).
*/
int runTerminal(string logFile, int function(string[]) progMain, string[] args, void delegate() listener)
{
    initLoggingSystem(logFile, false);
        
    version (linux) 
    {
        savedListener = listener;
        signal(SIGHUP, &sighandler);
    } else
    {
        logError("This platform doesn't support signals. Updating json-sql table by signal is disabled!");
    }

    logInfo("Server is starting in terminal mode...");
    return progMain(args);
}