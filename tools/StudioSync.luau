--!strict
-- Pulls the repo's code into the open place from tools/studio_sync.py (fallback for when the Rojo plugin can't be
-- connected). Run through the Studio connector (execute_luau, Edit datamodel) while studio_sync.py is serving.
-- Touches only the four code roots in the manifest: creates, updates and removes Folders and scripts there so
-- they match the repo exactly. Returns a short summary.

local HttpService = game:GetService("HttpService")

local PORT = 34991

local manifest = HttpService:JSONDecode(HttpService:GetAsync(`http://127.0.0.1:{PORT}/manifest`, true))

local created, updated, removed, unchanged = 0, 0, 0, 0
local keep: { [Instance]: boolean } = {}

local function childOf(parent: Instance, name: string, className: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	local fresh = Instance.new(className)
	fresh.Name = name
	if existing then
		-- Wrong class (e.g. a folder that became a module with init.luau): move its children over, then replace it.
		for _, child in existing:GetChildren() do
			child.Parent = fresh
		end
		existing:Destroy()
	end
	fresh.Parent = parent
	created += 1
	return fresh
end

for _, item in manifest.items do
	local node: Instance = game
	local path = item.path
	for i = 1, #path - 1 do
		node = node:FindFirstChild(path[i]) or error(`missing parent {table.concat(path, ".", 1, i)}`)
	end
	local isRootService = #path == 1
	local inst = if isRootService then game:GetService(path[1]) else childOf(node, path[#path], item.className)
	keep[inst] = true
	if item.source ~= nil then
		local script = inst :: any
		if script.Source ~= item.source then
			script.Source = item.source
			updated += 1
		else
			unchanged += 1
		end
	end
end

-- Remove folders and scripts under the managed roots that the repo no longer has.
for _, rootPath in manifest.roots do
	local root: Instance? = game
	for _, name in rootPath do
		root = root and root:FindFirstChild(name)
	end
	if root then
		for _, d in root:GetDescendants() do
			if not keep[d] and (d:IsA("LuaSourceContainer") or d:IsA("Folder")) and d.Parent ~= nil then
				d:Destroy()
				removed += 1
			end
		end
	end
end

return `synced: {created} created, {updated} updated, {unchanged} unchanged, {removed} removed`
