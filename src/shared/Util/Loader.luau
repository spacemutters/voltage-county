--!strict
-- Shared boot routine for server services and client controllers.
-- Every ModuleScript in the folder may define Init() and Start(). All Init() calls finish before any
-- Start() runs, so modules can require each other freely and rely on each other being set up in Start.
-- A module whose require or Init fails is reported and skipped; the rest still boot.

export type Module = {
	Init: ((self: Module) -> ())?,
	Start: ((self: Module) -> ())?,
	[string]: any,
}

type Entry = { name: string, module: Module }

local Loader = {}

local function report(label: string, what: string, err: any)
	warn(`[{label}] {what} failed: {err}`)
end

-- Requires every ModuleScript directly inside `folder` (sorted by name), runs Init on all, then Start on
-- all, and prints "[<label>] booted N <noun>". Returns the number that booted.
function Loader.boot(folder: Instance?, label: string, noun: string): number
	local entries: { Entry } = {}
	if folder ~= nil then
		local scripts = {}
		for _, child in folder:GetChildren() do
			if child:IsA("ModuleScript") then
				table.insert(scripts, child)
			end
		end
		table.sort(scripts, function(a, b)
			return a.Name < b.Name
		end)
		for _, moduleScript in scripts do
			local ok, result = pcall(require :: any, moduleScript)
			if ok and type(result) == "table" then
				table.insert(entries, { name = moduleScript.Name, module = result })
			else
				report(label, `require {moduleScript.Name}`, if ok then "module must return a table" else result)
			end
		end
	end

	local ready: { Entry } = {}
	for _, entry in entries do
		local init = entry.module.Init
		local ok, err = true, nil
		if init then
			ok, err = xpcall(init, debug.traceback, entry.module)
		end
		if ok then
			table.insert(ready, entry)
		else
			report(label, `{entry.name}.Init`, err)
		end
	end

	for _, entry in ready do
		local start = entry.module.Start
		if start then
			task.spawn(function()
				local ok, err = xpcall(start, debug.traceback, entry.module)
				if not ok then
					report(label, `{entry.name}.Start`, err)
				end
			end)
		end
	end

	print(`[{label}] booted {#ready} {noun}`)
	return #ready
end

return Loader
