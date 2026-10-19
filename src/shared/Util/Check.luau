--!strict
-- Payload validators for remotes (used by Net). Every client payload is untrusted: a validator returns true
-- only when the value has exactly the expected shape. Numbers must be finite and in range, strings must be
-- valid UTF-8 under a length cap, and tables may not carry keys that were not declared.

export type Validator = (value: any) -> boolean

local Check = {}

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- The payload must be absent (remotes that carry no data).
function Check.none(): Validator
	return function(value)
		return value == nil
	end
end

function Check.boolean(): Validator
	return function(value)
		return type(value) == "boolean"
	end
end

function Check.number(min: number, max: number): Validator
	return function(value)
		return type(value) == "number" and isFinite(value) and value >= min and value <= max
	end
end

function Check.integer(min: number, max: number): Validator
	return function(value)
		return type(value) == "number" and isFinite(value) and value % 1 == 0 and value >= min and value <= max
	end
end

function Check.string(maxBytes: number): Validator
	return function(value)
		return type(value) == "string" and #value <= maxBytes and utf8.len(value) ~= nil
	end
end

-- The value must be one of the listed options (ids, enums).
function Check.oneOf(options: { any }): Validator
	local allowed: { [any]: boolean } = {}
	for _, option in options do
		allowed[option] = true
	end
	return function(value)
		return value ~= nil and allowed[value] == true
	end
end

function Check.optional(inner: Validator): Validator
	return function(value)
		return value == nil or inner(value)
	end
end

function Check.vector3(maxMagnitude: number): Validator
	return function(value)
		return typeof(value) == "Vector3"
			and isFinite(value.X)
			and isFinite(value.Y)
			and isFinite(value.Z)
			and value.Magnitude <= maxMagnitude
	end
end

-- A table with exactly these string keys (optional fields may be missing; unknown keys fail).
function Check.shape(fields: { [string]: Validator }): Validator
	return function(value)
		if type(value) ~= "table" then
			return false
		end
		for key in value do
			if type(key) ~= "string" or fields[key] == nil then
				return false
			end
		end
		for key, validate in fields do
			if not validate(value[key]) then
				return false
			end
		end
		return true
	end
end

-- A list of up to maxLength items, each passing `inner`, with no gaps and no other keys.
function Check.array(inner: Validator, maxLength: number): Validator
	return function(value)
		if type(value) ~= "table" then
			return false
		end
		local count = 0
		for key in value do
			if type(key) ~= "number" then
				return false
			end
			count += 1
		end
		if count > maxLength or count ~= #value then
			return false
		end
		for i = 1, count do
			if not inner(value[i]) then
				return false
			end
		end
		return true
	end
end

return Check
