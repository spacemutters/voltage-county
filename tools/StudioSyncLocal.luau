--!strict
-- Code sync with no Rojo plugin and no HTTP (the Studio connector's execute_luau may not reach localhost). First, from
-- the repo:
--   rojo build tools/sync.project.json -o build/vc_sync.rbxm
--   copy build/vc_sync.rbxm into Studio's content folder (%LOCALAPPDATA%\Roblox\Versions\<current>\content)
-- then run this through execute_luau (Edit datamodel). It mirrors the four code roots Rojo manages, as
-- tools/StudioSync.luau does: scripts and folders are created, updated or removed to match; nothing else is touched.

local roots: { [string]: { string } } = {
	Shared = { "ReplicatedStorage", "Shared" },
	Server = { "ServerScriptService", "Server" },
	Client = { "StarterPlayer", "StarterPlayerScripts", "Client" },
	Tests = { "ServerStorage", "Tests" },
}

local source = game:GetObjects("rbxasset://vc_sync.rbxm")[1]
local created, updated, removed, unchanged = 0, 0, 0, 0

local function mirror(from: Instance, into: Instance)
	local keep: { [Instance]: boolean } = {}
	for _, child in from:GetChildren() do
		local existing = into:FindFirstChild(child.Name)
		local target: Instance
		if existing and existing.ClassName == child.ClassName then
			target = existing
		else
			target = Instance.new(child.ClassName)
			target.Name = child.Name
			if existing then
				for _, grand in existing:GetChildren() do
					grand.Parent = target
				end
				existing:Destroy()
			end
			target.Parent = into
			created += 1
		end
		keep[target] = true
		if child:IsA("LuaSourceContainer") then
			local a, b = child :: any, target :: any
			if b.Source ~= a.Source then
				b.Source = a.Source
				updated += 1
			else
				unchanged += 1
			end
		end
		mirror(child, target)
	end
	for _, child in into:GetChildren() do
		if not keep[child] and (child:IsA("LuaSourceContainer") or child:IsA("Folder")) then
			child:Destroy()
			removed += 1
		end
	end
end

for name, path in roots do
	local node: Instance = game
	for _, step in path do
		node = node:FindFirstChild(step) or error(`missing {table.concat(path, ".")}`)
	end
	mirror(source:FindFirstChild(name) or error(`vc_sync has no {name}`), node)
end

return `synced: {created} created, {updated} updated, {unchanged} unchanged, {removed} removed`
