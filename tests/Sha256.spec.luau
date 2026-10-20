--!strict
-- Util/Sha256 against the standard test vectors (FIPS 180-4 examples and well-known digests), including every
-- padding edge (55, 56, 63, 64, 65, 119 and 120 bytes: one block, two blocks, three blocks) and non-ASCII bytes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Harness = require(ReplicatedStorage.Shared.Testing.Harness)
local Sha256 = require(ReplicatedStorage.Shared.Util.Sha256)

type Vector = { label: string, message: string, digest: string }

local function bytes(from: number, to: number): string
	local list = {}
	for byte = from, to do
		table.insert(list, string.char(byte))
	end
	return table.concat(list)
end

local VECTORS: { Vector } = {
	{
		label = "the empty string",
		message = "",
		digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
	},
	{
		label = '"abc"',
		message = "abc",
		digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
	},
	{
		label = "the 448-bit FIPS message",
		message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
		digest = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
	},
	{
		label = "the 896-bit FIPS message",
		message = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
		digest = "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
	},
	{
		label = "the quick brown fox",
		message = "The quick brown fox jumps over the lazy dog",
		digest = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
	},
	{
		label = "55 bytes (the longest single block)",
		message = string.rep("a", 55),
		digest = "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
	},
	{
		label = "56 bytes (the length spills into a second block)",
		message = string.rep("a", 56),
		digest = "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
	},
	{
		label = "63 bytes",
		message = string.rep("a", 63),
		digest = "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
	},
	{
		label = "64 bytes (exactly one block)",
		message = string.rep("a", 64),
		digest = "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
	},
	{
		label = "65 bytes",
		message = string.rep("a", 65),
		digest = "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
	},
	{
		label = "119 bytes",
		message = string.rep("a", 119),
		digest = "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb",
	},
	{
		label = "120 bytes (three blocks)",
		message = string.rep("a", 120),
		digest = "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c",
	},
	{
		label = "1,000 bytes",
		message = string.rep("a", 1000),
		digest = "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3",
	},
	{
		label = "UTF-8 text",
		message = "caf\u{e9} \u{2603}",
		digest = "ce335642bab85530c756f72c1afb3bfc2067dd39b92e2368e4475c8dbeacc48e",
	},
	{
		label = "every byte value 0..255",
		message = bytes(0, 255),
		digest = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880",
	},
}

return function(t: Harness.Api)
	t.describe("Sha256", function()
		for _, vector in VECTORS do
			t.it(`hashes {vector.label}`, function()
				t.expect(Sha256.hex(vector.message)).toBe(vector.digest)
			end)
		end

		t.it("always answers 64 lowercase hex characters", function()
			local digest = Sha256.hex("salt-1234")
			t.expect(#digest).toBe(64)
			t.expect(string.match(digest, "^[0-9a-f]+$") ~= nil).toBe(true)
		end)

		t.it("gives different digests for different salts of the same id", function()
			t.expect(Sha256.hex("salt-a" .. "42") == Sha256.hex("salt-b" .. "42")).toBe(false)
		end)
	end)
end
