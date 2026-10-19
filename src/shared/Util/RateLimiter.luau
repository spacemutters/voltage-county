--!strict
-- Token bucket per key (usually a Player). Each key starts with `burst` tokens and regains `perSecond`
-- tokens every second, up to `burst`. take() spends one token when one is available.
-- Pass a clock to control time in specs.

export type RateLimiter = {
	take: (key: any) -> boolean,
	forget: (key: any) -> (),
}

type Bucket = { tokens: number, at: number }

local RateLimiter = {}

function RateLimiter.new(burst: number, perSecond: number, clock: (() -> number)?): RateLimiter
	local now: () -> number = clock or os.clock
	local buckets: { [any]: Bucket } = {}

	local function take(key: any): boolean
		local t = now()
		local bucket = buckets[key]
		if bucket == nil then
			local fresh: Bucket = { tokens = burst, at = t }
			buckets[key] = fresh
			bucket = fresh
		end
		assert(bucket, "bucket exists")
		bucket.tokens = math.min(burst, bucket.tokens + math.max(0, t - bucket.at) * perSecond)
		bucket.at = t
		if bucket.tokens < 1 then
			return false
		end
		bucket.tokens -= 1
		return true
	end

	local function forget(key: any)
		buckets[key] = nil
	end

	return { take = take, forget = forget }
end

return RateLimiter
