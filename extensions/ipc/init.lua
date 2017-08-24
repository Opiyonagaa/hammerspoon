--- === hs.ipc ===
---
--- Provides Hammerspoon with the ability to create both local and remote message ports for inter-process communication.
---
--- The most common use of this module is to provide support for the command line tool `hs` which can be added to your terminal shell environment with [hs.ipc.cliInstall](#cliInstall).  The command line tool will not work unless the `hs.ipc` module is loaded first, so it is recommended that you add `require("hs.ipc")` to your Hammerspoon `init.lua` file (usually located at ~/.hammerspoon/init.lua) so that it is always available when Hammerspoon is running.
---
--- This module is based heavily on code from Mjolnir by [Steven Degutis](https://github.com/sdegutis/).

local USERDATA_TAG = "hs.ipc"
local module       = require(USERDATA_TAG..".internal")

local basePath = package.searchpath(USERDATA_TAG, package.path)
if basePath then
    basePath = basePath:match("^(.+)/init.lua$")
    if require"hs.fs".attributes(basePath .. "/docs.json") then
        require"hs.doc".registerJSONFile(basePath .. "/docs.json")
    end
end

local timer    = require("hs.timer")
local settings = require("hs.settings")
local log      = require("hs.logger").new(USERDATA_TAG, (settings.get(USERDATA_TAG .. ".logLevel") or "warning"))
local json     = require("hs.json")
local fnutils  = require("hs.fnutils")

-- private variables and methods -----------------------------------------

local MSG_ID = {
    REGISTER   = 100,   -- register an instance with the v2 cli
    UNREGISTER = 200,   -- unregister an instance with the v2 cli

    LEGACYCHK  = 900,   -- query to test if we are the v2 ipc or not (v1 will ignore the id and evaluate)
    COMMAND    = 500,   -- a command from the user from a v2 cli
    QUERY      = 501,   -- an internal query from the v2 cli

    LEGACY     =  0,    -- v1 cli/ipc only used the 0 msgID

    ERROR      = -1,    -- result was an error
    OUTPUT     =  1,    -- print output
    RETURN     =  2,    -- result
    CONSOLE    =  3,    -- cloned console output
}

local originalPrint = print
local printReplacement = function(...)
    originalPrint(...)
    for k,v in pairs(module.__registeredCLIInstances) do
        if v._cli.console and v.print and not v._cli.quietMode then
--            v.print(...)
-- make it more obvious what is console output versus the command line's
            local things = table.pack(...)
            local stdout = (things.n > 0) and tostring(things[1]) or ""
            for i = 2, things.n do
                stdout = stdout .. "\t" .. tostring(things[i])
            end
            v._cli.remote:sendMessage(stdout .. "\n", MSG_ID.CONSOLE)
        end
    end
end
print = printReplacement

-- Public interface ------------------------------------------------------

--- hs.ipc.cliColors([colors]) -> table
--- Function
--- Get or set the terminal escape codes used to produce colorized output in the `hs` command line tool
---
--- Parameters:
---  * colors - an optional table or explicit nil specifying the colors to use when colorizing output for the command line tool.  If you specify an explicit nil, the colors will revert to their defaults.  If you specify a table it must contain one or more of the following keys with the terminal key sequence as a string for the value:
---    * initial - this color is used for the initial tagline when starting the command line tool and for output to the Hammerspoon console that is redirected to the instance.  Defaults to "\27[35m" (foreground magenta).
---    * input   - this color is used for input typed in by the user into the cli instance.  Defaults to "\27[33m" (foreground yellow).
---    * output  - this color is used for output generated by the commands executed within the instance and the results returned.  Defaults to "\27[36m" (foreground cyan).
---    * error   - this color is used for lua errors generated by the commands executed within the instance.  Defaults to "\27[31m" (foreground red).
---
--- Returns:
---  * a table describing the colors used when colorizing output in the `hs` command line tool.
---
--- Notes:
---  * For a brief intro into terminal colors, you can visit a web site like this one [http://jafrog.com/2013/11/23/colors-in-terminal.html](http://jafrog.com/2013/11/23/colors-in-terminal.html)
---  * Lua doesn't support octal escapes in it's strings, so use `\x1b` or `\27` to indicate the `escape` character e.g. `ipc.cliSetColors{ initial = "", input = "\27[33m", output = "\27[38;5;11m" }`
---
---  * Changes made with this function are saved with `hs.settings` with the following labels and will persist through a reload or restart of Hammerspoon: "ipc.cli.color_initial", "ipc.cli.color_input", "ipc.cli.color_output", and "ipc.cli.color_error"
module.cliColors = function(...)
    local args = table.pack(...)
    if args.n > 0 then
        if type(args[1]) == "nil" then
            settings.clear("ipc.cli.color_initial")
            settings.clear("ipc.cli.color_input")
            settings.clear("ipc.cli.color_output")
            settings.clear("ipc.cli.color_error")
        else
            local colors = args[1]
            if colors.initial then settings.set("ipc.cli.color_initial", colors.initial) end
            if colors.input   then settings.set("ipc.cli.color_input",   colors.input)   end
            if colors.output  then settings.set("ipc.cli.color_output",  colors.output)  end
            if colors.error   then settings.set("ipc.cli.color_error",   colors.error)   end
        end
    end
    local colors = {}
    colors.initial = settings.get("ipc.cli.color_initial") or "\27[35m" ;
    colors.input   = settings.get("ipc.cli.color_input")   or "\27[33m" ;
    colors.output  = settings.get("ipc.cli.color_output")  or "\27[36m" ;
    colors.error   = settings.get("ipc.cli.color_error")   or "\27[31m" ;
    return setmetatable(colors, {
        __tostring = function(self)
            local res = ""
            for k,v in fnutils.sortByKeys(self) do res = res .. string.format("%-7s = %q\n", k, v) end
            return res
        end,
    })
end

--- hs.ipc.cliGetColors() -> table
--- Deprecated
--- See [hs.ipc.cliColors](#cliColors).
local seenDeprecatedGetColors = false
module.cliGetColors = function()
    if not seenDeprecatedGetColors then
        seenDeprecatedGetColors = true
        log.w("hs.ipc.cliGetColors is deprecated and may be removed in the future.  Please use hs.ipc.cliColors instead.")
    end
    return module.cliColors()
end

--- hs.ipc.cliSetColors(table) -> table
--- Deprecated
--- See [hs.ipc.cliColors](#cliColors).
local seenDeprecatedSetColors = false
module.cliSetColors = function(colors)
    if not seenDeprecatedSetColors then
        seenDeprecatedSetColors = true
        log.w("hs.ipc.cliSetColors is deprecated and may be removed in the future.  Please use hs.ipc.cliColors instead.")
    end
    return module.cliColors(colors)
end

--- hs.ipc.cliResetColors()
--- Deprecated
--- See [hs.ipc.cliColors](#cliColors).
local seenDeprecatedResetColors = false
module.cliResetColors = function()
    if not seenDeprecatedResetColors then
        seenDeprecatedResetColors = true
        log.w("hs.ipc.cliResetColors is deprecated and may be removed in the future.  Please use hs.ipc.cliColors instead.")
    end
    return module.cliColors(nil)
end

--- hs.ipc.cliSaveHistory([state]) -> boolean
--- Function
--- Get or set whether or not the command line tool saves a history of the commands you type.
---
--- Parameters:
---  * state - an optional boolean (default false) specifying whether or not a history of the commands you type into the command line tool should be saved between sessions.
---
--- Returns:
---  * the current, possibly changed, value
---
--- Notes:
---  * If this is enabled, your history is saved in `hs.configDir .. ".cli.history"`, which is usually "~/.hammerspoon/.cli.history".
---  * If you have multiple invocations of the command line tool running at the same time, only the history of the last one cleanly exited is saved; this is a limitation of the readline wrapper Apple has provided for libedit and at present no workaround is known.
---
---  * Changes made with this function are saved with `hs.settings` with the label "ipc.cli.saveHistory" and will persist through a reload or restart of Hammerspoon.
module.cliSaveHistory = function(...)
    local args = table.pack(...)
    if args.n > 0 then
        settings.set("ipc.cli.saveHistory", args[1] and true or nil)
    end
    return settings.get("ipc.cli.saveHistory") or false
end

--- hs.ipc.cliSaveHistorySize([size]) -> number
--- Function
--- Get or set whether the maximum number of commands saved when command line tool history saving is enabled.
---
--- Parameters:
---  * size - an optional integer (default 1000) specifying the maximum number of commands to save when [hs.ipc.cliSaveHistory](#cliSaveHistory) is set to true.
---
--- Returns:
---  * the current, possibly changed, value
---
--- Notes:
---  * When [hs.ipc.cliSaveHistory](#cliSaveHistory) is enabled, your history is saved in `hs.configDir .. ".cli.history"`, which is usually "~/.hammerspoon/.cli.history".
---  * If you have multiple invocations of the command line tool running at the same time, only the history of the last one cleanly exited is saved; this is a limitation of the readline wrapper Apple has provided for libedit and at present no workaround is known.
---
---  * Changes made with this function are saved with `hs.settings` with the label "ipc.cli.historyLimit" and will persist through a reload or restart of Hammerspoon.
module.cliSaveHistorySize = function(...)
    local args = table.pack(...)
    if args.n > 0 then
        settings.set("ipc.cli.historyLimit", math.tointeger(args[1]) or nil)
    end
    return settings.get("ipc.cli.historyLimit") or 1000
end

--- hs.ipc.cliStatus([path][,silent]) -> bool
--- Function
--- Gets the status of the `hs` command line tool
---
--- Parameters:
---  * path - An optional string containing a path to look for the `hs` tool. Defaults to `/usr/local`
---  * silent - An optional boolean indicating whether or not to print errors to the Hammerspoon Console
---
--- Returns:
---  * A boolean, true if the `hs` command line tool is correctly installed, otherwise false
module.cliStatus = function(path, silent)
    local path = path or "/usr/local"
    local mod_path = string.match(package.searchpath("hs.ipc",package.path), "^(.*)/init%.lua$")

    local silent = silent or false

    local bin_file = os.execute("[ -f \""..path.."/bin/hs\" ]")
    local man_file = os.execute("[ -f \""..path.."/share/man/man1/hs.1\" ]")
    local bin_link = os.execute("[ -L \""..path.."/bin/hs\" ]")
    local man_link = os.execute("[ -L \""..path.."/share/man/man1/hs.1\" ]")
    local bin_ours = os.execute("[ \""..path.."/bin/hs\" -ef \""..mod_path.."/bin/hs\" ]")
    local man_ours = os.execute("[ \""..path.."/share/man/man1/hs.1\" -ef \""..mod_path.."/share/man/man1/hs.1\" ]")

    local result = bin_file and man_file and bin_link and man_link and bin_ours and man_ours or false
    local broken = false

    if not bin_ours and bin_file then
        if not silent then
            print([[cli installation problem: 'hs' is not ours.]])
        end
        broken = true
    end
    if not man_ours and man_file then
        if not silent then
            print([[cli installation problem: 'hs.1' is not ours.]])
        end
        broken = true
    end
    if bin_file and not bin_link then
        if not silent then
            print([[cli installation problem: 'hs' is an independant file won't be updated when Hammerspoon is.]])
        end
        broken = true
    end
    if not bin_file and bin_link then
        if not silent then
            print([[cli installation problem: 'hs' is a dangling link.]])
        end
        broken = true
    end
    if man_file and not man_link then
        if not silent then
            print([[cli installation problem: man page for 'hs.1' is an independant file and won't be updated when Hammerspoon is.]])
        end
        broken = true
    end
    if not man_file and man_link then
        if not silent then
            print([[cli installation problem: man page for 'hs.1' is a dangling link.]])
        end
        broken = true
    end
    if ((bin_file and bin_link) and not (man_file and man_link)) or ((man_file and man_link) and not (bin_file and bin_link)) then
        if not silent then
            print([[cli installation problem: incomplete installation of 'hs' and 'hs.1'.]])
        end
        broken = true
    end

    return broken and "broken" or result
end

--- hs.ipc.cliInstall([path][,silent]) -> bool
--- Function
--- Installs the `hs` command line tool
---
--- Parameters:
---  * path - An optional string containing a path to install the tool in. Defaults to `/usr/local`
---  * silent - An optional boolean indicating whether or not to print errors to the Hammerspoon Console
---
--- Returns:
---  * A boolean, true if the tool was successfully installed, otherwise false
---
--- Notes:
---  * If this function fails, it is likely that you have some old/broken symlinks. You can use `hs.ipc.cliUninstall()` to forcibly tidy them up
module.cliInstall = function(path, silent)
    local path = path or "/usr/local"
    local silent = silent or false
    if module.cliStatus(path, true) == false then
        local mod_path = string.match(package.searchpath("hs.ipc",package.path), "^(.*)/init%.lua$")
        os.execute("ln -s \""..mod_path.."/bin/hs\" \""..path.."/bin/\"")
        os.execute("ln -s \""..mod_path.."/share/man/man1/hs.1\" \""..path.."/share/man/man1/\"")
    end
    return module.cliStatus(path, silent)
end

--- hs.ipc.cliUninstall([path][,silent]) -> bool
--- Function
--- Uninstalls the `hs` command line tool
---
--- Parameters:
---  * path - An optional string containing a path to remove the tool from. Defaults to `/usr/local`
---  * silent - An optional boolean indicating whether or not to print errors to the Hammerspoon Console
---
--- Returns:
---  * A boolean, true if the tool was successfully removed, otherwise false
---
--- Notes:
---  * This function used to be very conservative and refuse to remove symlinks it wasn't sure about, but now it will unconditionally remove whatever it finds at `path/bin/hs` and `path/share/man/man1/hs.1`. This is more likely to be useful in situations where this command is actually needed (please open an Issue on GitHub if you disagree!)
module.cliUninstall = function(path, silent)
    local path = path or "/usr/local"
    local silent = silent or false
    os.execute("rm \""..path.."/bin/hs\"")
    os.execute("rm \""..path.."/share/man/man1/hs.1\"")
    return not module.cliStatus(path, silent)
end

module.__registeredCLIInstances = {}
-- cleanup in case someone goes away without saying goodbye
module.__registeredInstanceCleanup = timer.doEvery(60, function()
    for k, v in pairs(module.__registeredCLIInstances) do
        if v._cli.remote and not v._cli.remote:isValid() then
            log.df("pruning %s; message port is no longer valid", k)
            v._cli.remote:delete()
            module.__registeredCLIInstances[k] = nil
        elseif not v._cli.remote then
            module.__registeredCLIInstances[k] = nil
        end
    end
end)

module.__defaultHandler = function(self, msgID, msg)
    if msgID == MSG_ID.LEGACYCHK then
        -- the message sent will be a mathematical equation; the original ipc will evaluate it because it ignored
        -- the msgid.  We send back a version string instead
        return "version:2.0a"
    elseif msgID == MSG_ID.REGISTER then      -- registering a new instance
        local instanceID, arguments = msg:match("^([%w-]+)\0(.*)$")
        if not instanceID then instanceID, arguments = msg, nil end
        local scriptArguments = nil
        local quietMode       = false
        local console         = "none"
        if arguments then
            arguments = json.decode(arguments)
            scriptArguments = {}
            local seenSeparator = false
            for i, v in ipairs(arguments) do
                if i > 1 and (v == "--" or v:match("^~") or v:match("^%.?/")) then seenSeparator = true end
                if seenSeparator then
                    table.insert(scriptArguments, v)
                else
                    if v == "-q" then quietMode = true end
                    if v == "-C" then console = "mirror" end
                    if v == "-P" then console = "legacy" end
                end
            end
            if #scriptArguments == 0 then scriptArguments = arguments end
        end
        log.df("registering %s", instanceID)

        module.__registeredCLIInstances[instanceID] = setmetatable({
            _cli = {
                remote    = module.remotePort(instanceID),
                console   = console,
                _args     = arguments,
                args      = scriptArguments,
                quietMode = quietMode,
            },
            print  = function(...)
                local parent = module.__registeredCLIInstances[instanceID]._cli
                if parent.quietMode then return end
                local things = table.pack(...)
                local stdout = (things.n > 0) and tostring(things[1]) or ""
                for i = 2, things.n do
                    stdout = stdout .. "\t" .. tostring(things[i])
                end
                module.__registeredCLIInstances[instanceID]._cli.remote:sendMessage(stdout .. "\n", MSG_ID.OUTPUT)
                if type(parent.console) == "nil" then
                    originalPrint(...)
                end
            end,
        }, {
            __index    = _G,
           __newindex = function(self, key, value)
               _G[key] = value
           end,
        })
    elseif msgID == MSG_ID.UNREGISTER then  -- unregistering an instance
        log.df("unregistering %s", msg)
        module.__registeredCLIInstances[msg]._cli.remote:delete()
        module.__registeredCLIInstances[msg] = nil
    elseif msgID == MSG_ID.COMMAND or msgID == MSG_ID.QUERY then
        local instanceID, code = msg:match("^([%w-]*)\0(.*)$")
--        print(msg, instanceID, code)
        if instanceID then

            if hs._consoleInputPreparser then
              if type(hs._consoleInputPreparser) == "function" then
                local status, code2 = pcall(hs._consoleInputPreparser, code)
                if status then
                  code = code2
                else
                  hs.luaSkinLog.ef("console preparse error: %s", code2)
                end
              else
                  hs.luaSkinLog.e("console preparser must be a function or nil")
              end
            end

            local fnEnv = module.__registeredCLIInstances[instanceID]
            local fn, err = load("return " .. code, "return " .. code, "bt", fnEnv)
            if not fn then fn, err = load(code, code, "bt", fnEnv) end
            local results = fn and table.pack(pcall(fn)) or { false, err, n = 2 }

            local str = (results.n > 1) and tostring(results[2]) or ""
            for i = 3, results.n do
                str = str .. "\t" .. tostring(results[i])
            end

            if #str > 0 then str = str .. "\n" end
            if msgID == MSG_ID.COMMAND then
                fnEnv._cli.remote:sendMessage(str, results[1] and MSG_ID.RETURN or MSG_ID.ERROR)
                return results[1] and "ok" or "error"
            else
                return str
            end
        else
            log.ef("unexpected message received: %s", msg)
        end
    elseif msgID == MSG_ID.LEGACY then
        log.df("in legacy handler")
        local raw, str = (msg:sub(1,1) == "r"), msg:sub(2)

        if hs._consoleInputPreparser then
          if type(hs._consoleInputPreparser) == "function" then
            local status, s2 = pcall(hs._consoleInputPreparser, str)
            if status then
              str = s2
            else
              hs.luaSkinLog.ef("console preparse error: %s", s2)
            end
          else
              hs.luaSkinLog.e("console preparser must be a function or nil")
          end
        end

        local originalprint = print
        local fakestdout = ""
        print = function(...)
            originalprint(...)
            local things = table.pack(...)
            for i = 1, things.n do
                if i > 1 then fakestdout = fakestdout .. "\t" end
                fakestdout = fakestdout .. tostring(things[i])
            end
            fakestdout = fakestdout .. "\n"
        end

--        local fn = raw and rawhandler or module.handler
        local fn = function(str)
            local fn, err = load("return " .. str)
            if not fn then fn, err = load(str) end
            if fn then return fn() else return err end
        end

        local results = table.pack(pcall(function() return fn(str) end))

        local str = ""
        for i = 2, results.n do
            if i > 2 then str = str .. "\t" end
            str = str .. tostring(results[i])
        end

        print = originalprint
        return fakestdout .. str
    else
        log.ef("unexpected message id received: %d, %s", msgID, msg)
    end
end

module.__default = module.localPort("CommandPost", module.__defaultHandler)

-- Return Module Object --------------------------------------------------

return setmetatable(module, {
    __index = function(self, key)
        if key == "handler" then
            log.e("Setting a specialized handler is no longer supported in hs.ipc. Use `hs.ipc.localPort` to setup your own message port for handling custom requests.")
            return nil
        else
            return rawget(self, key) -- probably not necessary, but...
        end
    end,
    __newindex = function(self, key, value)
        if key == "handler" then
            log.e("Setting a specialized handler is no longer supported in hs.ipc. Use `hs.ipc.localPort` to setup your own message port for handling custom requests.")
        else
            rawset(self, key, value)
        end
    end,
})
