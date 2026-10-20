--!strict
-- Util/BrandNames, the game's own check of AI text for real carmaker and model names (CLAUDE.md hard rules 4 and
-- 11): every name on the list is caught in plain text and through the usual tricks (case, full-width letters,
-- accents, dashes or dots between letters), whole words only, and ordinary car words are left alone. No real name
-- is written in this file: they come from the module's own list. scripts/check.ps1 checks that list covers
-- scripts/banned-names.txt.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BrandNames = require(ReplicatedStorage.Shared.Util.BrandNames)
local Harness = require(ReplicatedStorage.Shared.Testing.Harness)

local FULL_WIDTH_OFFSET = 0xFEE0
local ACCENTED: { [string]: string } = { a = "á", e = "é", i = "í", o = "ó", u = "ú" }

local function fullWidth(text: string): string
	local out: { string } = {}
	for _, code in utf8.codes(text) do
		table.insert(out, if code > 0x20 and code < 0x7F then utf8.char(code + FULL_WIDTH_OFFSET) else utf8.char(code))
	end
	return table.concat(out)
end

local function capitalized(text: string): string
	return string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

-- Every phrase whose text, changed by `change`, isn't caught. Phrases `skip` returns true for are left out.
local function missed(change: (phrase: string) -> string, skip: ((phrase: string) -> boolean)?): { string }
	local list: { string } = {}
	for _, phrase in BrandNames.phrases() do
		if skip ~= nil and skip(phrase) then
			continue
		end
		local text = `a {change(phrase)} car`
		if BrandNames.find(text) == nil then
			table.insert(list, text)
		end
	end
	return list
end

local function oneWord(phrase: string): boolean
	return string.find(phrase, " ", 1, true) == nil
end

return function(t: Harness.Api)
	t.describe("BrandNames", function()
		t.it("has the whole list, decoded", function()
			local phrases = BrandNames.phrases()
			t.expect(#phrases).toBe(#BrandNames.encoded)
			t.expect(#phrases > 40).toBe(true)
			for _, phrase in phrases do
				t.expect({ phrase = phrase, plain = string.match(phrase, "^[a-z0-9 ]+$") ~= nil })
					.toEqual({ phrase = phrase, plain = true })
			end
		end)

		t.it("catches every name as written and in any case", function()
			t.expect(missed(function(phrase: string): string
				return phrase
			end)).toEqual({})
			t.expect(missed(string.upper)).toEqual({})
			t.expect(missed(capitalized)).toEqual({})
			local first = BrandNames.phrases()[1]
			t.expect(BrandNames.find(`the {capitalized(first)} edition`)).toBe(first)
		end)

		t.it("catches full-width letters, accents and combining accents", function()
			t.expect(missed(fullWidth)).toEqual({})
			t.expect(missed(function(phrase: string): string
				return (string.gsub(phrase, "[aeiou]", ACCENTED))
			end)).toEqual({})
			t.expect(missed(function(phrase: string): string
				return (string.gsub(phrase, "[aeiou]", "%0\u{0301}"))
			end)).toEqual({})
		end)

		t.it("catches dashes, underscores and dots", function()
			t.expect(missed(function(phrase: string): string
				return (string.gsub(phrase, " ", "-"))
			end)).toEqual({})
			t.expect(missed(function(phrase: string): string
				return (string.gsub(phrase, " ", "_"))
			end)).toEqual({})
			-- Dotting every letter only rejoins one-word names; the rest are covered above.
			t.expect(missed(function(phrase: string): string
				return (string.gsub(string.sub(phrase, 1, -2), ".", "%0.")) .. string.sub(phrase, -1)
			end, function(phrase: string): boolean
				return not oneWord(phrase)
			end)).toEqual({})
		end)

		t.it("matches whole words only", function()
			local stuck: { string } = {}
			for _, phrase in BrandNames.phrases() do
				if oneWord(phrase) and BrandNames.find(`a {phrase}ish car`) ~= nil then
					table.insert(stuck, phrase)
				end
			end
			t.expect(stuck).toEqual({})
		end)

		t.it("leaves ordinary car words alone", function()
			for _, text in
				{
					"a sleek two-door coupe with round lights",
					"rugged off-roader with a roof rack and a light bar",
					"Volt Comet",
					"Desert Fox",
					"a model of efficiency",
					"the model's best side",
					"affordable family wagon",
					"Custom Sedan",
					"Mod applied",
					"",
				}
			do
				t.expect({ text = text, found = BrandNames.find(text) }).toEqual({ text = text, found = nil })
			end
			t.expect(BrandNames.find(nil :: any)).toBe(nil)
			t.expect(BrandNames.has("\255\254 not text")).toBe(false)
		end)
	end)
end
