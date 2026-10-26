--!strict
-- Sends palm meshes to tools/palm_leaflets.py (docs/city/SCENERY.md §1): for each MeshPart in PARTS, its vertices,
-- faces and UVs as <key>.json and its texture's pixels as <key>.hex, POSTed to the script's localhost server. Run it
-- through the Studio connector (execute_luau, Edit datamodel) while `python tools/palm_leaflets.py serve` runs.
-- Needs "Allow HTTP Requests" on in the place, and meshes and textures this account may read (generated ones are).

local AssetService = game:GetService("AssetService")
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local URL = "http://127.0.0.1:8771/put"

-- The parts to send and the key each is filed under (edit to taste). The templates wear their cut ColorMap now, so
-- their own TextureID (the generated texture) is what gets sent.
local palms = ServerStorage:WaitForChild("CityAssets"):WaitForChild("Palms")
local PARTS: { { part: MeshPart, key: string } } = {
	{ part = palms:WaitForChild("royal") :: MeshPart, key = "royal" },
	{ part = palms:WaitForChild("coconut") :: MeshPart, key = "coconut" },
	{ part = palms:WaitForChild("sabal") :: MeshPart, key = "sabal" },
}

local function send(part: MeshPart, key: string): string
	local mesh = AssetService:CreateEditableMeshAsync(Content.fromUri(part.MeshId))
	local index: { [number]: number } = {}
	local positions: { string } = {}
	for i, vertex in mesh:GetVertices() do
		index[vertex] = i - 1
		local p = mesh:GetPosition(vertex)
		table.insert(positions, string.format("%.4f,%.4f,%.4f", p.X, p.Y, p.Z))
	end
	local faces: { string } = {}
	for _, face in mesh:GetFaces() do
		local vertices = mesh:GetFaceVertices(face)
		local uvs = mesh:GetFaceUVs(face)
		local corners: { string } = {}
		for k = 1, 3 do
			local uv = mesh:GetUV(uvs[k]) :: Vector2
			table.insert(corners, string.format("%d,%.5f,%.5f", index[vertices[k]], uv.X, uv.Y))
		end
		table.insert(faces, table.concat(corners, ";"))
	end
	local json =
		HttpService:JSONEncode({ mesh = part.MeshId, texture = part.TextureID, pos = positions, faces = faces })
	HttpService:PostAsync(`{URL}?name={key}.json&mode=w`, json, Enum.HttpContentType.TextPlain)

	local image = AssetService:CreateEditableImageAsync(Content.fromUri(part.TextureID))
	local width, height = image.Size.X, image.Size.Y
	local hex: { [number]: string } = {}
	for b = 0, 255 do
		hex[b] = string.format("%02x", b)
	end
	local rows = 64
	for y = 0, height - 1, rows do
		local n = math.min(rows, height - y)
		local pixels = image:ReadPixelsBuffer(Vector2.new(0, y), Vector2.new(width, n))
		local length = buffer.len(pixels)
		local text = table.create(length) :: { string }
		for i = 0, length - 1 do
			text[i + 1] = hex[buffer.readu8(pixels, i)]
		end
		local mode = if y == 0 then "w" else "a"
		HttpService:PostAsync(`{URL}?name={key}.hex&mode={mode}`, table.concat(text), Enum.HttpContentType.TextPlain)
		task.wait()
	end
	return `{key}: {#positions} vertices, {#faces} faces, texture {width}x{height}`
end

local report: { string } = {}
for _, entry in PARTS do
	local ok, result = pcall(send, entry.part, entry.key)
	table.insert(report, if ok then result else `{entry.key}: {result}`)
end
return table.concat(report, "\n")
