--!strict
-- Tiny in-repo test harness: describe / it / beforeEach / expect.
--
-- A spec is a ModuleScript named "<Something>.spec" under ServerStorage.Tests that returns a function:
--
--   return function(t: Harness.Api)
--   	t.describe("Economy", function()
--   		t.it("adds cash", function()
--   			t.expect(1 + 1).toBe(2)
--   		end)
--   	end)
--   end
--
-- Run every spec (Studio command bar, or MCP execute_luau in the Edit datamodel):
--   require(game.ReplicatedStorage.Shared.Testing.Harness).runFolder(game.ServerStorage.Tests)
-- Each failure prints on its own line, and the last line is "TESTS: passed=N failed=M".

export type Expectation = {
	toBe: (expected: any) -> (),
	toEqual: (expected: any) -> (),
	toBeNear: (expected: number, tolerance: number) -> (),
	toBeGreaterThan: (bound: number) -> (),
	toBeLessThan: (bound: number) -> (),
	toBeTruthy: () -> (),
	toBeFalsy: () -> (),
	toThrow: (messagePart: string?) -> (),
	never: Expectation,
}

export type Api = {
	describe: (name: string, body: () -> ()) -> (),
	it: (name: string, body: () -> ()) -> (),
	beforeEach: (body: () -> ()) -> (),
	expect: (value: any) -> Expectation,
}

export type Spec = { name: string, run: (t: Api) -> () }

type Case = { name: string, body: () -> (), hooks: { () -> () } }

local Harness = {}

local MAX_SHOWN_KEYS = 8
local MAX_DEPTH = 3

local function show(value: any, depth: number?): string
	local level = depth or 0
	if type(value) == "string" then
		return string.format("%q", value)
	elseif type(value) ~= "table" then
		return tostring(value)
	elseif level >= MAX_DEPTH then
		return "{...}"
	end
	local parts = {}
	for key, item in value do
		if #parts >= MAX_SHOWN_KEYS then
			table.insert(parts, "...")
			break
		end
		table.insert(parts, `{tostring(key)}={show(item, level + 1)}`)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return a ~= a and b ~= b -- both NaN
	end
	for key, item in a do
		if not deepEqual(item, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function buildExpectation(value: any, negate: boolean): any
	local function check(passed: boolean, message: string)
		if passed == negate then
			error((if negate then "expected NOT " else "expected ") .. message, 3)
		end
	end

	local e = {}
	function e.toBe(expected: any)
		check(value == expected, `{show(value)} to be {show(expected)}`)
	end
	function e.toEqual(expected: any)
		check(deepEqual(value, expected), `{show(value)} to equal {show(expected)}`)
	end
	function e.toBeNear(expected: number, tolerance: number)
		check(
			type(value) == "number" and math.abs(value - expected) <= tolerance,
			`{show(value)} to be within {tolerance} of {expected}`
		)
	end
	function e.toBeGreaterThan(bound: number)
		check(type(value) == "number" and value > bound, `{show(value)} to be greater than {bound}`)
	end
	function e.toBeLessThan(bound: number)
		check(type(value) == "number" and value < bound, `{show(value)} to be less than {bound}`)
	end
	function e.toBeTruthy()
		check(not not value, `{show(value)} to be truthy`)
	end
	function e.toBeFalsy()
		check(not value, `{show(value)} to be falsy`)
	end
	function e.toThrow(messagePart: string?)
		local ok, err = pcall(value)
		local matches = not ok and (messagePart == nil or string.find(tostring(err), messagePart, 1, true) ~= nil)
		check(matches, if messagePart then `function to throw "{messagePart}"` else "function to throw")
	end
	return e
end

function Harness.expect(value: any): Expectation
	local positive = buildExpectation(value, false)
	local negative = buildExpectation(value, true)
	positive.never = negative
	negative.never = positive
	return positive
end

-- Runs the spec's top level to collect its cases. Returns an error message if the spec itself failed.
local function collect(spec: Spec, cases: { Case }): string?
	local path: { string } = { spec.name }
	local hookStack: { { () -> () } } = { {} }

	local api: Api = {
		describe = function(name, body)
			table.insert(path, name)
			table.insert(hookStack, table.clone(hookStack[#hookStack]))
			body()
			table.remove(hookStack)
			table.remove(path)
		end,
		it = function(name, body)
			table.insert(cases, {
				name = table.concat(path, " > ") .. " > " .. name,
				body = body,
				hooks = hookStack[#hookStack],
			})
		end,
		beforeEach = function(body)
			table.insert(hookStack[#hookStack], body)
		end,
		expect = Harness.expect,
	}

	local ok, err = pcall(spec.run, api)
	return if ok then nil else tostring(err)
end

function Harness.run(specs: { Spec }): (number, number)
	local passed, failed = 0, 0
	for _, spec in specs do
		local cases: { Case } = {}
		local loadError = collect(spec, cases)
		if loadError then
			failed += 1
			print(`FAIL  {spec.name}: spec failed to load: {loadError}`)
		end
		for _, case in cases do
			local ok, err = pcall(function()
				for _, hook in case.hooks do
					hook()
				end
				case.body()
			end)
			if ok then
				passed += 1
			else
				failed += 1
				print(`FAIL  {case.name}: {err}`)
			end
		end
	end
	print(`TESTS: passed={passed} failed={failed}`)
	return passed, failed
end

-- Finds every "*.spec" ModuleScript under `folder` and runs them all.
-- Each spec is required from a fresh copy so an edited spec re-runs within the same Studio session.
function Harness.runFolder(folder: Instance): (number, number)
	local modules: { ModuleScript } = {}
	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("ModuleScript") and string.sub(descendant.Name, -5) == ".spec" then
			table.insert(modules, descendant)
		end
	end
	table.sort(modules, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)

	local specs: { Spec } = {}
	for _, moduleScript in modules do
		local name = string.sub(moduleScript.Name, 1, -6)
		local copy = moduleScript:Clone()
		copy.Parent = moduleScript.Parent
		local ok, result = pcall(require :: any, copy)
		copy:Destroy()
		if ok and type(result) == "function" then
			table.insert(specs, { name = name, run = result })
		else
			local reason = if ok then "spec must return a function" else tostring(result)
			table.insert(specs, {
				name = name,
				run = function()
					error(reason, 0)
				end,
			})
		end
	end
	return Harness.run(specs)
end

return Harness
