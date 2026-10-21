--!strict
-- Vehicle/GeneratedAdapter's triangle budget (Config/Perf meshes; PLAN.md Phase 14 "Budgets": generated meshes at
-- most 20,000 triangles at the top level of detail; docs/phase-14-contracts.md "Performance"):
--   * the count covers every mesh the look keeps and leaves out the four generated wheels (the kit wheels stay)
--   * a body at the budget is taken, one triangle over is refused, and one that can't be counted is refused while
--     Config/Perf meshes.rejectUncounted is on and taken (with its why) while it's off
--   * accept (what build does with a generated model) fits a body inside the budget onto a copy of the kit build and
--     never even scales one over it
--   * the real counter: an EditableMesh's faces as triangles, and a MeshPart with no mesh behind it as unreadable
-- GenerationService is never called: the generated cars here are hand-made Car5 stand-ins (a "body" and four named
-- wheels) whose meshes carry their triangle count in an attribute. Builds in memory only. Edit-mode safe.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Designer = require(ReplicatedStorage.Shared.Config.Designer)
local GeneratedAdapter = require(ReplicatedStorage.Shared.Vehicle.GeneratedAdapter)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Perf = require(ReplicatedStorage.Shared.Config.Perf)
local SpecBuilder = require(ReplicatedStorage.Shared.Vehicle.SpecBuilder)

local kit: any = require(ReplicatedStorage.Shared.Config.DesignKit)

local BUDGET = Perf.meshes.maxTriangles
local TRIANGLES = "Triangles" -- attribute: a stand-in mesh's triangle count (absent: unreadable)
local PLAN_BUDGET = 20000 -- PLAN.md Phase 14: the most a generated mesh may have at its top level of detail

-- Car5's wheel names (Vehicle/GeneratedAdapter WHEEL_PARTS) and where a 2-stud stand-in car has them: its front
-- (-Z) axle at z = -0.6.
local WHEELS: { [string]: Vector3 } = {
	["front left wheel"] = Vector3.new(-0.5, 0.15, -0.6),
	["front right wheel"] = Vector3.new(0.5, 0.15, -0.6),
	["rear left wheel"] = Vector3.new(-0.5, 0.15, 0.6),
	["rear right wheel"] = Vector3.new(0.5, 0.15, 0.6),
}

local function meshPart(name: string, size: Vector3, at: Vector3, triangles: number?): MeshPart
	local part = Instance.new("MeshPart")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(at)
	part.Anchored = true
	if triangles ~= nil then
		part:SetAttribute(TRIANGLES, triangles)
	end
	return part
end

-- A Car5 stand-in: one body mesh per entry of `bodies` (the first named "body"), and four wheels of `wheelTriangles`
-- each.
local function standIn(bodies: { number }, wheelTriangles: number): Model
	local model = Instance.new("Model")
	model.Name = "GeneratedStandIn"
	for index, triangles in bodies do
		local name = if index == 1 then "body" else `body part {index}`
		meshPart(name, Vector3.new(1, 0.5, 2), Vector3.new(0, 0.4, 0), triangles).Parent = model
	end
	for name, at in WHEELS do
		meshPart(name, Vector3.new(0.15, 0.3, 0.3), at, wheelTriangles).Parent = model
	end
	return model
end

-- The stand-ins' counter: their attribute (nil when it is missing, like a mesh that can't be read).
local function fromAttribute(part: MeshPart): number?
	local value = part:GetAttribute(TRIANGLES)
	return if type(value) == "number" then value else nil
end

