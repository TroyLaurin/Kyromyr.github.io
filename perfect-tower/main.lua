DEBUG = not fengari;
package.path = "scripts/?.lua";

local line_number;
local _cache = {};

for _, lib in ipairs {"base64", "lexer-functions", "lexer-operators", "lexer-tokens", "lexer-debug", "lexer"} do
	if DEBUG then
		dofile(package.path:gsub("?", lib));
	else
		require(lib);
	end
end

if not DEBUG then
	local js = require"js";
	local window = js.global;
	local document = window.document;

	local output = document:getElementById("output");
	local lua_arg = document:getElementById("lua_arg");

	local assert_old = assert;

	local function assert_lexer(test, msg)
		if not test then
			assert_old(false, string.format("GSUB_HERE%s: %s", line_number, msg));
		end

		return test;
	end

	function lua_main(func)
		-- window.console.clear();

		if func == "compile" then
			assert = assert_lexer;
			local status, ret = pcall(compile, lua_arg.value, window.editor:getValue());
			assert = assert_old;

			if status then
				output.value = ret;
			else
				output.value = ret:gsub(".*GSUB_HERE", "");
			end
		elseif func == "import" then
			local status, ret = pcall(import, lua_arg.value);

			if status then
				return ret;
			else
				output.value = ret;
			end
		elseif func == "unittest" then
			local status, ret = pcall(unittest);

			if not status then
				output.value = ret;
			end
		else
			assert(false, "BUG REPORT: unknown lua_main function: " .. func);
		end
	end

	local elem = document:getElementById("functionList");
	elem.innerHTML = FUNCTION_LIST;
end

local function cache(line, variables)
	local key = {};

	for k, v in pairs (variables) do
		table.insert(key, string.format("%s.%s.%s", v.scope, v.type, v.name));
	end

	table.sort(key);
	table.insert(key, line);
	key = table.concat(key, "¤");

	if not _cache[key] then
		_cache[key] = lexer(line, variables);
	end

	return _cache[key];
end

