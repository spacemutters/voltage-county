--!strict
-- Payload validators for remotes (used by Net). Every client payload is untrusted: a validator returns true
-- only when the value has exactly the expected shape. Numbers must be finite and in range, strings must be
-- valid UTF-8 under a length cap, not empty (unless a remote allows it) and free of NUL bytes, and tables may not
-- carry keys that were not declared. A validator never throws, whatever it is given (tests/NetFuzz.spec).

export type Validator = (value: any) -> boolean

local Check = {}

local NUL = "\0"

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- -0 equals 0, so range checks let it through; no client ever means it, and saved as a count it prints as "-0".
local function isNegativeZero(n: number): boolean
	return n == 0 and 1 / n < 0
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
		return type(value) == "number"
			and isFinite(value)
			and value % 1 == 0
			and not isNegativeZero(value)
			and value >= min
			and value <= max
	end
end

-- A string of at most `maxBytes` bytes and at least `minBytes` (default 1: "" is refused, since an empty id or
-- prompt is never a real request; pass 0 where "" means something, like clearing a plate).
function Check.string(maxBytes: number, minBytes: number?): Validator
	local least = minBytes or 1
	return function(value)
		return type(value) == "string"
			and #value >= least
			and #value <= maxBytes
			and string.find(value, NUL, 1, true) == nil
			and utf8.len(value) ~= nil
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

-- A list of up to maxLength items, each passing `inner`, with no gaps and no other keys. A longer list is refused
-- as soon as it is seen to be too long, so a huge one costs no more than a short one.
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
			if count > maxLength then
				return false
			end
		end
		if count ~= #value then
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
