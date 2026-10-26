--!strict
-- Every archetype module the city builder knows (docs/city/ARCHETYPE_GUIDE.md): each ModuleScript in a district folder
-- next to this one (downtown, beach, suburbs, arts, civic...), found by itself so many archetypes can be written side by
-- side. Each one also needs its Config/CityArchetypes/<id> module (tests/City.spec checks the two lists match). The list
-- is sorted by id, so placement draws the same way whatever order Studio keeps the modules in.

local Types = require(script.Parent.Parent.Types)

type Archetype = Types.Archetype

local list: { Archetype } = {}
for _, folder in script.Parent:GetChildren() do
	if folder:IsA("Folder") then
		for _, module in folder:GetChildren() do
			if module:IsA("ModuleScript") then
				table.insert(list, (require :: any)(module) :: Archetype)
			end
		end
	end
end
table.sort(list, function(a: Archetype, b: Archetype): boolean
	return a.id < b.id
end)

local byId: { [string]: Archetype } = {}
for _, archetype in list do
	byId[archetype.id] = archetype
end

return { list = list, byId = byId }