function compile(name, input, testing)
	local labels, variables, impulses, conditions, actions = {}, {}, {}, {}, {};
	local ret = {};
	line_number = 0;
	labels["99"] = 99;

	for line in input:gmatch"[^\n]*" do
		line_number = line_number + 1;

		if line:match"^:" then
			local scope, type, name = line:sub(2):match("^(%a+) (%a+) " .. TOKEN.identifier.patternAnywhere .."$");
			assert(scope, "variable definition: [global/local] [int/double] name");

			name = name:lower();
			assert(scope == "global" or scope == "local", "variable scopes are 'global' and 'local'");
			assert(type == "int" or type == "double", "variable types are 'int' and 'double'");
			assert(not variables[name], "variable already exists: " .. name);
			
			variables[name] = {name = name, scope = scope, type = type};
		else
			local label;
			line = line
				:gsub("^%s*([%w%.]+):", function(a) label = a; return ""; end)
				:gsub("^%s+", ""):gsub("%s+$", "")
			;

			if #line > 0 then
				local node = cache(line, variables);

				if node.func.ret == "impulse" then
					table.insert(impulses, node);
				elseif node.func.ret == "bool" then
					table.insert(conditions, node);
				elseif node.func.ret == "void" then
					table.insert(actions, node);

					if label then
						labels[label] = #actions;
					end
				end
			end
		end
	end

	local function ins(frmt, val)
		table.insert(ret, string.pack(frmt, val));
	end

	local function encode(node)
		if node.func then
			ins("s1", node.func.name);

			for _, arg in ipairs (node.args) do
				encode(arg);
			end
		else
			ins("s1", "constant");

			if node.type == "bool" then
				ins("b", 1);
				ins("b", node.value and 1 or 0);
			elseif node.type == "number" then
				if math.type(node.value) == "integer" then
					ins("b", 2);
					ins("i4", node.value);
				else
					ins("b", 3);
					ins("d", node.value);
				end
			elseif node.type == "string" then
				ins("b", 4);
				ins("s1", node.value);
			elseif node.type == "vector" then
				ins("b", 5);
				ins("f", node.x);
				ins("f", node.y);
			elseif node.type == "operator" then
				ins("b", 4);

				if node.value == "%" then
					node.value = "mod";
				elseif node.value == "^" then
					node.value = "pow";
				elseif node.value == "//" then
					node.value = "log";
				end

				ins("s1", node.value);
			elseif node.type == "label" then
				ins("b", 2);
				ins("i4", assert(labels[node.value], "unknown label: " .. node.value));
			else
				assert(false, "BUG REPORT: unknown compile type: " .. node.type);
			end
		end
	end

	ins("s1", name);

	for _, tbl in ipairs {impulses, conditions, actions} do
		ins("i4", #tbl);

		for _, line in ipairs (tbl) do
			encode(line);
		end
	end

	ret = base64.encode(table.concat(ret));
	return testing and ret or string.format("%s\n%s %s %s\n%s", name, #impulses, #conditions, #actions, ret);
end

function import(input)
	local data = base64.decode(input);
	local pos = 1;

	local variables = {};
	local ret = {};
	
	local function read(frmt)
		local ret, new = string.unpack(frmt, data, pos);
		pos = new;
		return ret;
	end

	local function stripParens(text)
		return tostring(text):gsub("^%b()", function(a) return a:sub(2,-2); end);
	end
	
	local function parse()
		local func = read"s1";
		
		if func == "constant" then
			local type = read"b";
			
			if type == 1 then
				return string.format("%s", read"b" == 1 and "true" or "false");
			elseif type == 2 then
				return string.format("%s", read"i4");
			elseif type == 3 then
				return string.format("%s", read"d");
			elseif type == 4 then
				return string.format('"%s"', read"s1");
			elseif type == 5 then
				return string.format("vec(%s, %s)", read"f", read"f");
			else
				assert(false, "BUG REPORT: unknown constant type: " .. type);
			end
		else
			local func = assert(FUNCTION[func], "BUG REPORT: unknown function: " .. func);
			local args = {};
			
			for i, arg in ipairs (func.args) do
				table.insert(args, parse());
				
				if arg:match"^op_" then
					args[i] = args[i]:sub(2,-2):lower()
						:gsub("&&", "&")
						:gsub("||", "|")
						:gsub("^=$", "==")
						:gsub("mod", "%%")
						:gsub("pow", "^")
						:gsub("log", "//")
					;
				end
			end

			local scope, type, func_name = func.name:match"(%a+).(%a+).(%a+)";

			if scope == "global" or scope == "local" then
				local var = args[1]:sub(2,-2):lower();

				if var == var:match(TOKEN.identifier.pattern) then
					if not variables[var] then
						local key = string.format(":%s %s %s", scope, type, var);
						variables[key] = true;
					end

					return func_name == "set" and string.format("%s = %s", var, stripParens(args[2])) or var;
				end
			elseif func.name:match"^arithmetic" or func.name:match"^comparison" then
				return string.format("(%s)", table.concat(args, " "));
			end

			for k, v in ipairs (args) do
				args[k] = stripParens(v);
			end

			return string.format("%s(%s)", func.short, table.concat(args, ", "));
		end
	end

	local function ins(val)
		local text = stripParens(val);
		table.insert(ret, text);

		return val;
	end

	local name = read"s1";

	for i = 1, 3 do
		for j = 1, read"i4" do
			ins(parse());
			
			if i == 3 then
				ins(string.format("%s: %s", j, table.remove(ret)));
			end
		end

		ins"";
	end

	table.insert(ret, 1, "");

	for var in pairs (variables) do
		table.insert(ret, 1, var);
	end

	table.remove(ret);
	ret = table.concat(ret, "\n"):gsub("\n\n+", "\n\n"):gsub("^\n", ""):gsub("\n$", "");
	return {name, ret};
end

function unittest()
	local tests = {
"C2dsb2JhbF90aWVyAQAAAAVrZXkuMQAAAAABAAAADmdsb2JhbC5pbnQuc2V0CGNvbnN0YW50BAR0aWVyDmFyaXRobWV0aWMuaW50DmFyaXRobWV0aWMuaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BANtb2QIY29uc3RhbnQCCgAAAAhjb25zdGFudAQBKwhjb25zdGFudAIBAAAA",
"EEdMT0JBTF9DT1VOVGRvd24BAAAABWtleS4yAAAAAAYAAAAOZ2VuZXJpYy5nb3RvaWYIY29uc3RhbnQCAwAAABFjb21wYXJpc29uLmRvdWJsZRFnbG9iYWwuZG91YmxlLmdldAhjb25zdGFudAQFY291bnQIY29uc3RhbnQEATwIY29uc3RhbnQDAAAAAAAA8D8QbG9jYWwuZG91YmxlLnNldAhjb25zdGFudAQDcG93DGRvdWJsZS5mbG9vchFhcml0aG1ldGljLmRvdWJsZQhjb25zdGFudAN7FK5H4XqEvwhjb25zdGFudAQBKxFhcml0aG1ldGljLmRvdWJsZRFnbG9iYWwuZG91YmxlLmdldAhjb25zdGFudAQFY291bnQIY29uc3RhbnQEA2xvZwhjb25zdGFudAMAAAAAAAAkQA1sb2NhbC5pbnQuc2V0CGNvbnN0YW50BANpbmMOYXJpdGhtZXRpYy5pbnQIY29uc3RhbnQCCgAAAAhjb25zdGFudAQDcG93A2QyaRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BANwb3cQbG9jYWwuZG91YmxlLnNldAhjb25zdGFudAQDdG1wEWFyaXRobWV0aWMuZG91YmxlEWdsb2JhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAVjb3VudAhjb25zdGFudAQBLQNpMmQNbG9jYWwuaW50LmdldAhjb25zdGFudAQDaW5jDmdlbmVyaWMuZ290b2lmCGNvbnN0YW50AmMAAAARY29tcGFyaXNvbi5kb3VibGUQbG9jYWwuZG91YmxlLmdldAhjb25zdGFudAQDdG1wCGNvbnN0YW50BAE8CGNvbnN0YW50AwAAAAAAAPA/EWdsb2JhbC5kb3VibGUuc2V0CGNvbnN0YW50BAVjb3VudBBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAN0bXA=",
"DkdMT0JBTF9DT1VOVFVQAQAAAAVrZXkuMwAAAAAGAAAADmdlbmVyaWMuZ290b2lmCGNvbnN0YW50AmMAAAARY29tcGFyaXNvbi5kb3VibGURZ2xvYmFsLmRvdWJsZS5nZXQIY29uc3RhbnQEBWNvdW50CGNvbnN0YW50BAE+CGNvbnN0YW50AwAAAACIKmFBDmdlbmVyaWMuZ290b2lmCGNvbnN0YW50AgQAAAARY29tcGFyaXNvbi5kb3VibGURZ2xvYmFsLmRvdWJsZS5nZXQIY29uc3RhbnQEBWNvdW50CGNvbnN0YW50BAE8CGNvbnN0YW50AwAAAAAAAPA/EGxvY2FsLmRvdWJsZS5zZXQIY29uc3RhbnQEA3Bvdwxkb3VibGUuZmxvb3IRYXJpdGhtZXRpYy5kb3VibGUIY29uc3RhbnQDexSuR+F6hD8IY29uc3RhbnQEASsRYXJpdGhtZXRpYy5kb3VibGURZ2xvYmFsLmRvdWJsZS5nZXQIY29uc3RhbnQEBWNvdW50CGNvbnN0YW50BANsb2cIY29uc3RhbnQDAAAAAAAAJEANbG9jYWwuaW50LnNldAhjb25zdGFudAQDaW5jDmFyaXRobWV0aWMuaW50CGNvbnN0YW50AgoAAAAIY29uc3RhbnQEA3BvdwNkMmkQbG9jYWwuZG91YmxlLmdldAhjb25zdGFudAQDcG93EGxvY2FsLmRvdWJsZS5zZXQIY29uc3RhbnQEA3RtcBFhcml0aG1ldGljLmRvdWJsZRFnbG9iYWwuZG91YmxlLmdldAhjb25zdGFudAQFY291bnQIY29uc3RhbnQEASsDaTJkDWxvY2FsLmludC5nZXQIY29uc3RhbnQEA2luYxFnbG9iYWwuZG91YmxlLnNldAhjb25zdGFudAQFY291bnQQbG9jYWwuZG91YmxlLmdldAhjb25zdGFudAQDdG1w",
"E2dsb2JhbF9jaG9vc2VfY3JhZnQBAAAABWtleS40AAAAAAEAAAAOZ2xvYmFsLmludC5zZXQIY29uc3RhbnQEBk9VVFBVVA5hcml0aG1ldGljLmludA5hcml0aG1ldGljLmludA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQGT1VUUFVUCGNvbnN0YW50BANtb2QIY29uc3RhbnQCBQAAAAhjb25zdGFudAQBKwhjb25zdGFudAIBAAAA",
"D0xPQ19TRVRfRkFDVE9SWQEAAAAMb3Blbi5mYWN0b3J5AAAAAAEAAAAOZ2xvYmFsLmludC5zZXQIY29uc3RhbnQECGxvY2F0aW9uCGNvbnN0YW50AgMAAAA=",
"DWZhY3RvcnlfY3JhZnQBAAAABWtleS4wAQAAAA9jb21wYXJpc29uLmJvb2wOY29tcGFyaXNvbi5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQECGxvY2F0aW9uCGNvbnN0YW50BAI9PQhjb25zdGFudAIDAAAACGNvbnN0YW50BAImJg5jb21wYXJpc29uLmludA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQIY3JhZnRpbmcIY29uc3RhbnQEAj09CGNvbnN0YW50AgAAAAADAAAADmdsb2JhbC5pbnQuc2V0CGNvbnN0YW50BAhjcmFmdGluZwhjb25zdGFudAIBAAAAE2dlbmVyaWMuZXhlY3V0ZXN5bmMGY29uY2F0CGNvbnN0YW50BA5mYWN0b3J5X2NyYWZ0XwNpMnMOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBm91dHB1dA5nbG9iYWwuaW50LnNldAhjb25zdGFudAQIY3JhZnRpbmcIY29uc3RhbnQCAAAAAA==",
"D0ZBQ1RPUllfQ1JBRlRfMQAAAAAAAAAACQAAAA5nZW5lcmljLmdvdG9pZghjb25zdGFudAJjAAAADmNvbXBhcmlzb24uaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAE+CGNvbnN0YW50AgUAAAATZ2VuZXJpYy5leGVjdXRlc3luYwhjb25zdGFudAQXZmFjdG9yeV9jcmFmdF8xX2luY2hpcHMOZ2xvYmFsLmludC5zZXQIY29uc3RhbnQEDGNyYWZ0MV9zdGF0ZQhjb25zdGFudAIBAAAAD2dlbmVyaWMuZXhlY3V0ZQhjb25zdGFudAQSZmFjdG9yeV9jcmFmdF8xXzFBE2dlbmVyaWMuZXhlY3V0ZXN5bmMIY29uc3RhbnQEEmZhY3RvcnlfY3JhZnRfMV8xQhNnZW5lcmljLmV4ZWN1dGVzeW5jCGNvbnN0YW50BBFmYWN0b3J5X2NyYWZ0XzFfMhFnZW5lcmljLndhaXR3aGlsZRZmYWN0b3J5Lm1hY2hpbmUuYWN0aXZlCGNvbnN0YW50BAlhc3NlbWJsZXIRZ2VuZXJpYy53YWl0d2hpbGUOY29tcGFyaXNvbi5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEDGNyYWZ0MV9zdGF0ZQhjb25zdGFudAQBPAhjb25zdGFudAIPAAAADWZhY3RvcnkuY3JhZnQIY29uc3RhbnQEBGNoaXAOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIRZ2xvYmFsLmRvdWJsZS5nZXQIY29uc3RhbnQEBWNvdW50",
"F2ZhY3RvcnlfY3JhZnRfMV9pbmNoaXBzAAAAAAAAAAAKAAAADmdlbmVyaWMuZ290b2lmCGNvbnN0YW50AmMAAAAOY29tcGFyaXNvbi5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIIY29uc3RhbnQEAj09CGNvbnN0YW50AgEAAAAQbG9jYWwuZG91YmxlLnNldAhjb25zdGFudAQGdGFyZ2V0EWFyaXRobWV0aWMuZG91YmxlCmRvdWJsZS5taW4RYXJpdGhtZXRpYy5kb3VibGUIY29uc3RhbnQDAAAAAAAAEEAIY29uc3RhbnQEASoRYXJpdGhtZXRpYy5kb3VibGUDaTJkDmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAEtCGNvbnN0YW50AwAAAAAAAPA/CGNvbnN0YW50AwAAAAAAAChACGNvbnN0YW50BAEqEWdsb2JhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAVjb3VudA5nZW5lcmljLmdvdG9pZghjb25zdGFudAJjAAAAEWNvbXBhcmlzb24uZG91YmxlE2ZhY3RvcnkuaXRlbXMuY291bnQIY29uc3RhbnQEBGNoaXAOYXJpdGhtZXRpYy5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIIY29uc3RhbnQEAS0IY29uc3RhbnQCAQAAAAhjb25zdGFudAQCPj0QbG9jYWwuZG91YmxlLmdldAhjb25zdGFudAQGdGFyZ2V0DWxvY2FsLmludC5zZXQIY29uc3RhbnQEBm15dGllcg5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllchBsb2NhbC5kb3VibGUuc2V0CGNvbnN0YW50BAdteWNvdW50EWdsb2JhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAVjb3VudA5nbG9iYWwuaW50LnNldAhjb25zdGFudAQEdGllcg5hcml0aG1ldGljLmludA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQBLQhjb25zdGFudAIBAAAAEWdsb2JhbC5kb3VibGUuc2V0CGNvbnN0YW50BAVjb3VudBFhcml0aG1ldGljLmRvdWJsZRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAZ0YXJnZXQIY29uc3RhbnQEAS0TZmFjdG9yeS5pdGVtcy5jb3VudAhjb25zdGFudAQEY2hpcA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllchNnZW5lcmljLmV4ZWN1dGVzeW5jCGNvbnN0YW50BA9mYWN0b3J5X2NyYWZ0XzEOZ2xvYmFsLmludC5zZXQIY29uc3RhbnQEBHRpZXINbG9jYWwuaW50LmdldAhjb25zdGFudAQGbXl0aWVyEWdsb2JhbC5kb3VibGUuc2V0CGNvbnN0YW50BAVjb3VudBBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAdteWNvdW50",
"EkZBQ1RPUllfY3JhZnRfMV8xYQAAAAABAAAADmNvbXBhcmlzb24uaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAhsb2NhdGlvbghjb25zdGFudAQCPT0IY29uc3RhbnQCAwAAAAkAAAAQbG9jYWwuZG91YmxlLnNldAhjb25zdGFudAQIYm9hcmRfbG8RYXJpdGhtZXRpYy5kb3VibGURZ2xvYmFsLmRvdWJsZS5nZXQIY29uc3RhbnQEBWNvdW50CGNvbnN0YW50BAEqEWFyaXRobWV0aWMuZG91YmxlDGRvdWJsZS5mbG9vchFhcml0aG1ldGljLmRvdWJsZQhjb25zdGFudAMAAAAANGEqQQhjb25zdGFudAQBLxFhcml0aG1ldGljLmRvdWJsZQhjb25zdGFudAMAAAAAAAAkQAhjb25zdGFudAQDcG93A2kyZA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQDbW9kCGNvbnN0YW50AwAAAAAAACRAEGxvY2FsLmRvdWJsZS5zZXQIY29uc3RhbnQECGJvYXJkX2hpEWFyaXRobWV0aWMuZG91YmxlEWdsb2JhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAVjb3VudAhjb25zdGFudAQBKhFhcml0aG1ldGljLmRvdWJsZQxkb3VibGUuZmxvb3IRYXJpdGhtZXRpYy5kb3VibGUIY29uc3RhbnQDAAAAAARQKkEIY29uc3RhbnQEAS8RYXJpdGhtZXRpYy5kb3VibGUIY29uc3RhbnQDAAAAAAAAJEAIY29uc3RhbnQEA3BvdwNpMmQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIIY29uc3RhbnQEA21vZAhjb25zdGFudAMAAAAAAAAkQBFnZW5lcmljLndhaXR3aGlsZRZmYWN0b3J5Lm1hY2hpbmUuYWN0aXZlCGNvbnN0YW50BAdwcmVzc2VyD2ZhY3RvcnkucHJvZHVjZQhjb25zdGFudAQFaW5nb3QOYXJpdGhtZXRpYy5pbnQOYXJpdGhtZXRpYy5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIIY29uc3RhbnQEASoIY29uc3RhbnQCAgAAAAhjb25zdGFudAQBLQhjb25zdGFudAIBAAAAEWFyaXRobWV0aWMuZG91YmxlEWFyaXRobWV0aWMuZG91YmxlEGxvY2FsLmRvdWJsZS5nZXQIY29uc3RhbnQECGJvYXJkX2xvCGNvbnN0YW50BAEtE2ZhY3RvcnkuaXRlbXMuY291bnQIY29uc3RhbnQEDXBsYXRlLmNpcmN1aXQOYXJpdGhtZXRpYy5pbnQOYXJpdGhtZXRpYy5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIIY29uc3RhbnQEASoIY29uc3RhbnQCAgAAAAhjb25zdGFudAQBLQhjb25zdGFudAIBAAAACGNvbnN0YW50BAEtE2ZhY3RvcnkuaXRlbXMuY291bnQIY29uc3RhbnQEBXBsYXRlDmFyaXRobWV0aWMuaW50DmFyaXRobWV0aWMuaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAEqCGNvbnN0YW50AgIAAAAIY29uc3RhbnQEAS0IY29uc3RhbnQCAQAAAAhjb25zdGFudAQHcHJlc3NlchFnZW5lcmljLndhaXR3aGlsZRZmYWN0b3J5Lm1hY2hpbmUuYWN0aXZlCGNvbnN0YW50BAdwcmVzc2VyDmdsb2JhbC5pbnQuc2V0CGNvbnN0YW50BAxjcmFmdDFfc3RhdGUOYXJpdGhtZXRpYy5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEDGNyYWZ0MV9zdGF0ZQhjb25zdGFudAQBKwhjb25zdGFudAICAAAAD2ZhY3RvcnkucHJvZHVjZQhjb25zdGFudAQFaW5nb3QOYXJpdGhtZXRpYy5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIIY29uc3RhbnQEASoIY29uc3RhbnQCAgAAABFhcml0aG1ldGljLmRvdWJsZRFhcml0aG1ldGljLmRvdWJsZRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAhib2FyZF9oaQhjb25zdGFudAQBLRNmYWN0b3J5Lml0ZW1zLmNvdW50CGNvbnN0YW50BA1wbGF0ZS5jaXJjdWl0DmFyaXRobWV0aWMuaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAEqCGNvbnN0YW50AgIAAAAIY29uc3RhbnQEAS0TZmFjdG9yeS5pdGVtcy5jb3VudAhjb25zdGFudAQFcGxhdGUOYXJpdGhtZXRpYy5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIIY29uc3RhbnQEASoIY29uc3RhbnQCAgAAAAhjb25zdGFudAQHcHJlc3NlchFnZW5lcmljLndhaXR3aGlsZRZmYWN0b3J5Lm1hY2hpbmUuYWN0aXZlCGNvbnN0YW50BAdwcmVzc2VyDmdsb2JhbC5pbnQuc2V0CGNvbnN0YW50BAxjcmFmdDFfc3RhdGUOYXJpdGhtZXRpYy5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEDGNyYWZ0MV9zdGF0ZQhjb25zdGFudAQBKwhjb25zdGFudAIEAAAA",
"EkZBQ1RPUllfY3JhZnRfMV8xYgAAAAABAAAADmNvbXBhcmlzb24uaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAhsb2NhdGlvbghjb25zdGFudAQCPT0IY29uc3RhbnQCAwAAAAsAAAAQbG9jYWwuZG91YmxlLnNldAhjb25zdGFudAQKY2lyY3VpdF9sbxFhcml0aG1ldGljLmRvdWJsZRFnbG9iYWwuZG91YmxlLmdldAhjb25zdGFudAQFY291bnQIY29uc3RhbnQEASoIY29uc3RhbnQDAAAAAAAAAEAQbG9jYWwuZG91YmxlLnNldAhjb25zdGFudAQKY2lyY3VpdF9oaRFhcml0aG1ldGljLmRvdWJsZRFnbG9iYWwuZG91YmxlLmdldAhjb25zdGFudAQFY291bnQIY29uc3RhbnQEASoRYXJpdGhtZXRpYy5kb3VibGUMZG91YmxlLmZsb29yEWFyaXRobWV0aWMuZG91YmxlCGNvbnN0YW50AwAAAAAgZQtBCGNvbnN0YW50BAEvEWFyaXRobWV0aWMuZG91YmxlCGNvbnN0YW50AwAAAAAAACRACGNvbnN0YW50BANwb3cDaTJkDmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BANtb2QIY29uc3RhbnQDAAAAAAAAJEARZ2VuZXJpYy53YWl0d2hpbGUWZmFjdG9yeS5tYWNoaW5lLmFjdGl2ZQhjb25zdGFudAQIcmVmaW5lcnkPZmFjdG9yeS5wcm9kdWNlCGNvbnN0YW50BAVpbmdvdA5hcml0aG1ldGljLmludA5hcml0aG1ldGljLmludA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQBKghjb25zdGFudAICAAAACGNvbnN0YW50BAEtCGNvbnN0YW50AgEAAAALZG91YmxlLmNlaWwRYXJpdGhtZXRpYy5kb3VibGURYXJpdGhtZXRpYy5kb3VibGURYXJpdGhtZXRpYy5kb3VibGUQbG9jYWwuZG91YmxlLmdldAhjb25zdGFudAQKY2lyY3VpdF9sbwhjb25zdGFudAQBLRNmYWN0b3J5Lml0ZW1zLmNvdW50CGNvbnN0YW50BAdjaXJjdWl0DmFyaXRobWV0aWMuaW50DmFyaXRobWV0aWMuaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAEqCGNvbnN0YW50AgIAAAAIY29uc3RhbnQEAS0IY29uc3RhbnQCAQAAAAhjb25zdGFudAQBLRNmYWN0b3J5Lml0ZW1zLmNvdW50CGNvbnN0YW50BAVjYWJsZQ5hcml0aG1ldGljLmludA5hcml0aG1ldGljLmludA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQBKghjb25zdGFudAICAAAACGNvbnN0YW50BAEtCGNvbnN0YW50AgEAAAAIY29uc3RhbnQEAS8IY29uc3RhbnQDAAAAAAAAAEAIY29uc3RhbnQECHJlZmluZXJ5EWdlbmVyaWMud2FpdHdoaWxlFmZhY3RvcnkubWFjaGluZS5hY3RpdmUIY29uc3RhbnQECHJlZmluZXJ5D2ZhY3RvcnkucHJvZHVjZQhjb25zdGFudAQFaW5nb3QOYXJpdGhtZXRpYy5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIIY29uc3RhbnQEASoIY29uc3RhbnQCAgAAAAtkb3VibGUuY2VpbBFhcml0aG1ldGljLmRvdWJsZRFhcml0aG1ldGljLmRvdWJsZRFhcml0aG1ldGljLmRvdWJsZRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BApjaXJjdWl0X2hpCGNvbnN0YW50BAEtE2ZhY3RvcnkuaXRlbXMuY291bnQIY29uc3RhbnQEB2NpcmN1aXQOYXJpdGhtZXRpYy5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIIY29uc3RhbnQEASoIY29uc3RhbnQCAgAAAAhjb25zdGFudAQBLRNmYWN0b3J5Lml0ZW1zLmNvdW50CGNvbnN0YW50BAVjYWJsZQ5hcml0aG1ldGljLmludA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQBKghjb25zdGFudAICAAAACGNvbnN0YW50BAEvCGNvbnN0YW50AwAAAAAAAABACGNvbnN0YW50BAhyZWZpbmVyeRFnZW5lcmljLndhaXR3aGlsZRZmYWN0b3J5Lm1hY2hpbmUuYWN0aXZlCGNvbnN0YW50BAlhc3NlbWJsZXIPZmFjdG9yeS5wcm9kdWNlCGNvbnN0YW50BAVjYWJsZQ5hcml0aG1ldGljLmludA5hcml0aG1ldGljLmludA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQBKghjb25zdGFudAICAAAACGNvbnN0YW50BAEtCGNvbnN0YW50AgEAAAARYXJpdGhtZXRpYy5kb3VibGUQbG9jYWwuZG91YmxlLmdldAhjb25zdGFudAQKY2lyY3VpdF9sbwhjb25zdGFudAQBLRNmYWN0b3J5Lml0ZW1zLmNvdW50CGNvbnN0YW50BAdjaXJjdWl0DmFyaXRobWV0aWMuaW50DmFyaXRobWV0aWMuaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAEqCGNvbnN0YW50AgIAAAAIY29uc3RhbnQEAS0IY29uc3RhbnQCAQAAAAhjb25zdGFudAQJYXNzZW1ibGVyEWdlbmVyaWMud2FpdHdoaWxlFmZhY3RvcnkubWFjaGluZS5hY3RpdmUIY29uc3RhbnQECHJlZmluZXJ5EWdlbmVyaWMud2FpdHdoaWxlFmZhY3RvcnkubWFjaGluZS5hY3RpdmUIY29uc3RhbnQECWFzc2VtYmxlcg9mYWN0b3J5LnByb2R1Y2UIY29uc3RhbnQEBWNhYmxlDmFyaXRobWV0aWMuaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAEqCGNvbnN0YW50AgIAAAARYXJpdGhtZXRpYy5kb3VibGUQbG9jYWwuZG91YmxlLmdldAhjb25zdGFudAQKY2lyY3VpdF9oaQhjb25zdGFudAQBLRNmYWN0b3J5Lml0ZW1zLmNvdW50CGNvbnN0YW50BAdjaXJjdWl0DmFyaXRobWV0aWMuaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAEqCGNvbnN0YW50AgIAAAAIY29uc3RhbnQECWFzc2VtYmxlcg==",
"EUZBQ1RPUllfY3JhZnRfMV8yAAAAAAEAAAAOY29tcGFyaXNvbi5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQECGxvY2F0aW9uCGNvbnN0YW50BAI9PQhjb25zdGFudAIDAAAACgAAABBsb2NhbC5kb3VibGUuc2V0CGNvbnN0YW50BAhib2FyZF9sbxFhcml0aG1ldGljLmRvdWJsZRFnbG9iYWwuZG91YmxlLmdldAhjb25zdGFudAQFY291bnQIY29uc3RhbnQEASoRYXJpdGhtZXRpYy5kb3VibGUMZG91YmxlLmZsb29yEWFyaXRobWV0aWMuZG91YmxlCGNvbnN0YW50AwAAAAA0YSpBCGNvbnN0YW50BAEvEWFyaXRobWV0aWMuZG91YmxlCGNvbnN0YW50AwAAAAAAACRACGNvbnN0YW50BANwb3cDaTJkDmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BANtb2QIY29uc3RhbnQDAAAAAAAAJEAQbG9jYWwuZG91YmxlLnNldAhjb25zdGFudAQIYm9hcmRfaGkRYXJpdGhtZXRpYy5kb3VibGURZ2xvYmFsLmRvdWJsZS5nZXQIY29uc3RhbnQEBWNvdW50CGNvbnN0YW50BAEqEWFyaXRobWV0aWMuZG91YmxlDGRvdWJsZS5mbG9vchFhcml0aG1ldGljLmRvdWJsZQhjb25zdGFudAMAAAAABFAqQQhjb25zdGFudAQBLxFhcml0aG1ldGljLmRvdWJsZQhjb25zdGFudAMAAAAAAAAkQAhjb25zdGFudAQDcG93A2kyZA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQDbW9kCGNvbnN0YW50AwAAAAAAACRAEWdlbmVyaWMud2FpdHdoaWxlDmNvbXBhcmlzb24uaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAxjcmFmdDFfc3RhdGUIY29uc3RhbnQEATwIY29uc3RhbnQCAwAAABFnZW5lcmljLndhaXR3aGlsZRZmYWN0b3J5Lm1hY2hpbmUuYWN0aXZlCGNvbnN0YW50BAhyZWZpbmVyeQ9mYWN0b3J5LnByb2R1Y2UIY29uc3RhbnQEBXBsYXRlDmFyaXRobWV0aWMuaW50DmFyaXRobWV0aWMuaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAEqCGNvbnN0YW50AgIAAAAIY29uc3RhbnQEAS0IY29uc3RhbnQCAQAAABFhcml0aG1ldGljLmRvdWJsZRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAhib2FyZF9sbwhjb25zdGFudAQBLRNmYWN0b3J5Lml0ZW1zLmNvdW50CGNvbnN0YW50BA1wbGF0ZS5jaXJjdWl0DmFyaXRobWV0aWMuaW50DmFyaXRobWV0aWMuaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAEqCGNvbnN0YW50AgIAAAAIY29uc3RhbnQEAS0IY29uc3RhbnQCAQAAAAhjb25zdGFudAQIcmVmaW5lcnkRZ2VuZXJpYy53YWl0d2hpbGUOY29tcGFyaXNvbi5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEDGNyYWZ0MV9zdGF0ZQhjb25zdGFudAQBPAhjb25zdGFudAIHAAAAEWdlbmVyaWMud2FpdHdoaWxlFmZhY3RvcnkubWFjaGluZS5hY3RpdmUIY29uc3RhbnQECHJlZmluZXJ5D2ZhY3RvcnkucHJvZHVjZQhjb25zdGFudAQFcGxhdGUOYXJpdGhtZXRpYy5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIIY29uc3RhbnQEASoIY29uc3RhbnQCAgAAABFhcml0aG1ldGljLmRvdWJsZRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAhib2FyZF9oaQhjb25zdGFudAQBLRNmYWN0b3J5Lml0ZW1zLmNvdW50CGNvbnN0YW50BA1wbGF0ZS5jaXJjdWl0DmFyaXRobWV0aWMuaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAEqCGNvbnN0YW50AgIAAAAIY29uc3RhbnQECHJlZmluZXJ5EWdlbmVyaWMud2FpdHdoaWxlFmZhY3RvcnkubWFjaGluZS5hY3RpdmUIY29uc3RhbnQECHJlZmluZXJ5Dmdsb2JhbC5pbnQuc2V0CGNvbnN0YW50BAxjcmFmdDFfc3RhdGUOYXJpdGhtZXRpYy5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEDGNyYWZ0MV9zdGF0ZQhjb25zdGFudAQBKwhjb25zdGFudAIIAAAA",
"D0ZBQ1RPUllfQ1JBRlRfMgAAAAAAAAAABgAAAA5nbG9iYWwuaW50LnNldAhjb25zdGFudAQMY3JhZnQyX3N0YXRlCGNvbnN0YW50AgEAAAAPZ2VuZXJpYy5leGVjdXRlCGNvbnN0YW50BBZmYWN0b3J5X2NyYWZ0XzJfcGxhdGVzD2dlbmVyaWMuZXhlY3V0ZQhjb25zdGFudAQVZmFjdG9yeV9jcmFmdF8yX2NvaWxzD2dlbmVyaWMuZXhlY3V0ZQhjb25zdGFudAQUZmFjdG9yeV9jcmFmdF8yX3JvZHMRZ2VuZXJpYy53YWl0dW50aWwOY29tcGFyaXNvbi5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEDGNyYWZ0Ml9zdGF0ZQhjb25zdGFudAQCPT0IY29uc3RhbnQCDwAAAA1mYWN0b3J5LmNyYWZ0CGNvbnN0YW50BAVtb3Rvcg5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllchFnbG9iYWwuZG91YmxlLmdldAhjb25zdGFudAQFY291bnQ=",
"FkZBQ1RPUllfQ1JBRlRfMl9wbGF0ZXMAAAAAAAAAAAYAAAAQbG9jYWwuZG91YmxlLnNldAhjb25zdGFudAQGdGFyZ2V0EWFyaXRobWV0aWMuZG91YmxlEWdsb2JhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAVjb3VudAhjb25zdGFudAQBKghjb25zdGFudAMAAAAAAAAQQA5nZW5lcmljLmdvdG9pZghjb25zdGFudAIGAAAAEWNvbXBhcmlzb24uZG91YmxlE2ZhY3RvcnkuaXRlbXMuY291bnQIY29uc3RhbnQEBXBsYXRlDmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAI+PRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAZ0YXJnZXQRZ2VuZXJpYy53YWl0d2hpbGUWZmFjdG9yeS5tYWNoaW5lLmFjdGl2ZQhjb25zdGFudAQHcHJlc3Nlcg9mYWN0b3J5LnByb2R1Y2UIY29uc3RhbnQEBWluZ290Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyEWFyaXRobWV0aWMuZG91YmxlEGxvY2FsLmRvdWJsZS5nZXQIY29uc3RhbnQEBnRhcmdldAhjb25zdGFudAQBLRNmYWN0b3J5Lml0ZW1zLmNvdW50CGNvbnN0YW50BAVwbGF0ZQ5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQHcHJlc3NlchFnZW5lcmljLndhaXR3aGlsZRZmYWN0b3J5Lm1hY2hpbmUuYWN0aXZlCGNvbnN0YW50BAdwcmVzc2VyDmdsb2JhbC5pbnQuc2V0CGNvbnN0YW50BAxjcmFmdDJfc3RhdGUOYXJpdGhtZXRpYy5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEDGNyYWZ0Ml9zdGF0ZQhjb25zdGFudAQBKwhjb25zdGFudAICAAAA",
"FUZBQ1RPUllfQ1JBRlRfMl9jb2lscwAAAAAAAAAACAAAABBsb2NhbC5kb3VibGUuc2V0CGNvbnN0YW50BApuZWVkX2NvaWxzEWFyaXRobWV0aWMuZG91YmxlEWdsb2JhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAVjb3VudAhjb25zdGFudAQBKghjb25zdGFudAMAAAAAAADwPw5nZW5lcmljLmdvdG9pZghjb25zdGFudAIFAAAAEWNvbXBhcmlzb24uZG91YmxlE2ZhY3RvcnkuaXRlbXMuY291bnQIY29uc3RhbnQEBWNhYmxlDmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAI+PRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BApuZWVkX2NvaWxzEWdlbmVyaWMud2FpdHdoaWxlFmZhY3RvcnkubWFjaGluZS5hY3RpdmUIY29uc3RhbnQECHJlZmluZXJ5D2ZhY3RvcnkucHJvZHVjZQhjb25zdGFudAQFaW5nb3QOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXILZG91YmxlLmNlaWwRYXJpdGhtZXRpYy5kb3VibGURYXJpdGhtZXRpYy5kb3VibGUQbG9jYWwuZG91YmxlLmdldAhjb25zdGFudAQKbmVlZF9jb2lscwhjb25zdGFudAQBLRNmYWN0b3J5Lml0ZW1zLmNvdW50CGNvbnN0YW50BAVjYWJsZQ5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQBLwhjb25zdGFudAMAAAAAAAAAQAhjb25zdGFudAQIcmVmaW5lcnkRZ2VuZXJpYy53YWl0d2hpbGUWZmFjdG9yeS5tYWNoaW5lLmFjdGl2ZQhjb25zdGFudAQIcmVmaW5lcnkPZmFjdG9yeS5wcm9kdWNlCGNvbnN0YW50BAVjYWJsZQ5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllchBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BApuZWVkX2NvaWxzCGNvbnN0YW50BAhyZWZpbmVyeRFnZW5lcmljLndhaXR3aGlsZRZmYWN0b3J5Lm1hY2hpbmUuYWN0aXZlCGNvbnN0YW50BAhyZWZpbmVyeQ5nbG9iYWwuaW50LnNldAhjb25zdGFudAQMY3JhZnQyX3N0YXRlDmFyaXRobWV0aWMuaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAxjcmFmdDJfc3RhdGUIY29uc3RhbnQEASsIY29uc3RhbnQCBAAAAA==",
"FEZBQ1RPUllfQ1JBRlRfMl9yb2RzAAAAAAAAAAAMAAAAEGxvY2FsLmRvdWJsZS5zZXQIY29uc3RhbnQEC25lZWRfc2NyZXdzCmRvdWJsZS5tYXgIY29uc3RhbnQDAAAAAAAAAAARYXJpdGhtZXRpYy5kb3VibGURZ2xvYmFsLmRvdWJsZS5nZXQIY29uc3RhbnQEBWNvdW50CGNvbnN0YW50BAEtE2ZhY3RvcnkuaXRlbXMuY291bnQIY29uc3RhbnQEBXNjcmV3Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyEGxvY2FsLmRvdWJsZS5zZXQIY29uc3RhbnQECW5lZWRfcm9kcwpkb3VibGUubWF4CGNvbnN0YW50AwAAAAAAAAAAEWFyaXRobWV0aWMuZG91YmxlEWFyaXRobWV0aWMuZG91YmxlEWFyaXRobWV0aWMuZG91YmxlEWdsb2JhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAVjb3VudAhjb25zdGFudAQBKghjb25zdGFudAMAAAAAAAAAQAhjb25zdGFudAQBKwtkb3VibGUuY2VpbBFhcml0aG1ldGljLmRvdWJsZRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAtuZWVkX3NjcmV3cwhjb25zdGFudAQBLwhjb25zdGFudAMAAAAAAAAQQAhjb25zdGFudAQBLRNmYWN0b3J5Lml0ZW1zLmNvdW50CGNvbnN0YW50BANyb2QOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIOZ2VuZXJpYy5nb3RvaWYIY29uc3RhbnQCBwAAABFjb21wYXJpc29uLmRvdWJsZRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAluZWVkX3JvZHMIY29uc3RhbnQEAj09CGNvbnN0YW50AwAAAAAAAAAAEWdlbmVyaWMud2FpdHdoaWxlFmZhY3RvcnkubWFjaGluZS5hY3RpdmUIY29uc3RhbnQEBnNoYXBlcg9mYWN0b3J5LnByb2R1Y2UIY29uc3RhbnQEBWluZ290Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyC2RvdWJsZS5jZWlsEWFyaXRobWV0aWMuZG91YmxlEGxvY2FsLmRvdWJsZS5nZXQIY29uc3RhbnQECW5lZWRfcm9kcwhjb25zdGFudAQBLwhjb25zdGFudAMAAAAAAAAAQAhjb25zdGFudAQGc2hhcGVyEWdlbmVyaWMud2FpdHVudGlsEWNvbXBhcmlzb24uZG91YmxlE2ZhY3RvcnkuaXRlbXMuY291bnQIY29uc3RhbnQEA3JvZA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQCPj0RYXJpdGhtZXRpYy5kb3VibGUQbG9jYWwuZG91YmxlLmdldAhjb25zdGFudAQLbmVlZF9zY3Jld3MIY29uc3RhbnQEAS8IY29uc3RhbnQDAAAAAAAAEEAOZ2VuZXJpYy5nb3RvaWYIY29uc3RhbnQCCwAAABFjb21wYXJpc29uLmRvdWJsZRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAtuZWVkX3NjcmV3cwhjb25zdGFudAQCPT0IY29uc3RhbnQDAAAAAAAAAAARZ2VuZXJpYy53YWl0d2hpbGUWZmFjdG9yeS5tYWNoaW5lLmFjdGl2ZQhjb25zdGFudAQGY3V0dGVyD2ZhY3RvcnkucHJvZHVjZQhjb25zdGFudAQDcm9kDmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyC2RvdWJsZS5jZWlsEWFyaXRobWV0aWMuZG91YmxlEGxvY2FsLmRvdWJsZS5nZXQIY29uc3RhbnQEC25lZWRfc2NyZXdzCGNvbnN0YW50BAEvCGNvbnN0YW50AwAAAAAAABBACGNvbnN0YW50BAZjdXR0ZXIRZ2VuZXJpYy53YWl0d2hpbGUWZmFjdG9yeS5tYWNoaW5lLmFjdGl2ZQhjb25zdGFudAQGY3V0dGVyEWdlbmVyaWMud2FpdHdoaWxlFmZhY3RvcnkubWFjaGluZS5hY3RpdmUIY29uc3RhbnQEBnNoYXBlcg5nbG9iYWwuaW50LnNldAhjb25zdGFudAQMY3JhZnQyX3N0YXRlDmFyaXRobWV0aWMuaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAxjcmFmdDJfc3RhdGUIY29uc3RhbnQEASsIY29uc3RhbnQCCAAAAA==",
"D0ZBQ1RPUllfQ1JBRlRfMwAAAAAAAAAABgAAAA5nbG9iYWwuaW50LnNldAhjb25zdGFudAQMY3JhZnQzX3N0YXRlCGNvbnN0YW50AgEAAAATZ2VuZXJpYy5leGVjdXRlc3luYwhjb25zdGFudAQPZmFjdG9yeV9jcmFmdF8yD2dlbmVyaWMuZXhlY3V0ZQhjb25zdGFudAQWZmFjdG9yeV9jcmFmdF8zX3BsYXRlcw9nZW5lcmljLmV4ZWN1dGUIY29uc3RhbnQEFWZhY3RvcnlfY3JhZnRfM19yaW5ncxFnZW5lcmljLndhaXR1bnRpbA5jb21wYXJpc29uLmludA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQMY3JhZnQyX3N0YXRlCGNvbnN0YW50BAI9PQhjb25zdGFudAIHAAAADWZhY3RvcnkuY3JhZnQIY29uc3RhbnQEBHB1bXAOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIRZ2xvYmFsLmRvdWJsZS5nZXQIY29uc3RhbnQEBWNvdW50",
"FkZBQ1RPUllfQ1JBRlRfM19wbGF0ZXMAAAAAAAAAAAsAAAAQbG9jYWwuZG91YmxlLnNldAhjb25zdGFudAQGdGFyZ2V0EWFyaXRobWV0aWMuZG91YmxlEWdsb2JhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAVjb3VudAhjb25zdGFudAQBKghjb25zdGFudAMAAAAAAAAAQA5nZW5lcmljLmdvdG9pZghjb25zdGFudAIGAAAAEWNvbXBhcmlzb24uZG91YmxlE2ZhY3RvcnkuaXRlbXMuY291bnQIY29uc3RhbnQEBXBsYXRlDmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAI+PRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAZ0YXJnZXQRZ2VuZXJpYy53YWl0d2hpbGUWZmFjdG9yeS5tYWNoaW5lLmFjdGl2ZQhjb25zdGFudAQHcHJlc3Nlcg9mYWN0b3J5LnByb2R1Y2UIY29uc3RhbnQEBWluZ290Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyEWFyaXRobWV0aWMuZG91YmxlEGxvY2FsLmRvdWJsZS5nZXQIY29uc3RhbnQEBnRhcmdldAhjb25zdGFudAQBLRNmYWN0b3J5Lml0ZW1zLmNvdW50CGNvbnN0YW50BAVwbGF0ZQ5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQHcHJlc3NlchFnZW5lcmljLndhaXR3aGlsZRZmYWN0b3J5Lm1hY2hpbmUuYWN0aXZlCGNvbnN0YW50BAdwcmVzc2VyEGxvY2FsLmRvdWJsZS5zZXQIY29uc3RhbnQEBnRhcmdldBFhcml0aG1ldGljLmRvdWJsZRFnbG9iYWwuZG91YmxlLmdldAhjb25zdGFudAQFY291bnQIY29uc3RhbnQEASoIY29uc3RhbnQDAAAAAAAAEEAOZ2VuZXJpYy5nb3RvaWYIY29uc3RhbnQCCwAAABFjb21wYXJpc29uLmRvdWJsZRNmYWN0b3J5Lml0ZW1zLmNvdW50CGNvbnN0YW50BAxwbGF0ZS5ydWJiZXIIY29uc3RhbnQCAQAAAAhjb25zdGFudAQCPj0QbG9jYWwuZG91YmxlLmdldAhjb25zdGFudAQGdGFyZ2V0EWdlbmVyaWMud2FpdHdoaWxlFmZhY3RvcnkubWFjaGluZS5hY3RpdmUIY29uc3RhbnQEB3ByZXNzZXIPZmFjdG9yeS5wcm9kdWNlCGNvbnN0YW50BAZydWJiZXIIY29uc3RhbnQCAQAAABFhcml0aG1ldGljLmRvdWJsZRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAZ0YXJnZXQIY29uc3RhbnQEAS0TZmFjdG9yeS5pdGVtcy5jb3VudAhjb25zdGFudAQMcGxhdGUucnViYmVyCGNvbnN0YW50AgEAAAAIY29uc3RhbnQEB3ByZXNzZXIRZ2VuZXJpYy53YWl0d2hpbGUWZmFjdG9yeS5tYWNoaW5lLmFjdGl2ZQhjb25zdGFudAQHcHJlc3Nlcg5nbG9iYWwuaW50LnNldAhjb25zdGFudAQMY3JhZnQzX3N0YXRlDmFyaXRobWV0aWMuaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAxjcmFmdDNfc3RhdGUIY29uc3RhbnQEASsIY29uc3RhbnQCAgAAAA==",
"FUZBQ1RPUllfQ1JBRlRfM19yaW5ncwAAAAAAAAAACQAAABBsb2NhbC5kb3VibGUuc2V0CGNvbnN0YW50BAZ0YXJnZXQRYXJpdGhtZXRpYy5kb3VibGURZ2xvYmFsLmRvdWJsZS5nZXQIY29uc3RhbnQEBWNvdW50CGNvbnN0YW50BAEqCGNvbnN0YW50AwAAAAAAAABADmdlbmVyaWMuZ290b2lmCGNvbnN0YW50AgkAAAARY29tcGFyaXNvbi5kb3VibGUTZmFjdG9yeS5pdGVtcy5jb3VudAhjb25zdGFudAQEcmluZw5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQCPj0QbG9jYWwuZG91YmxlLmdldAhjb25zdGFudAQGdGFyZ2V0DmdlbmVyaWMuZ290b2lmCGNvbnN0YW50AgYAAAARY29tcGFyaXNvbi5kb3VibGUTZmFjdG9yeS5pdGVtcy5jb3VudAhjb25zdGFudAQDcm9kDmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAI+PRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAZ0YXJnZXQRZ2VuZXJpYy53YWl0d2hpbGUWZmFjdG9yeS5tYWNoaW5lLmFjdGl2ZQhjb25zdGFudAQGc2hhcGVyD2ZhY3RvcnkucHJvZHVjZQhjb25zdGFudAQFaW5nb3QOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXILZG91YmxlLmNlaWwRYXJpdGhtZXRpYy5kb3VibGURYXJpdGhtZXRpYy5kb3VibGUQbG9jYWwuZG91YmxlLmdldAhjb25zdGFudAQGdGFyZ2V0CGNvbnN0YW50BAEtE2ZhY3RvcnkuaXRlbXMuY291bnQIY29uc3RhbnQEA3JvZA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQBLwhjb25zdGFudAMAAAAAAAAAQAhjb25zdGFudAQGc2hhcGVyEWdlbmVyaWMud2FpdHdoaWxlFmZhY3RvcnkubWFjaGluZS5hY3RpdmUIY29uc3RhbnQEBnNoYXBlcg9mYWN0b3J5LnByb2R1Y2UIY29uc3RhbnQEA3JvZA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllchFhcml0aG1ldGljLmRvdWJsZRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAZ0YXJnZXQIY29uc3RhbnQEAS0TZmFjdG9yeS5pdGVtcy5jb3VudAhjb25zdGFudAQEcmluZw5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQGc2hhcGVyEWdlbmVyaWMud2FpdHdoaWxlFmZhY3RvcnkubWFjaGluZS5hY3RpdmUIY29uc3RhbnQEBnNoYXBlcg5nbG9iYWwuaW50LnNldAhjb25zdGFudAQMY3JhZnQyX3N0YXRlDmFyaXRobWV0aWMuaW50Dmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAxjcmFmdDJfc3RhdGUIY29uc3RhbnQEASsIY29uc3RhbnQCBAAAAA==",
"D0ZBQ1RPUllfQ1JBRlRfNAAAAAAAAAAABQAAAA5nbG9iYWwuaW50LnNldAhjb25zdGFudAQMY3JhZnQ0X3N0YXRlCGNvbnN0YW50AgEAAAAPZ2VuZXJpYy5leGVjdXRlCGNvbnN0YW50BBZmYWN0b3J5X2NyYWZ0XzRfY2FibGVzD2dlbmVyaWMuZXhlY3V0ZQhjb25zdGFudAQWZmFjdG9yeV9jcmFmdF80X3J1YmJlchFnZW5lcmljLndhaXR1bnRpbA5jb21wYXJpc29uLmludA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQMY3JhZnQ0X3N0YXRlCGNvbnN0YW50BAI9PQhjb25zdGFudAIHAAAADWZhY3RvcnkuY3JhZnQIY29uc3RhbnQED2NhYmxlLmluc3VsYXRlZA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllchFnbG9iYWwuZG91YmxlLmdldAhjb25zdGFudAQFY291bnQ=",
"FkZBQ1RPUllfQ1JBRlRfNF9jYWJsZXMAAAAAAAAAAAcAAAAQbG9jYWwuZG91YmxlLnNldAhjb25zdGFudAQGdGFyZ2V0CmRvdWJsZS5tYXgKZG91YmxlLm1heAhjb25zdGFudAMAAAAAAADwPxFhcml0aG1ldGljLmRvdWJsZQNpMmQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIIY29uc3RhbnQEAS0IY29uc3RhbnQDAAAAAAAAAEAKZG91YmxlLm1heBFhcml0aG1ldGljLmRvdWJsZQhjb25zdGFudAMAAAAAAAAkQAhjb25zdGFudAQBLRFhcml0aG1ldGljLmRvdWJsZQhjb25zdGFudAMAAAAAAAAUQAhjb25zdGFudAQBKhFhcml0aG1ldGljLmRvdWJsZRFhcml0aG1ldGljLmRvdWJsZQNpMmQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIIY29uc3RhbnQEAS0IY29uc3RhbnQDAAAAAAAAIEAIY29uc3RhbnQEA3Bvdwhjb25zdGFudAMAAAAAAAAAQAtkb3VibGUuY2VpbBFhcml0aG1ldGljLmRvdWJsZRFhcml0aG1ldGljLmRvdWJsZRFhcml0aG1ldGljLmRvdWJsZQNpMmQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIIY29uc3RhbnQEAS0IY29uc3RhbnQDAAAAAAAA8D8IY29uc3RhbnQEA3Bvdwhjb25zdGFudAMAAAAAAAD4Pwhjb25zdGFudAQBLQhjb25zdGFudAMAAAAAAAAmQBBsb2NhbC5kb3VibGUuc2V0CGNvbnN0YW50BAZ0YXJnZXQRYXJpdGhtZXRpYy5kb3VibGUQbG9jYWwuZG91YmxlLmdldAhjb25zdGFudAQGdGFyZ2V0CGNvbnN0YW50BAEqEWdsb2JhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAVjb3VudA5nZW5lcmljLmdvdG9pZghjb25zdGFudAIHAAAAEWNvbXBhcmlzb24uZG91YmxlE2ZhY3RvcnkuaXRlbXMuY291bnQIY29uc3RhbnQEBWNhYmxlDmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAI+PRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAZ0YXJnZXQRZ2VuZXJpYy53YWl0d2hpbGUWZmFjdG9yeS5tYWNoaW5lLmFjdGl2ZQhjb25zdGFudAQIcmVmaW5lcnkPZmFjdG9yeS5wcm9kdWNlCGNvbnN0YW50BAVpbmdvdA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcgtkb3VibGUuY2VpbBFhcml0aG1ldGljLmRvdWJsZRFhcml0aG1ldGljLmRvdWJsZRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAZ0YXJnZXQIY29uc3RhbnQEAS0TZmFjdG9yeS5pdGVtcy5jb3VudAhjb25zdGFudAQFY2FibGUOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEBHRpZXIIY29uc3RhbnQEAS8IY29uc3RhbnQDAAAAAAAAAEAIY29uc3RhbnQECHJlZmluZXJ5EWdlbmVyaWMud2FpdHdoaWxlFmZhY3RvcnkubWFjaGluZS5hY3RpdmUIY29uc3RhbnQECHJlZmluZXJ5Dmdsb2JhbC5pbnQuc2V0CGNvbnN0YW50BAxjcmFmdDRfc3RhdGUOYXJpdGhtZXRpYy5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEDGNyYWZ0NF9zdGF0ZQhjb25zdGFudAQBKwhjb25zdGFudAICAAAA",
"FkZBQ1RPUllfQ1JBRlRfNF9ydWJiZXIAAAAAAAAAAAcAAAAQbG9jYWwuZG91YmxlLnNldAhjb25zdGFudAQGdGFyZ2V0CmRvdWJsZS5tYXgIY29uc3RhbnQDAAAAAAAAAAARYXJpdGhtZXRpYy5kb3VibGURYXJpdGhtZXRpYy5kb3VibGURYXJpdGhtZXRpYy5kb3VibGUIY29uc3RhbnQDAAAAAAAAAEAIY29uc3RhbnQEASoDaTJkDmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAEtCGNvbnN0YW50AwAAAAAAABBACGNvbnN0YW50BAEtCmRvdWJsZS5tYXgIY29uc3RhbnQDAAAAAAAAAAARYXJpdGhtZXRpYy5kb3VibGUIY29uc3RhbnQDAAAAAAAAAEAIY29uc3RhbnQEAS0RYXJpdGhtZXRpYy5kb3VibGURYXJpdGhtZXRpYy5kb3VibGUDaTJkDmdsb2JhbC5pbnQuZ2V0CGNvbnN0YW50BAR0aWVyCGNvbnN0YW50BAEtCGNvbnN0YW50AwAAAAAAACBACGNvbnN0YW50BAEqEWFyaXRobWV0aWMuZG91YmxlA2kyZA5nbG9iYWwuaW50LmdldAhjb25zdGFudAQEdGllcghjb25zdGFudAQBLQhjb25zdGFudAMAAAAAAAAiQBBsb2NhbC5kb3VibGUuc2V0CGNvbnN0YW50BAZ0YXJnZXQRYXJpdGhtZXRpYy5kb3VibGUQbG9jYWwuZG91YmxlLmdldAhjb25zdGFudAQGdGFyZ2V0CGNvbnN0YW50BAEqEWdsb2JhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAVjb3VudA5nZW5lcmljLmdvdG9pZghjb25zdGFudAIHAAAAEWNvbXBhcmlzb24uZG91YmxlE2ZhY3RvcnkuaXRlbXMuY291bnQIY29uc3RhbnQEDHBsYXRlLnJ1YmJlcghjb25zdGFudAIBAAAACGNvbnN0YW50BAI+PRBsb2NhbC5kb3VibGUuZ2V0CGNvbnN0YW50BAZ0YXJnZXQRZ2VuZXJpYy53YWl0d2hpbGUWZmFjdG9yeS5tYWNoaW5lLmFjdGl2ZQhjb25zdGFudAQHcHJlc3Nlcg9mYWN0b3J5LnByb2R1Y2UIY29uc3RhbnQEBnJ1YmJlcghjb25zdGFudAIBAAAAEWFyaXRobWV0aWMuZG91YmxlEGxvY2FsLmRvdWJsZS5nZXQIY29uc3RhbnQEBnRhcmdldAhjb25zdGFudAQBLRNmYWN0b3J5Lml0ZW1zLmNvdW50CGNvbnN0YW50BAxwbGF0ZS5ydWJiZXIIY29uc3RhbnQCAQAAAAhjb25zdGFudAQHcHJlc3NlchFnZW5lcmljLndhaXR3aGlsZRZmYWN0b3J5Lm1hY2hpbmUuYWN0aXZlCGNvbnN0YW50BAdwcmVzc2VyDmdsb2JhbC5pbnQuc2V0CGNvbnN0YW50BAxjcmFmdDRfc3RhdGUOYXJpdGhtZXRpYy5pbnQOZ2xvYmFsLmludC5nZXQIY29uc3RhbnQEDGNyYWZ0NF9zdGF0ZQhjb25zdGFudAQBKwhjb25zdGFudAIEAAAA",
	};

	local status, ret;

	for k, v in ipairs (tests) do
		status, ret = pcall(import, v);
		assert(status, string.format("Failed to import unit test #%s\n\n%s", k, ret));

		status, ret = pcall(compile, ret[1], ret[2], true);
		assert(status, string.format("Failed to compile unit test #%s\n\n%s", k, ret));

		v = ret;
		status, ret = pcall(import, v);
		assert(status, string.format("Failed to re-import unit test #%s\n\n%s", k, ret));

		status, ret = pcall(compile, ret[1], ret[2], true);
		assert(status, string.format("Failed to re-compile unit test #%s\n\n%s", k, ret));
		assert(ret == v, string.format("Failed to match unit test #%s\n\n%s\n\n%s\n\n%s\n\n%s", k, v, ret, base64.decode(v), base64.decode(ret)));
	end

	return true;
end

LOAD_DONE = true;
