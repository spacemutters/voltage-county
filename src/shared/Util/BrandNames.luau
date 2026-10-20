--!strict
-- Real carmaker and model names the game must never show or send to a generation tool (CLAUDE.md hard rules 4 and
-- 11: AI output is checked in the backend and again in the game, since the backend isn't trusted either). Read by
-- Services/DesignerService (every name, tagline, summary, refusal and mesh prompt the backend sends, and saved
-- text again on join) and tests/DesignKit.spec (the list).
--
--   BrandNames.find(text) -> string?   the first banned name in `text` (decoded, lowercase), or nil
--   BrandNames.has(text) -> boolean
--   BrandNames.phrases() -> { string } every banned name as lowercase words separated by single spaces
--   BrandNames.encoded                 the list as stored (ROT13)
--
-- The list is scripts/banned-names.txt written out as whole-word phrases (both spellings where a pattern allows an
-- optional space or dash), ROT13-encoded so this file doesn't trip the repo's own brand-name gate.
-- scripts/check.ps1 fails when a line of scripts/banned-names.txt has no phrase here, so add one with every new
-- line there.
--
-- Matching follows backend/lib/brands.ts: whole words, any case, with accented and full-width letters read as plain
-- ones and apostrophes dropped (a possessive never becomes a word of its own). The text is read twice: with every
-- other mark as a space, and with separators (- _ . / \ | and middle dots) removed, so a name spelled with dots or
-- dashes between its letters is caught too. Pure: works on the server and clients, in Edit mode too.

local BrandNames = {}

BrandNames.encoded = table.freeze({
	"terraivyyr",
	"grfyn",
	"zbqry 3",
	"zbqry f",
	"zbqry k",
	"zbqry l",
	"ploregehpx",
	"plore gehpx",
	"plorepno",
	"plore pno",
	"sbeq",
	"zhfgnat",
	"s150",
	"s 150",
	"puriebyrg",
	"puril",
	"pbeirggr",
	"pnzneb",
	"fvyirenqb",
	"pnqvyynp",
	"rfpnynqr",
	"tzp",
	"ohvpx",
	"uhzzre",
	"puelfyre",
	"qbqtr",
	"uryypng",
	"wrrc",
	"cbagvnp",
	"gblbgn",
	"pbebyyn",
	"pnzel",
	"cevhf",
	"fhcen",
	"yrkhf",
	"ubaqn",
	"nphen",
	"avffna",
	"tge",
	"tg e",
	"vasvavgv",
	"znmqn",
	"zvngn",
	"fhoneh",
	"zvgfhovfuv",
	"ulhaqnv",
	"xvn",
	"ozj",
	"zreprqrf",
	"oram",
	"nhqv",
	"cbefpur",
	"ibyxfjntra",
	"ij",
	"ibyib",
	"cbyrfgne",
	"evivna",
	"sreenev",
	"ynzobetuvav",
	"znfrengv",
	"nysn ebzrb",
	"svng",
	"ohtnggv",
	"zpynera",
	"xbravtfrtt",
	"cntnav",
	"oragyrl",
	"ebyyf eblpr",
	"nfgba znegva",
	"crhtrbg",
	"eranhyg",
	"pvgebra",
	"fxbqn",
})

-- Full-width ASCII (U+FF01..U+FF5E) reads as plain ASCII, as Unicode's NFKD form has it.
local FULL_WIDTH_FIRST, FULL_WIDTH_LAST, FULL_WIDTH_OFFSET = 0xFF01, 0xFF5E, 0xFEE0
-- Combining accents (U+0300..U+036F) are dropped.
local COMBINING_FIRST, COMBINING_LAST = 0x0300, 0x036F

-- Accented Latin letters (Latin-1 and Latin Extended-A) and what they read as.
local FOLDS: { [string]: string } = {
	a = "ÀÁÂÃÄÅĀĂĄàáâãäåāăą",
	ae = "Ææ",
	c = "ÇĆĈĊČçćĉċč",
	d = "ĎĐďđ",
	e = "ÈÉÊËĒĔĖĘĚèéêëēĕėęě",
	g = "ĜĞĠĢĝğġģ",
	h = "ĤĦĥħ",
	i = "ÌÍÎÏĨĪĬĮİìíîïĩīĭįı",
	j = "Ĵĵ",
	k = "Ķķ",
	l = "ĹĻĽĿŁĺļľŀł",
	n = "ÑŃŅŇñńņň",
	o = "ÒÓÔÕÖØŌŎŐòóôõöøōŏő",
	oe = "Œœ",
	r = "ŔŖŘŕŗř",
	s = "ŚŜŞŠśŝşš",
	ss = "ß",
	t = "ŢŤŦţťŧ",
	u = "ÙÚÛÜŨŪŬŮŰŲùúûüũūŭůűų",
	w = "Ŵŵ",
	y = "ÝŶŸýŷÿ",
	z = "ŹŻŽźżž",
}

-- Marks removed in both readings (apostrophes) and in the joined reading (separators), as plain substrings.
local APOSTROPHES = { "'", "\u{2019}" }
local SEPARATORS = { "-", "_", ".", "/", "\\", "|", "\u{00B7}", "\u{2022}" }

local foldOf: { [number]: string } = {}
for plain, accented in FOLDS do
	for _, code in utf8.codes(accented) do
		foldOf[code] = plain
	end
end

local function rot13(text: string): string
	return (
		string.gsub(text, "%l", function(letter: string): string
			return string.char((string.byte(letter) - string.byte("a") + 13) % 26 + string.byte("a"))
		end)
	)
end

local decoded: { string } = {}
local needles: { string } = {} -- " phrase ", so only whole words match
for _, encoded in BrandNames.encoded do
	local phrase = rot13(encoded)
	table.insert(decoded, phrase)
	table.insert(needles, " " .. phrase .. " ")
end

-- `text` in lowercase with accented and full-width letters made plain and combining accents dropped.
local function fold(text: string): string
	if utf8.len(text) == nil then
		return string.lower(text) -- not valid UTF-8: read its bytes as they are
	end
	local out: { string } = {}
	for _, code in utf8.codes(text) do
		if code >= FULL_WIDTH_FIRST and code <= FULL_WIDTH_LAST then
			table.insert(out, string.char(code - FULL_WIDTH_OFFSET))
		elseif code < COMBINING_FIRST or code > COMBINING_LAST then
			table.insert(out, foldOf[code] or utf8.char(code))
		end
	end
	return string.lower(table.concat(out))
end

-- A pattern matching `text` literally (every ASCII punctuation mark escaped).
local function literal(text: string): string
	return (string.gsub(text, "%p", "%%%0"))
end

local APOSTROPHE_PATTERNS: { string } = {}
for _, mark in APOSTROPHES do
	table.insert(APOSTROPHE_PATTERNS, literal(mark))
end
local SEPARATOR_PATTERNS: { string } = {}
for _, mark in SEPARATORS do
	table.insert(SEPARATOR_PATTERNS, literal(mark))
end

local function without(text: string, patterns: { string }): string
	local result = text
	for _, pattern in patterns do
		result = string.gsub(result, pattern, "")
	end
	return result
end

-- Only letters and digits, each run of anything else one space, with a space at each end.
local function words(text: string): string
	local spaced = string.gsub(text, "[^%w]+", " ")
	return " " .. spaced .. " "
end

-- The first banned name in `text` (the decoded phrase), or nil.
function BrandNames.find(text: string): string?
	if type(text) ~= "string" or text == "" then
		return nil
	end
	local folded = without(fold(text), APOSTROPHE_PATTERNS)
	local spaced = words(folded)
	local joined = words(without(folded, SEPARATOR_PATTERNS))
	for index, needle in needles do
		if string.find(spaced, needle, 1, true) ~= nil or string.find(joined, needle, 1, true) ~= nil then
			return decoded[index]
		end
	end
	return nil
end

function BrandNames.has(text: string): boolean
	return BrandNames.find(text) ~= nil
end

-- Every banned name as the matcher looks for it (a copy).
function BrandNames.phrases(): { string }
	return table.clone(decoded)
end

return BrandNames