return function(t: Harness.Api)
	t.describe("GeneratedAdapter triangle budget", function()
		t.it("is the plan's budget at most", function()
			t.expect(BUDGET > 0 and BUDGET <= PLAN_BUDGET).toBe(true)
		end)

		t.it("counts every mesh the look keeps and leaves out the four generated wheels", function()
			local car = standIn({ 12000, 3000 }, 5000)
			local total, why = GeneratedAdapter.triangles(car, fromAttribute)
			car:Destroy()
			t.expect(total).toBe(15000)
			t.expect(why).toBe(nil)
		end)

		t.it("takes a body at the budget and refuses one a triangle over it", function()
			local atBudget = standIn({ BUDGET - 500, 500 }, 4000)
			local over = standIn({ BUDGET - 500, 501 }, 0)
			local okAt, whyAt = GeneratedAdapter.withinBudget(atBudget, fromAttribute)
			local okOver, whyOver = GeneratedAdapter.withinBudget(over, fromAttribute)
			atBudget:Destroy()
			over:Destroy()
			t.expect(okAt).toBe(true)
			t.expect(whyAt).toBe(nil)
			t.expect(okOver).toBe(false)
			local text = tostring(whyOver)
			t.expect(string.find(text, tostring(BUDGET + 1), 1, true) ~= nil).toBe(true)
			t.expect(string.find(text, tostring(BUDGET), 1, true) ~= nil).toBe(true)
		end)

		t.it("refuses a body with a mesh it can't count while rejectUncounted is on, else takes it", function()
			local car = standIn({ 1000 }, 1000)
			meshPart("unreadable panel", Vector3.new(1, 0.2, 1), Vector3.new(0, 0.8, 0), nil).Parent = car
			local total, why = GeneratedAdapter.triangles(car, fromAttribute)
			local ok = GeneratedAdapter.withinBudget(car, fromAttribute)
			car:Destroy()
			t.expect(total).toBe(nil)
			t.expect(string.find(tostring(why), "unreadable panel", 1, true) ~= nil).toBe(true)
			t.expect(ok).toBe(not Perf.meshes.rejectUncounted)
		end)

		t.it("fits a body inside the budget onto a copy of the kit build", function()
			local kitModel = SpecBuilder.build({}, kit)
			local car = standIn({ BUDGET - 1000 }, 2000)
			local look, why = GeneratedAdapter.accept(car, kitModel, fromAttribute)
			car:Destroy()
			local seen = {
				look = look ~= nil,
				why = why,
				marked = if look ~= nil then look:GetAttribute(Designer.generation.lookAttribute) else nil,
				body = if look ~= nil
					then (look:FindFirstChild("Body") :: Instance):FindFirstChild("body") ~= nil
					else nil,
				wheelsLeft = if look ~= nil then look:FindFirstChild("front left wheel", true) ~= nil else nil,
				kitUntouched = kitModel:GetAttribute(Designer.generation.lookAttribute) == nil,
			}
			if look ~= nil then
				look:Destroy()
			end
			kitModel:Destroy()
			t.expect(seen).toEqual({
				look = true,
				why = nil,
				marked = true,
				body = true,
				wheelsLeft = false,
				kitUntouched = true,
			})
		end)

		t.it("never fits a body over the budget (it isn't even scaled)", function()
			local kitModel = SpecBuilder.build({}, kit)
			local car = standIn({ BUDGET + 1 }, 0)
			local scaleBefore = car:GetScale()
			local look, why = GeneratedAdapter.accept(car, kitModel, fromAttribute)
			local scaleAfter = car:GetScale()
			car:Destroy()
			kitModel:Destroy()
			if look ~= nil then
				look:Destroy()
			end
			t.expect(look == nil).toBe(true)
			t.expect(string.find(tostring(why), "budget", 1, true) ~= nil).toBe(true)
			t.expect(scaleAfter).toBe(scaleBefore)
		end)

		t.it("reads an EditableMesh's faces as triangles", function()
			local ok, mesh = pcall(function(): any
				return (AssetService :: any):CreateEditableMesh()
			end)
			if not ok or mesh == nil then
				print(
					`  GeneratedAdapter.spec: no EditableMesh here ({tostring(mesh)}), so the face count wasn't checked`
				)
				return
			end
			local a = mesh:AddVertex(Vector3.new(0, 0, 0))
			local b = mesh:AddVertex(Vector3.new(1, 0, 0))
			local c = mesh:AddVertex(Vector3.new(1, 1, 0))
			local d = mesh:AddVertex(Vector3.new(0, 1, 0))
			mesh:AddTriangle(a, b, c)
			mesh:AddTriangle(a, c, d)
			local count = GeneratedAdapter.editableTriangles(mesh)
			mesh:Destroy()
			t.expect(count).toBe(2)
		end)

		t.it("can't count a MeshPart with no mesh behind it", function()
			local part = Instance.new("MeshPart")
			local count = GeneratedAdapter.meshTriangles(part)
			part:Destroy()
			t.expect(count).toBe(nil)
		end)
	end)
end
